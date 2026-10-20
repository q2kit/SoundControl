import AudioToolbox
import CoreAudio
import Foundation

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transportType: UInt32
    /// For Bluetooth devices, "<product id> <vendor id>" in hex, when the device reports it.
    let modelUID: String?

    /// Devices made by software rather than hardware (game streaming, recording and meeting apps often
    /// add one). Rarely what you want to listen on, so they're hidden from the pickers by default.
    var isVirtual: Bool { transportType == kAudioDeviceTransportTypeVirtual }

    /// SF Symbol that best represents the device.
    var symbol: String {
        let lower = name.lowercased()
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            if let symbol = appleHeadphonesSymbol { return symbol }
            // Anything else doesn't say what kind of device it is (it even reports itself as
            // headphones), so go by the name: headphone-ish names get headphones, the rest a speaker.
            let headphoneWords = ["headphone", "headset", "earphone", "buds", "airpods", "tai nghe"]
            return headphoneWords.contains { lower.contains($0) } ? "headphones" : "hifispeaker"
        case kAudioDeviceTransportTypeBuiltIn:
            return lower.contains("headphone") || lower.contains("tai nghe") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplay.audio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform"
        default:
            return "hifispeaker"
        }
    }

    /// Apple's own Bluetooth headphones report Apple's vendor ID (0x4c) in their model UID, whatever
    /// the user named them, and SF Symbols has a glyph for each kind. The product IDs pick the kind.
    private var appleHeadphonesSymbol: String? {
        let parts = (modelUID ?? "").lowercased().split(separator: " ")
        guard parts.count == 2, parts[1] == "4c", let product = UInt32(parts[0], radix: 16) else { return nil }
        switch product {
        case 0x200E, 0x2014, 0x2024, 0x2027: return "airpodspro"
        case 0x200A, 0x201F: return "airpodsmax"
        case 0x2002, 0x200F, 0x2013, 0x2019, 0x201B: return "airpods"
        default: return "headphones"
        }
    }
}

enum AudioDevices {
    static func outputDevices() -> [OutputDevice] {
        AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyDevices).compactMap { id in
            guard id.dataSize(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput) > 0,
                  let uid = id.readString(kAudioDevicePropertyDeviceUID),
                  let name = id.readString(kAudioObjectPropertyName),
                  !uid.hasPrefix(AppTap.aggregateUIDPrefix)
            else { return nil }
            let transport: UInt32 = id.read(kAudioDevicePropertyTransportType, default: 0)
            return OutputDevice(id: id, uid: uid, name: name, transportType: transport,
                                modelUID: id.readString(kAudioDevicePropertyModelUID))
        }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID {
        AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioDeviceID.unknown)
    }

    static func setDefaultOutputDevice(_ id: AudioDeviceID) {
        _ = AudioObjectID.system.write(kAudioHardwarePropertyDefaultOutputDevice, value: id)
    }

    /// Main output volume (0...1), or nil if the device has no software volume control.
    static func volume(of id: AudioDeviceID) -> Float? {
        guard id.isValid,
              id.has(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        else { return nil }
        let value: Float32 = id.read(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                     scope: kAudioObjectPropertyScopeOutput, default: -1)
        return value < 0 ? nil : value
    }

    static func setVolume(_ volume: Float, of id: AudioDeviceID) {
        _ = id.write(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                     scope: kAudioObjectPropertyScopeOutput, value: Float32(min(1, max(0, volume))))
    }

    static func isMuted(_ id: AudioDeviceID) -> Bool {
        let value: UInt32 = id.read(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, default: 0)
        return value != 0
    }

    static func setMuted(_ muted: Bool, of id: AudioDeviceID) {
        _ = id.write(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, value: UInt32(muted ? 1 : 0))
    }
}
