import SwiftUI

/// One app in the list: icon, name, status, where its sound goes and how loud it is.
struct AppCard: View {
    @EnvironmentObject private var controller: AudioController
    let app: AudioApp
    @State private var hovering = false

    var body: some View {
        let settings = controller.settings(for: app)
        let device = settings.deviceUID.flatMap { uid in controller.devices.first { $0.uid == uid } }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIcon(image: app.icon)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    status(settings)
                }
                // When space is short, the app name keeps its room and the device picker shrinks.
                .layoutPriority(1)

                Spacer(minLength: 2)

                // Always laid out and only faded in on hover, so it never pushes the picker around.
                Menu { actions(settings) } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.button)
                .buttonStyle(ChipButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)

                DevicePicker(
                    title: device?.name ?? String(localized: "Default"),
                    symbol: device?.symbol,
                    devices: controller.pickerDevices(selected: settings.deviceUID),
                    selectedUID: settings.deviceUID,
                    includeDefault: true,
                    maxWidth: 110
                ) { controller.setDevice($0, for: app) }
            }

            VolumeRow(volume: settings.volume, muted: settings.muted,
                      onToggleMute: { controller.toggleMute(for: app) },
                      onChange: { controller.setVolume($0, for: app) })

            if let error = controller.errors[app.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(CardBackground(cornerRadius: 12, opacity: hovering ? 0.08 : 0.045))
        .opacity(app.isPlaying || !settings.isDefault ? 1 : 0.75)
        // Only discrete changes are animated: animating the volume would make the slider trail the cursor.
        .animation(.easeOut(duration: 0.15), value: settings.muted)
        .animation(.easeOut(duration: 0.15), value: settings.isDefault)
        .animation(.easeOut(duration: 0.15), value: settings.deviceUID)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .contextMenu { actions(settings) }
    }

    /// Shared by the "⋯" menu and the right-click menu.
    @ViewBuilder
    private func actions(_ settings: AppSettings) -> some View {
        Button { controller.reset(app) } label: { MenuLabel("Reset", systemImage: "arrow.counterclockwise") }
            .disabled(settings.isDefault)
        Button { controller.setHidden(true, for: app) } label: { MenuLabel("Hide", systemImage: "eye.slash") }
    }

    // A ternary of string literals would be a plain String and skip translation, hence the explicit type.
    private func statusText(_ settings: AppSettings) -> LocalizedStringKey {
        if settings.muted { return "Muted" }
        return app.isPlaying ? "Playing" : "Not Playing"
    }

    private func status(_ settings: AppSettings) -> some View {
        // The icons aren't the same size, so the icon gets a fixed slot and the line a fixed height.
        // Otherwise muting would change the card's height — and with it the whole menu bar window.
        HStack(spacing: 4) {
            Group {
                if settings.muted {
                    Image(systemName: "speaker.slash.fill").foregroundStyle(.red)
                } else if app.isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(.green)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                } else {
                    Image(systemName: "pause.fill").foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 12, height: 12)

            Text(statusText(settings))
                .contentTransition(.opacity)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .frame(height: 14, alignment: .leading)
    }
}
