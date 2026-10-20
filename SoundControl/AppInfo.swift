import Foundation
import os

enum AppInfo {
    /// Whatever bundle identifier the project is built with, so nothing depends on who builds the app.
    static let bundleID = Bundle.main.bundleIdentifier ?? "SoundControl"
}

extension Logger {
    /// A logger whose subsystem is the app's bundle identifier.
    init(category: String) {
        self.init(subsystem: AppInfo.bundleID, category: category)
    }
}
