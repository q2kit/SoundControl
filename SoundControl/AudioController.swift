import AppKit
import AudioToolbox
import Combine
import CoreAudio
import Foundation
import os
import ServiceManagement

private let log = Logger(category: "AudioController")

/// The user's choices, kept in UserDefaults as JSON.
private enum Stored {
    static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, as key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// A user choice to show or hide a device in the output pickers, kept by UID so it survives
/// disconnects. The name is remembered so a hidden, disconnected device can still be listed.
struct DeviceVisibility: Codable, Equatable {
    var name: String
    var visible: Bool
}

/// A non-default output device that apps are explicitly routed to, with its own volume.
struct RoutedDevice: Identifiable, Equatable {
    let device: OutputDevice
    let apps: [AudioApp]
    /// nil when the device has no software volume control.
    var volume: Float?
    var muted: Bool

    var id: AudioDeviceID { device.id }
}

struct AppSettings: Codable, Equatable {
    var volume: Float = 1
    var muted = false
    /// nil = follow the system default output device.
    var deviceUID: String?

    var isDefault: Bool { volume == 1 && !muted && deviceUID == nil }
    var effectiveGain: Float { muted ? 0 : volume }
}

@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var devices: [OutputDevice] = []
    @Published private(set) var defaultDeviceID = AudioDeviceID.unknown
    @Published private(set) var settings: [String: AppSettings] = [:]
    /// Only devices whose visibility differs from the default (virtual devices hidden, others shown).
    @Published private(set) var deviceVisibility: [String: DeviceVisibility] = [:]
    /// Apps moved to the collapsed "Hidden" group. Their settings keep applying; it's only about the list.
    @Published private(set) var hiddenApps: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    /// nil when the current output device has no software volume.
    @Published private(set) var systemVolume: Float?
    @Published private(set) var systemMuted = false
    /// Devices apps are routed to besides the system output, so their volume can be controlled too.
    @Published private(set) var routedDevices: [RoutedDevice] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue, !syncingLaunchAtLogin else { return }
            updateLaunchAtLogin()
        }
    }

    private var taps: [String: AppTap] = [:]
    /// Taps of apps whose settings went back to default, removed after a short delay so that
    /// dragging the slider around 100% doesn't create/destroy a tap on every tick.
    private var pendingTapRemovals: [String: DispatchWorkItem] = [:]
    private static let tapRemovalDelay: TimeInterval = 1.5
    private var syncingLaunchAtLogin = false
    private var systemListeners: [AudioPropertyListener] = []
    private var deviceListeners: [AudioPropertyListener] = []
    private var listenedDeviceID = AudioDeviceID.unknown
    private var processListeners: [AudioObjectID: AudioPropertyListener] = [:]
    private let muteGuard = MuteMirrorGuard()
    private var routedDeviceListeners: [AudioDeviceID: [AudioPropertyListener]] = [:]
    private var lastRoutedVolumeChange: [AudioDeviceID: Date] = [:]
    private var refreshScheduled = false
    private var terminationObserver: NSObjectProtocol?
    private var lastSystemVolumeChange = Date.distantPast
    private static let settingsKey = "AppSettings"
    private static let deviceVisibilityKey = "DeviceVisibility"
    private static let hiddenAppsKey = "HiddenApps"

    init() {
        if let saved: [String: AppSettings] = Stored.load(Self.settingsKey) {
            // Volumes above 100% (an old boost mode) are no longer supported.
            settings = saved.compactMapValues { s in
                var s = s
                s.volume = min(s.volume, 1)
                return s.isDefault ? nil : s
            }
        }
        deviceVisibility = Stored.load(Self.deviceVisibilityKey) ?? [:]
        // Earlier builds stored hidden apps as a plain string array.
        hiddenApps = Stored.load(Self.hiddenAppsKey)
            ?? Set(UserDefaults.standard.stringArray(forKey: Self.hiddenAppsKey) ?? [])
        refresh()

        // Everything is event driven: Core Audio notifies us of every relevant change.
        systemListeners = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyProcessObjectList,
        ].map { AudioPropertyListener(object: .system, selector: $0) { [weak self] in self?.scheduleRefresh() } }

        // Hand every tapped app its sound back before the process goes away.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAllTaps() }
        }
    }

    private func removeAllTaps() {
        pendingTapRemovals.values.forEach { $0.cancel() }
        pendingTapRemovals.removeAll()
        taps.values.forEach { $0.invalidateNow() }
        log.notice("Removed \(self.taps.count) taps before quitting")
        taps.removeAll()
    }

    var defaultDevice: OutputDevice? { devices.first { $0.id == defaultDeviceID } }

    func settings(for app: AudioApp) -> AppSettings { settings[app.id] ?? AppSettings() }

    // MARK: - Hidden apps

    func isHidden(_ app: AudioApp) -> Bool { hiddenApps.contains(app.id) }

    func setHidden(_ hidden: Bool, for app: AudioApp) {
        if hidden { hiddenApps.insert(app.id) } else { hiddenApps.remove(app.id) }
        Stored.save(hiddenApps, as: Self.hiddenAppsKey)
    }

    // MARK: - Device visibility

    func isVisible(_ device: OutputDevice) -> Bool {
        deviceVisibility[device.uid]?.visible ?? !device.isVirtual
    }

    /// Devices to offer in a picker: the visible ones, plus the current selection even if hidden,
    /// so a picker never loses track of what is actually in use.
    func pickerDevices(selected uid: String?) -> [OutputDevice] {
        devices.filter { isVisible($0) || $0.uid == uid }
    }

    /// Hidden devices that are not connected right now (still listed in Settings so they can be shown again).
    var disconnectedHiddenDevices: [(uid: String, name: String)] {
        let connected = Set(devices.map(\.uid))
        return deviceVisibility
            .filter { !$0.value.visible && !connected.contains($0.key) }
            .map { (uid: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setVisible(_ visible: Bool, for device: OutputDevice) {
        // Store only deviations from the default, so the default can evolve.
        deviceVisibility[device.uid] = visible == !device.isVirtual ? nil : DeviceVisibility(name: device.name, visible: visible)
        Stored.save(deviceVisibility, as: Self.deviceVisibilityKey)
    }

    /// Shows a disconnected device again (connected ones go through `setVisible(_:for:)`).
    func showDisconnectedDevice(uid: String) {
        deviceVisibility[uid] = nil
        Stored.save(deviceVisibility, as: Self.deviceVisibilityKey)
    }

    // MARK: - User actions

    func setVolume(_ volume: Float, for app: AudioApp) {
        update(app) { $0.volume = volume }
    }

    func toggleMute(for app: AudioApp) {
        update(app) { $0.muted.toggle() }
    }

    func setDevice(_ uid: String?, for app: AudioApp) {
        update(app) { $0.deviceUID = uid }
    }

    func reset(_ app: AudioApp) {
        update(app) { $0 = AppSettings() }
    }

    func resetAll() {
        settings.removeAll()
        Stored.save(settings, as: Self.settingsKey)
        for id in taps.keys { removeTap(id) }
        errors.removeAll()
        updateRoutedDevices()
    }

    func setSystemVolume(_ volume: Float) {
        lastSystemVolumeChange = Date()
        systemVolume = volume
        AudioDevices.setVolume(volume, of: defaultDeviceID)
        if systemMuted && volume > 0 { toggleSystemMute() }
    }

    func toggleSystemMute() {
        setMuted(!systemMuted, of: defaultDeviceID)
        // Read back: some devices have no mute control and ignore the request.
        systemMuted = AudioDevices.isMuted(defaultDeviceID)
    }

    func setVolume(_ volume: Float, of routed: RoutedDevice) {
        let id = routed.device.id
        lastRoutedVolumeChange[id] = Date()
        AudioDevices.setVolume(volume, of: id)
        if routed.muted && volume > 0 { setMuted(false, of: id) }
        updateRoutedDevice(id) { $0.volume = volume; $0.muted = AudioDevices.isMuted(id) }
    }

    func toggleMute(of routed: RoutedDevice) {
        let id = routed.device.id
        setMuted(!routed.muted, of: id)
        // Read back: some devices have no mute control and ignore the request.
        updateRoutedDevice(id) { $0.muted = AudioDevices.isMuted(id) }
    }

    /// Every mute SoundControl applies for the user goes through here, so the mute guard knows it's intentional.
    private func setMuted(_ muted: Bool, of id: AudioDeviceID) {
        muteGuard.willSetMute(id)
        AudioDevices.setMuted(muted, of: id)
    }

    private func updateRoutedDevice(_ id: AudioDeviceID, _ change: (inout RoutedDevice) -> Void) {
        guard let index = routedDevices.firstIndex(where: { $0.id == id }) else { return }
        change(&routedDevices[index])
    }

    func setSystemOutput(_ device: OutputDevice) {
        AudioDevices.setDefaultOutputDevice(device.id)
        refresh()
    }

    private func update(_ app: AudioApp, _ change: (inout AppSettings) -> Void) {
        var s = settings(for: app)
        change(&s)
        settings[app.id] = s.isDefault ? nil : s
        Stored.save(settings, as: Self.settingsKey)
        applyRouting(for: app)
        updateRoutedDevices()
    }

    // MARK: - Routing

    /// Coalesces bursts of Core Audio notifications into a single refresh.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    /// Refreshes whenever a device's volume or mute changes — from the keyboard, Control Center or anywhere.
    private func volumeAndMuteListeners(_ id: AudioDeviceID) -> [AudioPropertyListener] {
        [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute].map {
            AudioPropertyListener(object: id, selector: $0, scope: kAudioObjectPropertyScopeOutput) { [weak self] in
                self?.scheduleRefresh()
            }
        }
    }

    private func listenToDefaultDevice(_ id: AudioDeviceID) {
        guard id != listenedDeviceID else { return }
        listenedDeviceID = id
        deviceListeners = volumeAndMuteListeners(id)
    }

    /// Works out which other devices apps are sent to, publishes them with their volume for the UI,
    /// follows their volume/mute changes, and tells the mute guard which devices to look after.
    private func updateRoutedDevices() {
        let routed: [RoutedDevice] = devices.compactMap { device in
            guard device.id != defaultDeviceID else { return nil }
            let users = apps.filter { settings(for: $0).deviceUID == device.uid }
            guard !users.isEmpty else { return nil }
            var entry = RoutedDevice(device: device, apps: users,
                                     volume: AudioDevices.volume(of: device.id),
                                     muted: AudioDevices.isMuted(device.id))
            // Don't fight the slider while the user is dragging it.
            if let last = lastRoutedVolumeChange[device.id], Date().timeIntervalSince(last) < 0.5,
               let shown = routedDevices.first(where: { $0.id == device.id }) {
                entry.volume = shown.volume
            }
            return entry
        }
        if routed != routedDevices { routedDevices = routed }

        let ids = Set(routed.map(\.id))
        for id in routedDeviceListeners.keys where !ids.contains(id) {
            routedDeviceListeners[id] = nil
            lastRoutedVolumeChange[id] = nil
        }
        for id in ids where routedDeviceListeners[id] == nil {
            routedDeviceListeners[id] = volumeAndMuteListeners(id)
        }
        muteGuard.update(defaultDeviceID: defaultDeviceID, routedDeviceIDs: ids)
    }

    /// Tracks play/pause of each audio process. Note: `IsRunningOutput` never notifies,
    /// but `IsRunning` does, and by then `IsRunningOutput` has its new value.
    private func listenToProcesses() {
        // Skip our own process: its IO (the taps' aggregate devices) is not interesting.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let objects = Set(AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList)
            .filter { $0.read(kAudioProcessPropertyPID, default: pid_t(-1)) != ownPID })
        for id in processListeners.keys where !objects.contains(id) {
            processListeners[id] = nil
        }
        for id in objects where processListeners[id] == nil {
            processListeners[id] = AudioPropertyListener(object: id, selector: kAudioProcessPropertyIsRunning) {
                [weak self] in self?.scheduleRefresh()
            }
        }
    }

    private func refresh() {
        listenToProcesses()
        let newDevices = AudioDevices.outputDevices()
        if newDevices != devices { devices = newDevices }
        let newDefault = AudioDevices.defaultOutputDeviceID()
        if newDefault != defaultDeviceID { defaultDeviceID = newDefault }
        listenToDefaultDevice(newDefault)
        // Don't fight the slider while the user is dragging it.
        if Date().timeIntervalSince(lastSystemVolumeChange) > 0.5 {
            let volume = AudioDevices.volume(of: newDefault)
            if volume != systemVolume { systemVolume = volume }
            let muted = AudioDevices.isMuted(newDefault)
            if muted != systemMuted { systemMuted = muted }
        }

        let current = AudioProcesses.currentApps()
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
        if current != apps { apps = current }

        let runningIDs = Set(current.map(\.id))
        for id in taps.keys where !runningIDs.contains(id) {
            removeTap(id)
        }
        current.forEach(applyRouting)
        updateRoutedDevices()
    }

    private func applyRouting(for app: AudioApp) {
        let s = settings(for: app)
        guard !app.processObjectIDs.isEmpty, !s.isDefault || taps[app.id] != nil else {
            removeTap(app.id)
            return
        }

        if s.isDefault {
            scheduleTapRemoval(app.id)
        } else {
            pendingTapRemovals.removeValue(forKey: app.id)?.cancel()
        }

        let target = s.deviceUID.flatMap { uid in devices.first { $0.uid == uid } } ?? defaultDevice
        guard let target else { return }

        if let tap = taps[app.id] {
            // Applied in place on a background queue; no teardown, no main-thread blocking.
            tap.gain = s.effectiveGain
            tap.update(processObjectIDs: app.processObjectIDs, outputUID: target.uid)
            return
        }

        let id = app.id
        let tap = AppTap(processObjectIDs: app.processObjectIDs, outputUID: target.uid, gain: s.effectiveGain)
        tap.onStatusChange = { [weak self, weak tap] error in
            // Ignore late callbacks from a tap that has since been replaced or removed.
            guard let self, let tap, self.taps[id] === tap, self.errors[id] != error else { return }
            self.errors[id] = error
        }
        taps[id] = tap
    }

    private func scheduleTapRemoval(_ id: String) {
        guard pendingTapRemovals[id] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingTapRemovals[id] = nil
                if (self.settings[id] ?? AppSettings()).isDefault { self.removeTap(id) }
            }
        }
        pendingTapRemovals[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tapRemovalDelay, execute: work)
    }

    private func removeTap(_ id: String) {
        pendingTapRemovals.removeValue(forKey: id)?.cancel()
        taps.removeValue(forKey: id)?.invalidate()
        errors[id] = nil
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("Launch at login failed: \(error.localizedDescription, privacy: .public)")
        }
        // Reflect the real state (e.g. registration failed or needs approval in System Settings).
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin {
            syncingLaunchAtLogin = true
            launchAtLogin = enabled
            syncingLaunchAtLogin = false
        }
    }
}
