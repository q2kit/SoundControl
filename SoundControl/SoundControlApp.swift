import AppKit
import SwiftUI

@main
struct SoundControlApp: App {
    @StateObject private var controller = AudioController()

    init() {
        Self.terminateOtherInstances()
    }

    var body: some Scene {
        MenuBarExtra("SoundControl", systemImage: "slider.horizontal.3") {
            ContentView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.window)
    }

    /// Two instances would both tap the same apps (each muting them at the source) and route them
    /// independently, so the newest instance (e.g. a fresh Run from Xcode) replaces any older one.
    private static func terminateOtherInstances() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleID)
        where app.processIdentifier != ownPID {
            app.terminate()
            // An instance that doesn't quit in time (hung, or paused in a debugger) is killed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !app.isTerminated { app.forceTerminate() }
            }
        }
    }
}
