import CoreAudio
import Foundation

struct CoreAudioError: LocalizedError {
    let message: String
    let status: OSStatus

    var errorDescription: String? { "\(message) (OSStatus \(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ message: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(message: message(), status: status) }
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    private func address(_ selector: AudioObjectPropertySelector,
                         _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func read<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default defaultValue: T) -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value)
        return status == noErr ? value : defaultValue
    }

    func readString(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    func readObjectIDs(_ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    func has(_ selector: AudioObjectPropertySelector,
             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Bool {
        var addr = address(selector, scope)
        return AudioObjectHasProperty(self, &addr)
    }

    func dataSize(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32 {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr ? size : 0
    }

    func write<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                  value: T) -> OSStatus {
        var addr = address(selector, scope)
        var value = value
        return AudioObjectSetPropertyData(self, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    /// Sets a property whose value is a CF/ObjC object reference (CFString, CFArray, CATapDescription…).
    func writeObject(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     _ object: AnyObject) -> OSStatus {
        var addr = address(selector, scope)
        var ref = Unmanaged.passUnretained(object)
        return AudioObjectSetPropertyData(self, &addr, 0, nil, UInt32(MemoryLayout<Unmanaged<AnyObject>>.size), &ref)
    }
}

/// Registers a Core Audio property listener for its lifetime.
final class AudioPropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    /// The handler runs on `queue`.
    init(object: AudioObjectID, selector: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue, handler: @escaping () -> Void) {
        self.object = object
        self.address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
        self.queue = queue
        self.block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
    }

    /// The handler runs on the main actor.
    convenience init(object: AudioObjectID, selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                     handler: @escaping @MainActor () -> Void) {
        self.init(object: object, selector: selector, scope: scope, queue: .main) {
            MainActor.assumeIsolated { handler() }
        }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
