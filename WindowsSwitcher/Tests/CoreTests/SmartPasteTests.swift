import XCTest
import AppKit
@testable import WindowsSwitcher

// MARK: - 剪贴板解析

final class SmartPasteClipboardParserTests: XCTestCase {

    private let parser = ClipboardPathParser()
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SmartPasteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testAbsoluteDirectoryPathIsRecognizedAsDirectory() {
        let result = parser.parsePathText(tempDirectory.path)

        guard case .directory(let url) = result else {
            return XCTFail("期望目录，实际结果为 \(result)")
        }
        XCTAssertEqual(url.standardizedFileURL.path, tempDirectory.standardizedFileURL.path)
    }

    func testFilePathIsRecognizedAsFile() {
        let fileURL = tempDirectory.appendingPathComponent("note.txt")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())

        let result = parser.parsePathText(fileURL.path)

        guard case .file(let url) = result else {
            return XCTFail("期望文件，实际结果为 \(result)")
        }
        XCTAssertEqual(url.standardizedFileURL.path, fileURL.standardizedFileURL.path)
    }

    func testMissingPathIsReportedAsMissing() {
        let missing = tempDirectory.appendingPathComponent("not-exist").path
        let result = parser.parsePathText(missing)

        guard case .missing(let path) = result else {
            return XCTFail("期望路径缺失，实际结果为 \(result)")
        }
        XCTAssertEqual(path, URL(fileURLWithPath: missing).standardizedFileURL.path)
    }

    func testRelativePathIsNotApplicable() {
        XCTAssertEqual(parser.parsePathText("./Projects"), .notApplicable)
        XCTAssertEqual(parser.parsePathText("Projects"), .notApplicable)
    }

    func testPlainTextIsNotApplicable() {
        XCTAssertEqual(parser.parsePathText("hello world"), .notApplicable)
    }

    func testMultilineTextIsNotApplicable() {
        XCTAssertEqual(parser.parsePathText("/tmp/a\n/tmp/b"), .notApplicable)
    }

    func testEmptyTextIsNotApplicable() {
        XCTAssertEqual(parser.parsePathText("   \n"), .notApplicable)
    }

    func testTildePathIsExpanded() {
        let result = parser.parsePathText("~")

        guard case .directory(let url) = result else {
            return XCTFail("期望家目录被识别为目录，实际结果为 \(result)")
        }
        XCTAssertEqual(url.standardizedFileURL.path,
                       URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
    }

    func testFileURLIsRecognizedAsDirectory() {
        let result = parser.parsePathText(tempDirectory.absoluteString)

        guard case .directory = result else {
            return XCTFail("期望目录，实际结果为 \(result)")
        }
    }

    func testDirectoryURLIsNotApplicable() {
        XCTAssertEqual(parser.parsePathText("https://example.com/path"), .notApplicable)
    }
}

// MARK: - 焦点分类

final class SmartPasteFocusClassifierTests: XCTestCase {

    func testTextRolesAreTreatedAsTextInput() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertEqual(FocusClassifier.classify(role: role), .textInput, "角色 \(role) 应判为文本输入")
        }
    }

    func testBrowserRolesAreTreatedAsFileBrowser() {
        for role in ["AXTable", "AXOutline", "AXBrowser"] {
            XCTAssertEqual(FocusClassifier.classify(role: role), .fileBrowser, "角色 \(role) 应判为文件列表")
        }
    }

    func testButtonIsTreatedAsDialogControl() {
        XCTAssertEqual(FocusClassifier.classify(role: "AXButton"), .dialogControl)
        XCTAssertEqual(FocusClassifier.classify(role: "AXCell"), .dialogControl)
    }

    func testUnknownRoleIsTreatedAsUnknown() {
        XCTAssertEqual(FocusClassifier.classify(role: "AXWebArea"), .unknown)
        XCTAssertEqual(FocusClassifier.classify(role: "AXStaticText"), .unknown)
    }

    func testNilRoleIsTreatedAsUnknown() {
        XCTAssertEqual(FocusClassifier.classify(role: nil), .unknown)
    }

    func testNilElementIsTreatedAsUnknown() {
        XCTAssertEqual(FocusClassifier.classify(element: nil), .unknown)
    }
}

// MARK: - 决策引擎

final class SmartPasteDecisionTests: XCTestCase {

    private let engine = PasteDecisionEngine()
    private let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)

    private func input(clipboard: ClipboardPathResult,
                       focus: FocusClassification,
                       confidence: AdapterConfidence?) -> PasteDecisionEngine.Input {
        PasteDecisionEngine.Input(clipboard: clipboard,
                                  focus: focus,
                                  adapterConfidence: confidence)
    }

    func testDirectoryWithFileListFocusIsAllowed() {
        let decision = engine.decide(input(clipboard: .directory(directory),
                                          focus: .fileBrowser,
                                          confidence: .confirmed))
        XCTAssertEqual(decision, .allow)
    }

    func testTextInputFocusIsDenied() {
        let decision = engine.decide(input(clipboard: .directory(directory),
                                          focus: .textInput,
                                          confidence: .confirmed))
        XCTAssertEqual(decision, .deny(.focusIsTextInput))
    }

    func testUnknownFocusIsDenied() {
        let decision = engine.decide(input(clipboard: .directory(directory),
                                          focus: .unknown,
                                          confidence: .confirmed))
        XCTAssertEqual(decision, .deny(.focusUnknown))
    }

    func testFileClipboardIsDenied() {
        let decision = engine.decide(input(clipboard: .file(directory),
                                          focus: .fileBrowser,
                                          confidence: .confirmed))
        XCTAssertEqual(decision, .deny(.clipboardIsFile))
    }

    func testMissingClipboardIsDenied() {
        let decision = engine.decide(input(clipboard: .missing("/tmp"),
                                          focus: .fileBrowser,
                                          confidence: .confirmed))
        XCTAssertEqual(decision, .deny(.clipboardMissing))
    }

    func testNonPathClipboardIsDenied() {
        let decision = engine.decide(input(clipboard: .notApplicable,
                                          focus: .fileBrowser,
                                          confidence: .confirmed))
        XCTAssertEqual(decision, .deny(.clipboardNotPath))
    }

    func testUncertainAdapterIsDenied() {
        let decision = engine.decide(input(clipboard: .directory(directory),
                                          focus: .fileBrowser,
                                          confidence: .uncertain))
        XCTAssertEqual(decision, .deny(.unsupportedDialog))
    }

    func testMissingAdapterIsDenied() {
        let decision = engine.decide(input(clipboard: .directory(directory),
                                          focus: .fileBrowser,
                                          confidence: nil))
        XCTAssertEqual(decision, .deny(.unsupportedDialog))
    }
}

// MARK: - 快照有效性

final class SmartPasteSnapshotTests: XCTestCase {

    private let request = NavigationRequest(directory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                                            processID: 42,
                                            bundleID: "com.example.app",
                                            focusGeneration: 7,
                                            clipboardChangeCount: 3)

    private func makeSnapshot(createdAt: Date = Date(),
                              lifetime: TimeInterval = 2.0) -> PasteEligibilitySnapshot {
        PasteEligibilitySnapshot(request: request,
                                 processID: 42,
                                 focusGeneration: 7,
                                 clipboardChangeCount: 3,
                                 createdAt: createdAt,
                                 lifetime: lifetime)
    }

    func testEmptySnapshotIsAlwaysInvalid() {
        let snapshot = PasteEligibilitySnapshot.empty()
        XCTAssertFalse(snapshot.isValid(now: Date(),
                                        frontmostProcessID: 42,
                                        currentClipboardChangeCount: 0,
                                        currentFocusGeneration: 0))
    }

    func testValidSnapshotIsAccepted() {
        let snapshot = makeSnapshot()
        XCTAssertTrue(snapshot.isValid(now: Date(),
                                       frontmostProcessID: 42,
                                       currentClipboardChangeCount: 3,
                                       currentFocusGeneration: 7))
    }

    func testExpiredSnapshotIsRejected() {
        let snapshot = makeSnapshot(createdAt: Date().addingTimeInterval(-10), lifetime: 1.0)
        XCTAssertFalse(snapshot.isValid(now: Date(),
                                        frontmostProcessID: 42,
                                        currentClipboardChangeCount: 3,
                                        currentFocusGeneration: 7))
    }

    func testForegroundChangeIsRejected() {
        let snapshot = makeSnapshot()
        XCTAssertFalse(snapshot.isValid(now: Date(),
                                        frontmostProcessID: 99,
                                        currentClipboardChangeCount: 3,
                                        currentFocusGeneration: 7))
        XCTAssertFalse(snapshot.isValid(now: Date(),
                                        frontmostProcessID: nil,
                                        currentClipboardChangeCount: 3,
                                        currentFocusGeneration: 7))
    }

    func testClipboardChangeIsRejected() {
        let snapshot = makeSnapshot()
        XCTAssertFalse(snapshot.isValid(now: Date(),
                                        frontmostProcessID: 42,
                                        currentClipboardChangeCount: 4,
                                        currentFocusGeneration: 7))
    }

    func testFocusGenerationChangeIsRejected() {
        let snapshot = makeSnapshot()
        XCTAssertFalse(snapshot.isValid(now: Date(),
                                        frontmostProcessID: 42,
                                        currentClipboardChangeCount: 3,
                                        currentFocusGeneration: 8))
    }
}

// MARK: - "按回车进入目录"提示的路径匹配

final class SmartPastePathMatchTests: XCTestCase {

    private let directory = URL(fileURLWithPath: "/Users/demo/Projects", isDirectory: true)

    func testExactPathMatches() {
        XCTAssertTrue(SmartPasteCoordinator().matchesPath("/Users/demo/Projects", directory: directory))
    }

    func testTrailingSlashMatches() {
        XCTAssertTrue(SmartPasteCoordinator().matchesPath("/Users/demo/Projects/", directory: directory))
    }

    func testTildePathMatches() {
        XCTAssertTrue(SmartPasteCoordinator().matchesPath("~/Projects", directory: URL(fileURLWithPath: NSHomeDirectory() + "/Projects", isDirectory: true)))
    }

    func testDifferentPathDoesNotMatch() {
        XCTAssertFalse(SmartPasteCoordinator().matchesPath("/Users/demo/Other", directory: directory))
        XCTAssertFalse(SmartPasteCoordinator().matchesPath("", directory: directory))
    }
}

// MARK: - 右键跳转的路径框定位

final class SmartPastePathFieldLocatorTests: XCTestCase {

    private let windowFrame = CGRect(x: 100, y: 200, width: 800, height: 600)

    func testTopAreaFieldIsAccepted() {
        // 窗口顶部中间：y 在顶部 45% 以内
        let field = CGRect(x: 400, y: 220, width: 200, height: 24)
        XCTAssertTrue(DialogPathFieldLocator.isInTopArea(field, in: windowFrame))
        XCTAssertTrue(DialogPathFieldLocator.isNearHorizontalCenter(field, in: windowFrame))
    }

    func testBottomFieldIsRejected() {
        let field = CGRect(x: 400, y: 700, width: 200, height: 24)
        XCTAssertFalse(DialogPathFieldLocator.isInTopArea(field, in: windowFrame))
    }

    func testSideFieldIsRejected() {
        // 左侧区域（偏离中轴）不属于"中间顶部"
        let field = CGRect(x: 110, y: 220, width: 160, height: 24)
        XCTAssertTrue(DialogPathFieldLocator.isInTopArea(field, in: windowFrame))
        XCTAssertFalse(DialogPathFieldLocator.isNearHorizontalCenter(field, in: windowFrame))
    }
}

// MARK: - 右键跳转配置

final class SmartPasteRightClickConfigTests: XCTestCase {

    func testRightClickIsEnabledByDefault() {
        let config = SmartPasteConfig()
        XCTAssertTrue(config.rightClickJumpEnabled)
        XCTAssertTrue(config.suppressSystemContextMenu)
    }

    func testLegacyConfigFallsBackToRightClickDefaults() throws {
        let json = #"{"smartPaste": {"enabled": true}}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let config = try JSONDecoder().decode(ConfigModel.self, from: data)

        XCTAssertTrue(config.smartPaste.enabled)
        XCTAssertTrue(config.smartPaste.rightClickJumpEnabled)
        XCTAssertTrue(config.smartPaste.suppressSystemContextMenu)
    }

    func testRightClickSettingsRoundTrip() throws {
        var config = ConfigModel()
        config.smartPaste.rightClickJumpEnabled = false
        config.smartPaste.suppressSystemContextMenu = false

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)

        XCTAssertFalse(decoded.smartPaste.rightClickJumpEnabled)
        XCTAssertFalse(decoded.smartPaste.suppressSystemContextMenu)
    }
}

// MARK: - 配置迁移

final class SmartPasteConfigTests: XCTestCase {

    func testLegacyConfigWithoutSmartPasteSectionKeepsOtherSettings() throws {
        let json = """
        {
          "behavior": { "sortOrder": "appName" },
          "appearance": { "panelOpacity": 0.8 }
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let config = try JSONDecoder().decode(ConfigModel.self, from: data)

        XCTAssertEqual(config.behavior.sortOrder, .appName)
        XCTAssertEqual(config.appearance.panelOpacity, 0.8)
        XCTAssertFalse(config.smartPaste.enabled)
        XCTAssertEqual(config.smartPaste.navigationTimeout, 1.5)
    }

    func testPartialSmartPasteSectionFallsBackToDefaults() throws {
        let json = #"{"smartPaste": {"enabled": true}}"#
        let data = try XCTUnwrap(json.data(using: .utf8))
        let config = try JSONDecoder().decode(ConfigModel.self, from: data)

        XCTAssertTrue(config.smartPaste.enabled)
        XCTAssertEqual(config.smartPaste.navigationTimeout, 1.5)
        XCTAssertTrue(config.smartPaste.showFailureToast)
        XCTAssertEqual(config.smartPaste.allowedBundleIDs, [])
    }

    func testSmartPasteSectionRoundTrip() throws {
        var config = ConfigModel()
        config.smartPaste.enabled = true
        config.smartPaste.navigationTimeout = 2.5
        config.smartPaste.allowedBundleIDs = ["com.example.editor"]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ConfigModel.self, from: data)

        XCTAssertTrue(decoded.smartPaste.enabled)
        XCTAssertEqual(decoded.smartPaste.navigationTimeout, 2.5)
        XCTAssertEqual(decoded.smartPaste.allowedBundleIDs, ["com.example.editor"])
    }
}
