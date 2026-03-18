import SwiftUI

struct DesignTokens {
    struct Colors {
        // Windows 11 accent
        static let accent = Color(red: 0/255, green: 120/255, blue: 212/255)
        static let accentHover = Color(red: 0/255, green: 103/255, blue: 192/255)
        static let accentLight = Color(red: 0/255, green: 120/255, blue: 212/255).opacity(0.15)

        struct Light {
            static let background = Color(white: 1.0)
            static let secondaryBackground = Color(red: 245/255, green: 245/255, blue: 247/255)
            static let border = Color(red: 229/255, green: 229/255, blue: 229/255)
            static let primaryText = Color(red: 29/255, green: 29/255, blue: 31/255)
            static let secondaryText = Color(red: 134/255, green: 134/255, blue: 139/255)
        }

        struct Dark {
            static let background = Color(red: 28/255, green: 28/255, blue: 30/255)
            static let secondaryBackground = Color(red: 44/255, green: 44/255, blue: 46/255)
            static let border = Color(red: 58/255, green: 58/255, blue: 60/255)
            static let primaryText = Color.white
            static let secondaryText = Color(red: 152/255, green: 152/255, blue: 157/255)
        }
    }

    struct Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    struct CornerRadius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    struct Animation {
        static let panelShow = SwiftUI.Animation.easeOut(duration: 0.2)
        static let itemHover = SwiftUI.Animation.easeOut(duration: 0.15)
        static let previewLoad = SwiftUI.Animation.easeOut(duration: 0.1)
        static let itemClose = SwiftUI.Animation.easeIn(duration: 0.2)
    }
}
