import CoreAudio
import Foundation
import os

private let log = Logger(category: "MuteMirrorGuard")

/// Keeps the keyboard's mute key from reaching devices you've sent apps to.
///
/// Here's the catch. When you press mute (or turn the volume all the way down), macOS mutes the system
/// output — and for some devices it quietly mutes them as well. A Bluetooth speaker may simply follow
/// the built-in speakers, while a pair of headphones next to it doesn't. So if an app plays on that
/// speaker, muting the system output silences the app too, even though you only meant the system
/// output. Unmuting works the same way: it switches the speaker back on even if you had muted it
/// yourself. Only the system's volume keys do this; sliders and direct property changes don't.
///
/// The fix is to watch the mute state of the system output and of every device an app is sent to.
/// If one of those devices flips the same way as the system output at practically the same moment
/// (they land 0–3 ms apart), macOS copied the change over, and we put the device back the way it was.
/// The blip in between is too short to hear.
///
/// The tricky part is telling a copied change from one you made on purpose:
/// - Anything you do inside SoundControl is on purpose. The controller says so with `willSetMute(_:)`
///   just before applying it, so it's never undone, however quickly you click.
/// - For changes from outside (keyboard, Control Center, another app) all we have is timing: within
///   `window` of the system output and in the same direction means copied. Muting the device yourself
///   a moment later is respected. Only doing that with another tool within half a second of pressing
///   the mute key would fool us, which doesn't really happen.
/// - Core Audio sometimes repeats a notification without anything changing; those are ignored.
///
/// All of this runs on its own queue, so a busy UI never delays the fix.
final class MuteMirrorGuard {
    private struct Change {
        let muted: Bool
        let at: Date
    }

    private let queue = DispatchQueue(label: "SoundControl.MuteMirrorGuard", qos: .userInteractive)
    private static let window: TimeInterval = 0.5
    /// How long an announced change of ours waits for its notification before it's considered stale.
    private static let ownChangeLifetime: TimeInterval = 1

    // Only touched on `queue`.
    private var defaultDeviceID = AudioDeviceID.unknown
    private var listeners: [AudioDeviceID: AudioPropertyListener] = [:]
    private var routedDeviceIDs: Set<AudioDeviceID> = []
    private var lastKnownMute: [AudioDeviceID: Bool] = [:]
    /// The last mute change of each watched device that did *not* come from SoundControl.
    private var externalChange: [AudioDeviceID: Change] = [:]
    /// Devices SoundControl is about to change the mute of, with when it announced it.
    private var ownChanges: [AudioDeviceID: Date] = [:]

    /// Call right before SoundControl sets a device's mute on the user's behalf. It is queued ahead of
    /// the resulting notification (same serial queue), so the change is never mistaken for a mirror.
    func willSetMute(_ id: AudioDeviceID) {
        queue.async { [weak self] in self?.ownChanges[id] = Date() }
    }

    func update(defaultDeviceID: AudioDeviceID, routedDeviceIDs: Set<AudioDeviceID>) {
        queue.async { [weak self] in self?.apply(defaultDeviceID, routedDeviceIDs) }
    }

    private func apply(_ newDefault: AudioDeviceID, _ routed: Set<AudioDeviceID>) {
        defaultDeviceID = newDefault
        routedDeviceIDs = routed.subtracting([newDefault])

        var watched = routedDeviceIDs
        if newDefault.isValid { watched.insert(newDefault) }
        for id in listeners.keys where !watched.contains(id) {
            listeners[id] = nil
            lastKnownMute[id] = nil
            externalChange[id] = nil
        }
        for id in watched where listeners[id] == nil {
            lastKnownMute[id] = AudioDevices.isMuted(id)
            listeners[id] = AudioPropertyListener(object: id, selector: kAudioDevicePropertyMute,
                                                  scope: kAudioObjectPropertyScopeOutput, queue: queue) {
                [weak self] in self?.muteChanged(id)
            }
        }
    }

    private func muteChanged(_ id: AudioDeviceID) {
        let muted = AudioDevices.isMuted(id)
        guard muted != lastKnownMute[id] else { return } // repeated notification, nothing changed
        lastKnownMute[id] = muted

        let now = Date()
        if let own = ownChanges.removeValue(forKey: id), now.timeIntervalSince(own) < Self.ownChangeLifetime {
            externalChange[id] = nil // SoundControl did this on the user's behalf: never a mirror
        } else {
            externalChange[id] = Change(muted: muted, at: now)
        }
        reconcile()
    }

    private func reconcile() {
        guard let system = externalChange[defaultDeviceID] else { return }
        for id in routedDeviceIDs {
            guard let change = externalChange[id], change.muted == system.muted,
                  abs(change.at.timeIntervalSince(system.at)) < Self.window,
                  AudioDevices.isMuted(id) == change.muted
            else { continue }
            log.notice("Undoing \(change.muted ? "mute" : "unmute", privacy: .public) mirrored from the system output onto routed device \(id)")
            externalChange[id] = nil
            ownChanges[id] = Date() // our own revert must not be judged as a mirror either
            AudioDevices.setMuted(!change.muted, of: id)
        }
    }
}
