import XCTest
@testable import WindowsSwitcher

// MARK: - 窗口顺序持久化单元测试
///
/// 覆盖"程序重启/重装后切换器顺序不乱"的完整链路：
/// 身份键生成 → 保存记录 → 恢复名次 → 排序结果。
final class WindowOrderPersistenceTests: XCTestCase {

    override func tearDown() {
        WindowOrderStore.shared.reset()
        super.tearDown()
    }

    // MARK: - 身份键

    func testIdentityKeyPrefersAXTitleOverCGTitle() {
        let window = makeWindow(id: 1, bundleID: "com.test.app", title: "CG Title")
        let key = WindowIdentity.key(for: window, axTitle: "AX Title")
        XCTAssertEqual(key, "com.test.app|AX Title",
                       "AX 标题在应用退到后台后依然存在，必须优先使用，否则同一个窗口会得到两个不同的键")
    }

    func testIdentityKeyFallsBackToCGTitleWhenAXUnavailable() {
        let window = makeWindow(id: 1, bundleID: "com.test.app", title: "CG Title")
        let key = WindowIdentity.key(for: window, axTitle: nil)
        XCTAssertEqual(key, "com.test.app|CG Title")
    }

    func testIdentityKeysAreUniqueForSameTitleWindows() {
        let windows = [
            makeWindow(id: 30, bundleID: "com.test.app", title: "无标题"),
            makeWindow(id: 10, bundleID: "com.test.app", title: "无标题"),
            makeWindow(id: 20, bundleID: "com.test.app", title: "无标题")
        ]
        let keys = WindowIdentity.keys(for: windows)
        let values = Array(keys.values)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(Set(values).count, 3, "同标题窗口必须得到不同的键，否则持久化记录互相覆盖")
    }

    func testIdentityKeysAreStableForSameWindowSet() {
        let windows = [
            makeWindow(id: 10, bundleID: "com.test.app", title: "A"),
            makeWindow(id: 20, bundleID: "com.test.app", title: "A")
        ]
        let first = WindowIdentity.keys(for: windows)
        let second = WindowIdentity.keys(for: windows)
        XCTAssertEqual(first, second, "同一组窗口每次计算出的键必须一致")
        XCTAssertNotEqual(first[10], first[20])
    }

    func testIdentityKeysUseCreationOrderForDuplicateTitles() {
        let windows = [
            makeWindow(id: 30, bundleID: "com.test.app", title: "无标题"),
            makeWindow(id: 10, bundleID: "com.test.app", title: "无标题")
        ]
        let keys = WindowIdentity.keys(for: windows)
        XCTAssertEqual(keys[10], "com.test.app|无标题")
        XCTAssertEqual(keys[30], "com.test.app|无标题#1")
    }

    // MARK: - 名次恢复

    func testRestoreRanksKeepsPersistedRankForKnownWindows() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.test.a", title: "A"),
            makeWindow(id: 2, bundleID: "com.test.b", title: "B")
        ]
        let entries = [
            "com.test.a|A": WindowOrderStore.Entry(rank: 42, lastSeen: Date())
        ]
        let ranks = WindowOrderPersistence.restoreRanks(
            for: windows,
            keys: WindowIdentity.keys(for: windows),
            entries: entries
        )
        XCTAssertEqual(ranks[1], 42)
    }

    func testRestoreRanksGivesUnknownWindowsLowestRank() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.test.a", title: "A"),
            makeWindow(id: 2, bundleID: "com.test.b", title: "B")
        ]
        let entries = [
            "com.test.a|A": WindowOrderStore.Entry(rank: 42, lastSeen: Date())
        ]
        let ranks = WindowOrderPersistence.restoreRanks(
            for: windows,
            keys: WindowIdentity.keys(for: windows),
            entries: entries
        )
        XCTAssertEqual(ranks[2], 0, "没有记录的窗口也必须有名次，否则它会因为时间是现在而跳到最前面")
    }

    func testRestoredRanksProducePersistedPanelOrder() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.test.a", title: "A"),
            makeWindow(id: 2, bundleID: "com.test.b", title: "B"),
            makeWindow(id: 3, bundleID: "com.test.c", title: "C")
        ]
        let entries = [
            "com.test.c|C": WindowOrderStore.Entry(rank: 30, lastSeen: Date()),
            "com.test.a|A": WindowOrderStore.Entry(rank: 20, lastSeen: Date()),
            "com.test.b|B": WindowOrderStore.Entry(rank: 10, lastSeen: Date())
        ]
        let ranks = WindowOrderPersistence.restoreRanks(
            for: windows,
            keys: WindowIdentity.keys(for: windows),
            entries: entries
        )
        let sorted = WindowOrdering().sort(windows, by: .recent, activitySequence: ranks)
        XCTAssertEqual(sorted.map(\.id), [3, 1, 2], "恢复后应保持上次的顺序")
    }

    func testRestoredRanksPutUnknownWindowLast() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.test.a", title: "A"),
            makeWindow(id: 9, bundleID: "com.test.new", title: "New")
        ]
        let entries = [
            "com.test.a|A": WindowOrderStore.Entry(rank: 20, lastSeen: Date())
        ]
        let ranks = WindowOrderPersistence.restoreRanks(
            for: windows,
            keys: WindowIdentity.keys(for: windows),
            entries: entries
        )
        let sorted = WindowOrdering().sort(windows, by: .recent, activitySequence: ranks)
        XCTAssertEqual(sorted.map(\.id), [1, 9], "新出现的窗口排在已有窗口之后，而不是跳到最前面")
    }

    func testRestoredRankIsAboveSessionActivityCounter() {
        let sequence = WindowActivitySequence()
        sequence.seed(rank: 20, for: 1)
        sequence.raiseGlobalSequence(to: 30)
        let newRank = sequence.record(windowID: 2)
        XCTAssertGreaterThan(newRank, 30, "本次会话记录的活动名次必须高于恢复出来的名次")
    }

    // MARK: - 名次基准与合并

    func testNextRankBaseIsAboveAllPreviousRanks() {
        let counter: UInt64 = 50
        let base = WindowOrderPersistence.nextRankBase(counter: counter, windowCount: 5)
        XCTAssertGreaterThan(base, counter)
        XCTAssertGreaterThan(base &- 4, counter, "本轮分配出去的所有名次都要高于历史名次")
    }

    func testMergedEntriesPreservesOrderAndKeepsClosedWindows() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.test.a", title: "A"),
            makeWindow(id: 2, bundleID: "com.test.b", title: "B")
        ]
        let keys = WindowIdentity.keys(for: windows)
        let previous = [
            "com.test.c|C": WindowOrderStore.Entry(rank: 5, lastSeen: Date())
        ]
        let now = Date()
        let entries = WindowOrderPersistence.mergedEntries(
            orderedWindows: windows,
            keys: keys,
            previous: previous,
            base: 100,
            now: now,
            cutoff: now.addingTimeInterval(-3600)
        )
        XCTAssertEqual(entries["com.test.a|A"]?.rank, 100, "面板最前面的窗口名次最高")
        XCTAssertEqual(entries["com.test.b|B"]?.rank, 99)
        XCTAssertEqual(entries["com.test.c|C"]?.rank, 5, "已关闭窗口的记录要保留，重新打开时能回到原位置")
    }

    func testMergedEntriesDropsExpiredRecords() {
        let windows = [makeWindow(id: 1, bundleID: "com.test.a", title: "A")]
        let keys = WindowIdentity.keys(for: windows)
        let now = Date()
        let previous = [
            "com.test.old|Old": WindowOrderStore.Entry(
                rank: 5,
                lastSeen: now.addingTimeInterval(-40 * 24 * 60 * 60)
            )
        ]
        let entries = WindowOrderPersistence.mergedEntries(
            orderedWindows: windows,
            keys: keys,
            previous: previous,
            base: 100,
            now: now,
            cutoff: now.addingTimeInterval(-30 * 24 * 60 * 60)
        )
        XCTAssertNil(entries["com.test.old|Old"], "超过保留期的记录要清理")
    }

    func testSaveAndRestoreRoundTripKeepsOrder() {
        let windows = [
            makeWindow(id: 1, bundleID: "com.test.a", title: "A"),
            makeWindow(id: 2, bundleID: "com.test.b", title: "B"),
            makeWindow(id: 3, bundleID: "com.test.c", title: "C")
        ]
        let keys = WindowIdentity.keys(for: windows)
        let now = Date()
        let base = WindowOrderPersistence.nextRankBase(counter: 0, windowCount: windows.count)
        let entries = WindowOrderPersistence.mergedEntries(
            orderedWindows: windows,
            keys: keys,
            previous: [:],
            base: base,
            now: now,
            cutoff: now.addingTimeInterval(-3600)
        )
        WindowOrderStore.shared.save(
            WindowOrderStore.Snapshot(entries: entries, counter: base)
        )

        // 模拟下次启动：窗口 ID 变了，身份键不变
        let relaunched = [
            makeWindow(id: 101, bundleID: "com.test.c", title: "C"),
            makeWindow(id: 102, bundleID: "com.test.a", title: "A"),
            makeWindow(id: 103, bundleID: "com.test.b", title: "B")
        ]
        let snapshot = WindowOrderStore.shared.load()
        let ranks = WindowOrderPersistence.restoreRanks(
            for: relaunched,
            keys: WindowIdentity.keys(for: relaunched),
            entries: snapshot.entries
        )
        let sorted = WindowOrdering().sort(relaunched, by: .recent, activitySequence: ranks)
        XCTAssertEqual(sorted.map(\.bundleIdentifier), ["com.test.a", "com.test.b", "com.test.c"],
                       "重启后顺序应与退出时完全一致")
    }

    func testNewSessionRanksAreAboveRestoredRanks() {
        let windows = [makeWindow(id: 1, bundleID: "com.test.a", title: "A")]
        let keys = WindowIdentity.keys(for: windows)
        let now = Date()
        let base = WindowOrderPersistence.nextRankBase(counter: 0, windowCount: 1)
        let entries = WindowOrderPersistence.mergedEntries(
            orderedWindows: windows,
            keys: keys,
            previous: [:],
            base: base,
            now: now,
            cutoff: now.addingTimeInterval(-3600)
        )
        WindowOrderStore.shared.save(
            WindowOrderStore.Snapshot(entries: entries, counter: base)
        )

        let snapshot = WindowOrderStore.shared.load()
        let nextBase = WindowOrderPersistence.nextRankBase(
            counter: snapshot.counter,
            windowCount: 1
        )
        XCTAssertGreaterThan(nextBase, snapshot.entries.values.map(\.rank).max() ?? 0)
    }

    // MARK: - 存储

    func testStoreRoundTrip() {
        let now = Date()
        let snapshot = WindowOrderStore.Snapshot(
            entries: ["com.test.a|A": WindowOrderStore.Entry(rank: 7, lastSeen: now)],
            counter: 7
        )
        WindowOrderStore.shared.save(snapshot)
        let loaded = WindowOrderStore.shared.load()
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries["com.test.a|A"]?.rank, 7)
        XCTAssertEqual(loaded.counter, 7)
    }

    func testStorePruneRemovesExpiredEntries() {
        let now = Date()
        WindowOrderStore.shared.save(WindowOrderStore.Snapshot(
            entries: [
                "com.test.fresh|F": WindowOrderStore.Entry(rank: 3, lastSeen: now),
                "com.test.stale|S": WindowOrderStore.Entry(
                    rank: 2,
                    lastSeen: now.addingTimeInterval(-40 * 24 * 60 * 60)
                )
            ],
            counter: 3
        ))
        let removed = WindowOrderStore.shared.prune(
            olderThan: now.addingTimeInterval(-30 * 24 * 60 * 60)
        )
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(WindowOrderStore.shared.load().entries.count, 1)
    }

    // MARK: - lastActiveTime（合并自旧版活动存储）

    func testUpdateLastActiveTimeOnlyTouchesExistingEntries() {
        let now = Date()
        WindowOrderStore.shared.save(WindowOrderStore.Snapshot(
            entries: ["com.test.a|A": WindowOrderStore.Entry(rank: 7, lastSeen: now)],
            counter: 7
        ))
        let activityTime = now.addingTimeInterval(-60)
        WindowOrderStore.shared.updateLastActiveTime(identityKey: "com.test.a|A", time: activityTime)
        WindowOrderStore.shared.updateLastActiveTime(identityKey: "com.test.missing|M", time: activityTime)

        let loaded = WindowOrderStore.shared.load()
        XCTAssertEqual(loaded.entries["com.test.a|A"]?.lastActive, activityTime, "已存在的记录要更新激活时间")
        XCTAssertNil(loaded.entries["com.test.missing|M"], "不存在的记录不能被凭空创建")
        XCTAssertEqual(loaded.entries["com.test.a|A"]?.rank, 7, "更新激活时间不能动名次")
    }

    func testLegacyActivityRecordsMigrateIntoSnapshotAndAreRemoved() {
        let now = Date()
        WindowOrderStore.shared.save(WindowOrderStore.Snapshot(
            entries: ["com.test.legacy|L": WindowOrderStore.Entry(rank: 9, lastSeen: now)],
            counter: 9
        ))

        let defaults = UserDefaults.standard
        let legacyTime = now.addingTimeInterval(-300)
        let legacyKey = LegacyWindowActivityStore.legacyKey(forIdentityKey: "com.test.legacy|L")
        defaults.set(legacyTime.timeIntervalSince1970, forKey: legacyKey)
        // 不匹配任何身份键的孤儿记录：迁移后应被删除
        let orphanKey = LegacyWindowActivityStore.legacyKey(forIdentityKey: "com.test.orphan|O")
        defaults.set(1.0, forKey: orphanKey)

        let migrated = LegacyWindowActivityStore.migrateIntoOrderStore()

        XCTAssertEqual(migrated, 1, "只有能匹配身份键的记录会计入迁移数")
        let entry = WindowOrderStore.shared.load().entries["com.test.legacy|L"]
        // 旧记录经 timeIntervalSince1970 存取，纪元换算有亚秒级浮点舍入，用精度比较
        XCTAssertEqual(
            entry?.lastActive?.timeIntervalSince1970 ?? 0,
            legacyTime.timeIntervalSince1970,
            accuracy: 0.001,
            "旧激活时间要并入快照记录"
        )
        XCTAssertEqual(entry?.rank, 9, "迁移不能改名次")
        XCTAssertNil(defaults.object(forKey: legacyKey), "迁移后旧键要删除")
        XCTAssertNil(defaults.object(forKey: orphanKey), "孤儿旧键也要删除")

        // 二次调用应无记录可迁移（幂等）
        XCTAssertEqual(LegacyWindowActivityStore.migrateIntoOrderStore(), 0)
    }

    func testEntryLastActiveSurvivesRoundTrip() {
        let now = Date()
        let activityTime = now.addingTimeInterval(-120)
        WindowOrderStore.shared.save(WindowOrderStore.Snapshot(
            entries: ["com.test.a|A": WindowOrderStore.Entry(rank: 4, lastSeen: now, lastActive: activityTime)],
            counter: 4
        ))
        // 旧版快照 JSON 没有 lastActive 字段，解码后应为 nil
        WindowOrderStore.shared.save(WindowOrderStore.Snapshot(
            entries: ["com.test.a|A": WindowOrderStore.Entry(rank: 5, lastSeen: now)],
            counter: 5
        ))
        XCTAssertEqual(WindowOrderStore.shared.load().entries["com.test.a|A"]?.lastActive, nil)
    }

    // MARK: - Helpers

    private func makeWindow(
        id: CGWindowID,
        bundleID: String,
        title: String
    ) -> WindowModel {
        WindowModel(
            id: id,
            appName: "TestApp",
            bundleIdentifier: bundleID,
            windowTitle: title,
            appIcon: NSImage(),
            frame: .zero,
            isMinimized: false,
            isHidden: false,
            isOnScreen: true,
            lastActiveTime: Date(),
            windowLayer: 0,
            ownerPID: pid_t(id)
        )
    }
}
