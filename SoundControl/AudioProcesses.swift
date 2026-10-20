import AppKit
import CoreAudio
import Darwin

/// One app as you see it in the Dock. Its sound often comes from several helper processes
/// (browsers in particular), which are grouped back under the app that launched them.
struct AudioApp: Identifiable, Equatable {
    let id: String              // bundle identifier, or "pid:<n>" when there is none
    let name: String
    let icon: NSImage?
    let processObjectIDs: [AudioObjectID]
    let isPlaying: Bool

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
            && lhs.processObjectIDs == rhs.processObjectIDs && lhs.isPlaying == rhs.isPlaying
    }
}

enum AudioProcesses {
    private typealias ResponsiblePIDFunc = @convention(c) (pid_t) -> pid_t

    /// Private libsystem call that maps helper processes to the app that launched them.
    private static let responsiblePID: ResponsiblePIDFunc? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: ResponsiblePIDFunc.self)
    }()

    static func currentApps() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier

        struct Group {
            var name: String
            var icon: NSImage?
            var objects: [AudioObjectID] = []
            var playing = false
            var isRegularApp = false
        }
        var groups: [String: Group] = [:]
        var order: [String] = []

        for object in AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = object.read(kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != ownPID else { continue }

            let playing: UInt32 = object.read(kAudioProcessPropertyIsRunningOutput, default: 0)
            let owner = responsibleApplication(for: pid)
            if owner?.processIdentifier == ownPID { continue }

            let key: String
            var group: Group
            if let owner {
                key = owner.bundleIdentifier ?? "pid:\(owner.processIdentifier)"
                group = groups[key] ?? Group(name: owner.localizedName ?? key, icon: owner.icon,
                                             isRegularApp: owner.activationPolicy == .regular)
            } else {
                let bundleID = object.readString(kAudioProcessPropertyBundleID) ?? ""
                key = bundleID.isEmpty ? "pid:\(pid)" : bundleID
                let path = executablePath(pid)
                group = groups[key] ?? Group(
                    name: path.map { ($0 as NSString).lastPathComponent } ?? key,
                    icon: path.map { NSWorkspace.shared.icon(forFile: $0) })
            }
            group.objects.append(object)
            group.playing = group.playing || playing != 0
            if groups[key] == nil { order.append(key) }
            groups[key] = group
        }

        return order.compactMap { key in
            guard let g = groups[key], g.isRegularApp || g.playing else { return nil }
            return AudioApp(id: key, name: g.name, icon: g.icon,
                            processObjectIDs: g.objects.sorted(), isPlaying: g.playing)
        }
    }

    private static func responsibleApplication(for pid: pid_t) -> NSRunningApplication? {
        if let fn = responsiblePID {
            let owner = fn(pid)
            if owner > 0, let app = NSRunningApplication(processIdentifier: owner) { return app }
        }
        return NSRunningApplication(processIdentifier: pid)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }
}
