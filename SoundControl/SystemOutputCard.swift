import SwiftUI

/// The top card: the system output device and its volume, followed by one row for every other
/// device that some app has been sent to.
struct SystemOutputCard: View {
    @EnvironmentObject private var controller: AudioController

    var body: some View {
        let device = controller.defaultDevice

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconBadge(symbol: device?.symbol ?? "speaker.wave.2", tint: .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sound")
                        .font(.system(size: 13, weight: .semibold))
                    Text("System Output")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                DevicePicker(
                    title: device?.name ?? "—",
                    symbol: device?.symbol,
                    devices: controller.pickerDevices(selected: device?.uid),
                    selectedUID: device?.uid,
                    includeDefault: false,
                    maxWidth: 150
                ) { uid in
                    if let target = controller.devices.first(where: { $0.uid == uid }) {
                        controller.setSystemOutput(target)
                    }
                }
            }

            if let volume = controller.systemVolume {
                VolumeRow(volume: volume, muted: controller.systemMuted,
                          onToggleMute: controller.toggleSystemMute,
                          onChange: controller.setSystemVolume)
            }

            ForEach(controller.routedDevices) { routed in
                Divider()
                RoutedDeviceRow(routed: routed)
            }
        }
        .padding(12)
        .background(CardBackground(cornerRadius: 14, opacity: 0.07))
        .animation(.snappy(duration: 0.25), value: controller.routedDevices.map(\.id))
    }
}

/// One device that apps are sent to: its name, who's using it, and its own volume.
/// Several apps on the same device share this one row; each still has its own slider on its card.
private struct RoutedDeviceRow: View {
    @EnvironmentObject private var controller: AudioController
    let routed: RoutedDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: routed.device.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                Text(routed.device.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                AppIconStack(apps: routed.apps)
            }

            if let volume = routed.volume {
                VolumeRow(volume: volume, muted: routed.muted,
                          onToggleMute: { controller.toggleMute(of: routed) },
                          onChange: { controller.setVolume($0, of: routed) })
            }
        }
    }
}

/// The icons of the apps using a device; past a few, the rest become "+N".
private struct AppIconStack: View {
    let apps: [AudioApp]
    private let limit = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(apps.prefix(limit)) { AppIcon(image: $0.icon, size: 18) }
            if apps.count > limit {
                Text("+\(apps.count - limit)")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
