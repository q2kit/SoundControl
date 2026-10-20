import Combine
import CoreAudio
import Foundation
import Network
import os

private let log = Logger(category: "ControlServer")

/// One line on the control socket. Fields are added over time; a client should ignore what it
/// doesn't know, and lines it can't decode at all are skipped on both sides.
struct ControlMessage: Codable, Equatable {
    enum Kind: String, Codable {
        /// client -> server: `version`. Answered with `state`, which is pushed again on every change.
        case hello
        /// server -> client: `version`, `apps`, `settings`, `devices`.
        case state
        /// client -> server: `app`, `volume` (0...1).
        case setVolume
        /// client -> server: `app`, `muted`.
        case setMuted
        /// client -> server: `app`, `device` (a device UID, or absent to follow the system output).
        case setDevice
        /// client -> server: `device`, `volume` (0...1). Raising it from 0 also unmutes, like the volume keys.
        case setDeviceVolume
        /// client -> server: `device`, `muted`.
        case setDeviceMuted
    }

    var kind: Kind
    var version: Int?
    /// An app's identifier: its bundle identifier, or "pid:<n>" when it has none.
    var app: String?
    var volume: Float?
    var muted: Bool?
    var device: String?
    /// Apps that have audio right now.
    var apps: [ControlApp]?
    /// Every app whose settings aren't the defaults, running or not. An app missing from here is at
    /// 100%, unmuted and follows the system output.
    var settings: [String: ControlSettings]?
    /// Output devices an app can be sent to: the ones shown in SoundControl's own pickers.
    var devices: [ControlDevice]?
}

struct ControlApp: Codable, Equatable {
    var id: String
    var name: String
    var playing: Bool
    /// Where the app's sound ends up: the device it's sent to, or the system output.
    var device: ControlDevice?
}

struct ControlDevice: Codable, Equatable {
    var uid: String
    var name: String
    /// Only in `devices`. Absent when the device has no volume control of its own.
    var volume: Float?
    var muted: Bool?
}

struct ControlSettings: Codable, Equatable {
    var volume: Float
    var muted: Bool
    /// UID of the device the app is sent to; absent when it follows the system output.
    var device: String?
}

/// Lets other apps on this Mac follow and change the volume of each app, over a Unix domain socket
/// that only the current user can reach. Each message is one line of JSON (`ControlMessage`).
///
/// SoundControl doesn't know or care who connects. Without clients this does nothing at all.
@MainActor
final class ControlServer {
    static let version = 1
    /// Not derived from the bundle identifier, so clients find it whoever built the app.
    static let socketURL = URL.applicationSupportDirectory
        .appendingPathComponent("SoundControl", isDirectory: true)
        .appendingPathComponent("control.sock")

    private static let maxClients = 8
    private static let maxLineLength = 64 * 1024

    private unowned let controller: AudioController
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private var state = ControlMessage(kind: .state)
    private var subscription: AnyCancellable?

    init(controller: AudioController) {
        self.controller = controller
        state = Self.makeState(controller)
        // Anything the controller publishes may show up in the state, device volumes included (it
        // follows those of the system output and of every device an app is sent to). The change only
        // lands after objectWillChange, hence reading it on the next turn of the main queue.
        subscription = controller.objectWillChange
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .map { [unowned controller] _ in MainActor.assumeIsolated { Self.makeState(controller) } }
            .removeDuplicates()
            .sink { [weak self] in self?.publish($0) }
        start()
    }

    private func start() {
        let path = Self.socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            log.error("Control socket path is too long: \(path, privacy: .public)")
            return
        }
        do {
            let folder = Self.socketURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            // Left behind by an earlier run (or an instance that is quitting right now).
            unlink(path)

            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: path)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            log.error("Couldn't open the control socket: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            log.notice("Listening on \(Self.socketURL.path, privacy: .public)")
        case .failed(let error):
            log.error("Control socket failed: \(error.localizedDescription, privacy: .public)")
            listener?.cancel()
            listener = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.listener == nil else { return }
                    self.start()
                }
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < Self.maxClients else {
            connection.cancel()
            return
        }
        let client = Client(connection, maxLineLength: Self.maxLineLength)
        let id = ObjectIdentifier(client)
        clients[id] = client
        client.onMessage = { [weak self, weak client] message in
            guard let self, let client else { return }
            handle(message, from: client)
        }
        client.onClose = { [weak self] in self?.clients[id] = nil }
        client.start()
    }

    private func handle(_ message: ControlMessage, from client: Client) {
        switch message.kind {
        case .hello:
            client.isSubscribed = true
            client.send(state)
        case .setVolume:
            guard let app = message.app, let volume = message.volume else { return }
            controller.setVolume(volume, forAppID: app)
        case .setMuted:
            guard let app = message.app, let muted = message.muted else { return }
            controller.setMuted(muted, forAppID: app)
        case .setDevice:
            guard let app = message.app else { return }
            controller.setDevice(message.device, forAppID: app)
        case .setDeviceVolume:
            guard let device = message.device, let volume = message.volume else { return }
            controller.setVolume(volume, ofDeviceUID: device)
        case .setDeviceMuted:
            guard let device = message.device, let muted = message.muted else { return }
            controller.setMuted(muted, ofDeviceUID: device)
        case .state:
            break
        }
    }

    private func publish(_ state: ControlMessage) {
        self.state = state
        for client in clients.values where client.isSubscribed {
            client.send(state)
        }
    }

    private static func makeState(_ controller: AudioController) -> ControlMessage {
        var state = ControlMessage(kind: .state, version: version)
        state.apps = controller.apps.map { app in
            // Same choice as the routing: the chosen device while it's connected, otherwise the system output.
            let device = controller.settings[app.id]?.deviceUID.flatMap { uid in controller.devices.first { $0.uid == uid } }
                ?? controller.defaultDevice
            return ControlApp(id: app.id, name: app.name, playing: app.isPlaying,
                              device: device.map { ControlDevice(uid: $0.uid, name: $0.name) })
        }
        state.settings = controller.settings.mapValues {
            ControlSettings(volume: $0.volume, muted: $0.muted, device: $0.deviceUID)
        }
        state.devices = controller.devices.filter(controller.isVisible).map { device in
            let volume = AudioDevices.volume(of: device.id)
            return ControlDevice(uid: device.uid, name: device.name, volume: volume,
                                 muted: volume == nil ? nil : AudioDevices.isMuted(device.id))
        }
        return state
    }

    /// One connected app, exchanging newline-delimited JSON.
    @MainActor
    private final class Client {
        var onMessage: (@MainActor (ControlMessage) -> Void)?
        var onClose: (@MainActor () -> Void)?
        var isSubscribed = false

        private let connection: NWConnection
        private let maxLineLength: Int
        private var buffer = Data()

        init(_ connection: NWConnection, maxLineLength: Int) {
            self.connection = connection
            self.maxLineLength = maxLineLength
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled:
                    MainActor.assumeIsolated { self?.onClose?() }
                default:
                    break
                }
            }
            connection.start(queue: .main)
            receive()
        }

        func send(_ message: ControlMessage) {
            guard var data = try? JSONEncoder().encode(message) else { return }
            data.append(0x0A)
            connection.send(content: data, completion: .contentProcessed { _ in })
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLineLength) { [weak self] data, _, isComplete, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let data, !data.isEmpty {
                        self.buffer.append(data)
                        self.drainBuffer()
                    }
                    if isComplete || error != nil {
                        self.connection.cancel()
                    } else {
                        self.receive()
                    }
                }
            }
        }

        private func drainBuffer() {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if let message = try? JSONDecoder().decode(ControlMessage.self, from: line) {
                    onMessage?(message)
                }
            }
            if buffer.count > maxLineLength {
                connection.cancel()
            }
        }
    }
}
