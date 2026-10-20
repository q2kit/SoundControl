import AudioToolbox
import CoreAudio
import Foundation
import os

private let log = Logger(category: "AppTap")

/// Captures (and silences) the audio of a set of processes with a Core Audio process tap,
/// then plays it back through a chosen output device with its own gain.
///
/// Pipeline: process tap (muted at source) -> private aggregate device (tap + output device) -> IOProc applying gain.
///
/// This is the main-thread facade. All Core Audio configuration runs on a background serial queue.
///
/// When the app spawns or loses a helper process, the tap's process list is updated in place. Moving the
/// sound to another device is different: changing the devices of a running aggregate stops its IO for a
/// few hundred milliseconds and restarts it mid-waveform, which is heard as a crackle, and switching
/// between devices of very different latency (built-in speakers vs Bluetooth) makes the tap skip or
/// repeat that much audio. So a new tap and aggregate are built on the new device instead. The old
/// one keeps playing until the new one actually has sound, then the two are crossfaded and the old one
/// removed. One of the two taps mutes the app at all times, so its own audio never leaks in between.
final class AppTap {
    static let aggregateUIDPrefix = "\(AppInfo.bundleID).aggregate"
    private static let controlQueue = DispatchQueue(label: "SoundControl.TapControl", qos: .userInitiated)

    /// Desired configuration (main thread). The engine converges to it asynchronously.
    private(set) var processObjectIDs: [AudioObjectID]
    private(set) var outputUID: String

    /// Called on the main thread after each (re)configuration: nil on success, otherwise an error message.
    var onStatusChange: (@MainActor (String?) -> Void)?

    /// Set when the last configuration failed, so the next `update` retries even if nothing changed
    /// (e.g. the user granted the audio capture permission in the meantime).
    private var needsRetry = false

    private let gainControl: GainControl
    private let box = EngineBox()

    var gain: Float {
        get { gainControl.value }
        set { gainControl.value = newValue }
    }

    init(processObjectIDs: [AudioObjectID], outputUID: String, gain: Float) {
        self.processObjectIDs = processObjectIDs
        self.outputUID = outputUID
        self.gainControl = GainControl(gain)
        reconfigure()
    }

    deinit { invalidate() }

    func update(processObjectIDs: [AudioObjectID], outputUID: String) {
        guard needsRetry || processObjectIDs != self.processObjectIDs || outputUID != self.outputUID else { return }
        self.processObjectIDs = processObjectIDs
        self.outputUID = outputUID
        reconfigure()
    }

    func invalidate() {
        let box = box
        Self.controlQueue.async {
            box.engine?.invalidate()
            box.engine = nil
        }
    }

    /// Tears the tap down before returning. Used when the app quits: the process would otherwise exit
    /// before the queued `invalidate()` gets to run, and the app being tapped would stay silenced until
    /// Core Audio cleaned up after us.
    func invalidateNow() {
        let box = box
        Self.controlQueue.sync {
            box.engine?.invalidate()
            box.engine = nil
        }
    }

    private func reconfigure() {
        needsRetry = false
        let (box, gainControl, processes, output) = (box, gainControl, processObjectIDs, outputUID)
        Self.controlQueue.async { [weak self] in
            let failure: String?
            do {
                if let engine = box.engine {
                    let inPlace = engine.outputUID == output
                        && (engine.processObjectIDs == processes || engine.setProcesses(processes))
                    if !inPlace {
                        if engine.outputUID == output { log.notice("Updating the tap in place failed; rebuilding it") }
                        // Make before break: the old engine plays until the new one takes over.
                        let replacement = try TapEngine(processObjectIDs: processes, outputUID: output,
                                                        gain: gainControl, startsAudible: false)
                        Self.crossfade(from: engine, to: replacement)
                        box.engine = replacement
                    }
                } else {
                    box.engine = try TapEngine(processObjectIDs: processes, outputUID: output,
                                               gain: gainControl, startsAudible: true)
                }
                failure = nil
            } catch {
                log.error("Tap configuration failed: \(error.localizedDescription, privacy: .public)")
                failure = error.localizedDescription
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.needsRetry = failure != nil
                    self.onStatusChange?(failure)
                }
            }
        }
    }

    private static let fadeDuration: TimeInterval = 0.03

    /// Hands the sound over from `engine` to `replacement` (control queue). The replacement waits for its
    /// tap to deliver sound, which takes as long as the new device's latency (well over 100 ms for
    /// Bluetooth); until then the old engine goes on playing. Then one fades in while the other fades out.
    private static func crossfade(from engine: TapEngine, to replacement: TapEngine) {
        // An app that is paused never delivers sound; don't hold the switch up for it.
        let deadline = Date().addingTimeInterval(0.6)
        while replacement.isWaitingForSound, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        replacement.fade.makeAudible()
        engine.fade.target = 0
        Thread.sleep(forTimeInterval: fadeDuration + 0.02)
        engine.invalidate()
    }

    /// Owned by the control queue only.
    private final class EngineBox {
        var engine: TapEngine?
    }

    /// Gain shared by the main thread (writer) and the IO thread(s) (readers).
    /// An aligned 32-bit float load/store is atomic on Apple silicon and x86-64.
    private final class GainControl {
        var value: Float
        init(_ value: Float) { self.value = value }
    }

    /// Fades one engine in or out while the sound moves to another device, on top of the user's gain.
    /// Shared by the control queue and the engine's IO thread; like `GainControl`, plain aligned loads
    /// and stores are enough.
    private final class FadeControl {
        /// 1 to be heard, 0 to go quiet.
        var target: Float
        /// A new engine stays silent until its tap delivers sound; the IO thread clears this when it
        /// starts fading in.
        var waitingForSound: Bool

        init(audible: Bool) {
            target = audible ? 1 : 0
            waitingForSound = !audible
        }

        func makeAudible() {
            waitingForSound = false
            target = 1
        }
    }

    /// The actual Core Audio objects. Only touched on `controlQueue`.
    private final class TapEngine {
        private(set) var processObjectIDs: [AudioObjectID]
        let outputUID: String
        let fade: FadeControl

        var isWaitingForSound: Bool { fade.waitingForSound }

        private let description: CATapDescription
        private var tapID = AudioObjectID.unknown
        private var aggregateID = AudioObjectID.unknown
        private var ioProcID: AudioDeviceIOProcID?
        private let ioQueue = DispatchQueue(label: "SoundControl.AppTap.IO", qos: .userInteractive)

        /// `startsAudible` false: silent until the tap delivers sound, then faded in (see `crossfade`).
        init(processObjectIDs: [AudioObjectID], outputUID: String, gain: GainControl, startsAudible: Bool) throws {
            self.processObjectIDs = processObjectIDs
            self.outputUID = outputUID
            self.fade = FadeControl(audible: startsAudible)

            description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
            description.uuid = UUID()
            description.name = "SoundControl Tap"
            description.muteBehavior = .mutedWhenTapped
            description.isPrivate = true

            do {
                try check(AudioHardwareCreateProcessTap(description, &tapID), String(localized: "Couldn’t create the process tap"))

                let format: AudioStreamBasicDescription = tapID.read(kAudioTapPropertyFormat,
                                                                     default: AudioStreamBasicDescription())
                // Each engine has its own render state, so two engines running side by side
                // (make before break) never write to the same memory.
                let state = RenderState(gain: gain, fade: fade, tapChannels: max(1, Int(format.mChannelsPerFrame)),
                                        sampleRate: format.mSampleRate > 0 ? format.mSampleRate : 48_000)

                let aggregate: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "SoundControl",
                    kAudioAggregateDeviceUIDKey: "\(AppTap.aggregateUIDPrefix).\(UUID().uuidString)",
                    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceIsStackedKey: false,
                    kAudioAggregateDeviceTapAutoStartKey: true,
                    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                    kAudioAggregateDeviceTapListKey: [[
                        kAudioSubTapDriftCompensationKey: true,
                        // The app and the output device rarely share a clock, and often not even a sample
                        // rate (Bluetooth speakers commonly run at 44.1 kHz while apps play at 48 kHz).
                        // Core Audio resamples the tap to match; at the default quality that is audible.
                        kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]],
                ]
                try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                          String(localized: "Couldn’t create the aggregate device"))

                try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, input, _, output, _ in
                    AppTap.render(input: input, output: output, state: state)
                }, String(localized: "Couldn’t create the audio callback"))

                try check(AudioDeviceStart(aggregateID, ioProcID), String(localized: "Couldn’t start the audio device"))
            } catch {
                invalidate()
                throw error
            }
        }

        /// Updates which processes the tap captures (e.g. a browser spawned a new audio helper).
        func setProcesses(_ ids: [AudioObjectID]) -> Bool {
            description.processes = ids
            guard tapID.writeObject(kAudioTapPropertyDescription, description) == noErr else {
                log.error("Updating tap processes failed")
                return false
            }
            processObjectIDs = ids
            return true
        }

        deinit { invalidate() }

        func invalidate() {
            if aggregateID.isValid {
                if let ioProcID {
                    AudioDeviceStop(aggregateID, ioProcID)
                    AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                }
                AudioHardwareDestroyAggregateDevice(aggregateID)
            }
            if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
            ioProcID = nil
            aggregateID = .unknown
            tapID = .unknown
        }
    }

    // MARK: - Real-time rendering

    /// Only touched by one engine's IO thread (besides the shared `gain` and `fade`).
    private final class RenderState {
        let gain: GainControl
        let fade: FadeControl
        let tapChannels: Int
        /// Gain applied at the end of the previous buffer; ramping from it avoids zipper noise.
        var currentGain: Float
        /// Fade level at the end of the previous buffer, and how far it moves per sample.
        var currentFade: Float
        let fadeStep: Float
        /// Sound arrived in the last buffer; the fade-in starts with the next one, which has sound from
        /// its very first sample.
        var fadeInOnNextBuffer = false

        init(gain: GainControl, fade: FadeControl, tapChannels: Int, sampleRate: Double) {
            self.gain = gain
            self.fade = fade
            self.tapChannels = tapChannels
            self.currentGain = gain.value
            self.currentFade = fade.target
            self.fadeStep = Float(1 / (sampleRate * AppTap.fadeDuration))
        }
    }

    /// The gain for one buffer: the user's gain ramping from `start` to `end` over the buffer, times the
    /// fade moving by at most `step` per sample from `fadeStart` towards `fadeEnd`.
    private struct Ramp {
        let start: Float, end: Float, frames: Float
        let fadeStart: Float, fadeEnd: Float, step: Float

        @inline(__always)
        func at(_ frame: Int) -> Float {
            let user = start + (end - start) * Float(frame) / frames
            let reach = step * Float(frame + 1)
            return user * (fadeStart + min(reach, max(-reach, fadeEnd - fadeStart)))
        }

        var fadeAtEnd: Float {
            let reach = step * frames
            return fadeStart + min(reach, max(-reach, fadeEnd - fadeStart))
        }
    }

    /// Returns (pointer to first sample, stride between frames, frame count) for a global channel index.
    @inline(__always)
    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int)
        -> (UnsafeMutablePointer<Float>, Int, Int)? {
        var i = index
        for buffer in list {
            let n = Int(buffer.mNumberChannels)
            if i < n {
                guard let data = buffer.mData else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n)
                return (data.assumingMemoryBound(to: Float.self) + i, n, frames)
            }
            i -= n
        }
        return nil
    }

    private static func render(input: UnsafePointer<AudioBufferList>,
                               output: UnsafeMutablePointer<AudioBufferList>,
                               state: RenderState) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        var totalOut = 0
        for buffer in outList {
            totalOut += Int(buffer.mNumberChannels)
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var totalIn = 0
        for buffer in inList { totalIn += Int(buffer.mNumberChannels) }

        // The tap's channels come after any input channels of the output device itself.
        let inChannels = min(state.tapChannels, totalIn)
        guard inChannels > 0, totalOut > 0 else { return }
        let inOffset = totalIn - inChannels

        if state.fade.waitingForSound {
            if state.fadeInOnNextBuffer {
                state.fadeInOnNextBuffer = false
                state.fade.makeAudible()
            } else if let (src, stride, frames) = channel(inList, inOffset),
                      (0..<frames).contains(where: { abs(src[$0 * stride]) > 1e-5 }) {
                state.fadeInOnNextBuffer = true
            }
        }

        let frameCount = channel(outList, 0).map { Float($0.2) } ?? 1
        let ramp = Ramp(start: state.currentGain, end: state.gain.value, frames: max(frameCount, 1),
                        fadeStart: state.currentFade, fadeEnd: state.fade.target, step: state.fadeStep)
        state.currentGain = ramp.end
        state.currentFade = ramp.fadeAtEnd
        if ramp.fadeStart == 0, ramp.fadeEnd == 0 { return }

        for oc in 0..<totalOut {
            guard let (dst, dstStride, dstFrames) = channel(outList, oc) else { continue }

            if totalOut == 1, inChannels >= 2,
               let (l, ls, lf) = channel(inList, inOffset), let (r, rs, rf) = channel(inList, inOffset + 1) {
                let frames = min(dstFrames, lf, rf)
                for f in 0..<frames {
                    dst[f * dstStride] = clip((l[f * ls] + r[f * rs]) * 0.5 * ramp.at(f))
                }
                continue
            }

            let source: Int
            if oc < inChannels { source = oc }
            else if inChannels == 1 && oc == 1 { source = 0 }
            else { continue }

            guard let (src, srcStride, srcFrames) = channel(inList, inOffset + source) else { continue }
            let frames = min(dstFrames, srcFrames)
            for f in 0..<frames {
                dst[f * dstStride] = clip(src[f * srcStride] * ramp.at(f))
            }
        }
    }

    @inline(__always)
    private static func clip(_ x: Float) -> Float { min(1, max(-1, x)) }
}
