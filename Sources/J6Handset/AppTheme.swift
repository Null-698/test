import SwiftUI
import UIKit

enum AppTheme {
    static var tint: Color {
        Color(uiColor: .systemBlue)
    }

    static var controlFill: Color {
        Color(uiColor: .secondarySystemFill)
    }

    static var selectedControlFill: Color {
        Color.primary
    }

    static var selectedControlForeground: Color {
        Color(uiColor: .systemBackground)
    }

    static var panelBackground: Color {
        Color(uiColor: .secondarySystemBackground)
    }

    static var separator: Color {
        Color(uiColor: .separator)
    }
}
