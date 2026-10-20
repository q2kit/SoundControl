import SwiftUI

/// The menu bar window: the main page, or Settings sliding in over it.
struct ContentView: View {
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            if showingSettings {
                SettingsView { showingSettings = false }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                MainView { showingSettings = true }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 340)
        .animation(.snappy(duration: 0.25), value: showingSettings)
    }
}

private struct MainView: View {
    @EnvironmentObject private var controller: AudioController
    let openSettings: () -> Void

    var body: some View {
        let visible = controller.apps.filter { !controller.isHidden($0) }
        let hidden = controller.apps.filter { controller.isHidden($0) }

        VStack(spacing: 0) {
            SystemOutputCard()
                .padding(12)

            if controller.apps.isEmpty {
                EmptyState()
            } else {
                FittedScrollView(maxHeight: 440) {
                    VStack(alignment: .leading, spacing: 6) {
                        section("Playing", visible.filter(\.isPlaying))
                        section("Other Apps", visible.filter { !$0.isPlaying })
                        if !hidden.isEmpty { HiddenAppsSection(apps: hidden) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }

            Divider()
            Footer(openSettings: openSettings)
        }
        .animation(.snappy(duration: 0.25), value: controller.apps.map(\.id))
        .animation(.snappy(duration: 0.25), value: controller.hiddenApps)
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ apps: [AudioApp]) -> some View {
        if !apps.isEmpty {
            SectionTitle(title)
            ForEach(apps) { AppCard(app: $0) }
        }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.zzz")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No apps are using audio")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Play some music or a video in any app to adjust it here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private struct Footer: View {
    @EnvironmentObject private var controller: AudioController
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            FooterButton(symbol: "arrow.counterclockwise", action: controller.resetAll)
            FooterButton(symbol: "gearshape", action: openSettings)
            FooterButton(symbol: "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
