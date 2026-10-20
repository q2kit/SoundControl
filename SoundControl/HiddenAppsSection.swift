import SwiftUI

/// Apps you've put away because you don't care about them (say, one you always keep muted).
/// They sit in a collapsed group at the bottom of the list, and their settings keep applying.
struct HiddenAppsSection: View {
    let apps: [AudioApp]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Hidden (\(apps.count))")
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                }
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .padding(.top, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // The list slides out from under the header like a drawer. The clipped container starts
            // right below the header, so while sliding in, the part still "above" it stays hidden
            // instead of passing over the header.
            VStack(spacing: 0) {
                if expanded {
                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                            if index > 0 { Divider().padding(.leading, 30) }
                            HiddenAppRow(app: app)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(CardBackground(cornerRadius: 12, opacity: 0.045))
                    .padding(.top, 6) // inside the clip, so the gap disappears together with the list
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .clipped()
        }
        .animation(.snappy(duration: 0.2), value: expanded)
    }
}

/// A compact line for a hidden app: just enough to mute it or bring it back.
private struct HiddenAppRow: View {
    @EnvironmentObject private var controller: AudioController
    let app: AudioApp

    var body: some View {
        let settings = controller.settings(for: app)

        HStack(spacing: 8) {
            AppIcon(image: app.icon, size: 20)
            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
            if app.isPlaying && !settings.muted {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 8)

            MuteButton(muted: settings.muted, volume: settings.volume) { controller.toggleMute(for: app) }
                .scaleEffect(0.85)
            FooterButton(symbol: "eye") { controller.setHidden(false, for: app) }
        }
        .frame(minHeight: 34)
    }
}
