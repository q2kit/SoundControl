import CoreAudio
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: AudioController
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                FooterButton(symbol: "chevron.left", action: close)
                Text("Settings").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            Divider()

            FittedScrollView(maxHeight: 520) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle("General")
                    SettingsCard {
                        SettingsRow(title: Text("Open at Login")) {
                            Toggle("", isOn: $controller.launchAtLogin).labelsHidden()
                        }
                    }

                    SectionTitle("Output Devices")
                    SettingsCard {
                        ForEach(Array(controller.devices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { Divider().padding(.leading, 38) }
                            DeviceRow(device: device)
                        }
                        ForEach(controller.disconnectedHiddenDevices, id: \.uid) { hidden in
                            Divider().padding(.leading, 38)
                            SettingsRow(symbol: "speaker.slash", title: Text(verbatim: hidden.name), subtitle: Text("Not Connected")) {
                                Toggle("", isOn: Binding(
                                    get: { false },
                                    set: { if $0 { controller.showDisconnectedDevice(uid: hidden.uid) } }
                                ))
                                .labelsHidden()
                            }
                            .opacity(0.6)
                        }
                    }
                    Text("Devices turned off here don’t show up when choosing an output, unless they’re in use. Virtual devices created by other software are hidden from the start.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
                .padding(12)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

private struct DeviceRow: View {
    @EnvironmentObject private var controller: AudioController
    let device: OutputDevice

    var body: some View {
        SettingsRow(symbol: device.symbol, title: Text(verbatim: device.name), subtitle: subtitle.map { Text(verbatim: $0) }) {
            Toggle("", isOn: Binding(
                get: { controller.isVisible(device) },
                set: { controller.setVisible($0, for: device) }
            ))
            .labelsHidden()
        }
        .opacity(controller.isVisible(device) ? 1 : 0.6)
    }

    /// e.g. "Bluetooth · in use"
    private var subtitle: String? {
        var parts: [String] = []
        if let kind { parts.append(kind) }
        if device.id == controller.defaultDeviceID {
            parts.append(String(localized: "system output"))
        } else if controller.settings.values.contains(where: { $0.deviceUID == device.uid }) {
            parts.append(String(localized: "in use"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var kind: String? {
        switch device.transportType {
        case kAudioDeviceTransportTypeBuiltIn: String(localized: "Built-in")
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: String(localized: "Display")
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeVirtual: String(localized: "Virtual Device")
        default: nil
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(CardBackground(cornerRadius: 12, opacity: 0.045))
    }
}

private struct SettingsRow<Accessory: View>: View {
    var symbol: String? = nil
    let title: Text
    var subtitle: Text? = nil
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 1) {
                title.font(.system(size: 12.5)).lineLimit(1)
                if let subtitle {
                    subtitle.font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .frame(minHeight: 36)
    }
}
