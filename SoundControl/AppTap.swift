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
/// This is the main-thread facade. All Core Audio configuration runs on a background serial queue, and
/// changes are applied in place (swap the aggregate's output device / update the tap's process list)
/// so the tap — and therefore the mute at the source — never goes away. That avoids the audible
/// "original audio leaks, then silence" gap of tearing down and rebuilding.
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
                    let inPlace = (engine.processObjectIDs == processes || engine.setProcesses(processes))
                        && (engine.outputUID == output || engine.setOutput(output))
                    if !inPlace {
                        log.notice("In-place reconfiguration failed; rebuilding tap")
                        // Make before break: start the replacement before removing the old one.
                        let replacement = try TapEngine(processObjectIDs: processes, outputUID: output, gain: gainControl)
                        engine.invalidate()
                        box.engine = replacement
                    }
                } else {
                    box.engine = try TapEngine(processObjectIDs: processes, outputUID: output, gain: gainControl)
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

    /// The actual Core Audio objects. Only touched on `controlQueue`.
    private final class TapEngine {
        private(set) var processObjectIDs: [AudioObjectID]
        private(set) var outputUID: String

        private let description: CATapDescription
        private var tapID = AudioObjectID.unknown
        private var aggregateID = AudioObjectID.unknown
        private var ioProcID: AudioDeviceIOProcID?
        private let ioQueue = DispatchQueue(label: "SoundControl.AppTap.IO", qos: .userInteractive)

        init(processObjectIDs: [AudioObjectID], outputUID: String, gain: GainControl) throws {
            self.processObjectIDs = processObjectIDs
            self.outputUID = outputUID

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
                let state = RenderState(gain: gain, tapChannels: max(1, Int(format.mChannelsPerFrame)))

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

        /// Swaps the aggregate's output device without touching the tap.
        func setOutput(_ uid: String) -> Bool {
            let swapped = aggregateID.writeObject(kAudioAggregateDevicePropertyFullSubDeviceList,
                                                  [outputUID, uid] as CFArray) == noErr
                && aggregateID.writeObject(kAudioAggregateDevicePropertyMainSubDevice, uid as CFString) == noErr
                && aggregateID.writeObject(kAudioAggregateDevicePropertyFullSubDeviceList, [uid] as CFArray) == noErr
            guard swapped else {
                log.error("Swapping output device failed")
                return false
            }
            outputUID = uid
            // Reconfiguring an aggregate can stop its IO; make sure it's running again.
            let running: UInt32 = aggregateID.read(kAudioDevicePropertyDeviceIsRunning, default: 0)
            if running == 0 { AudioDeviceStart(aggregateID, ioProcID) }
            return true
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

    /// Only touched by one engine's IO thread (besides the shared, read-only `gain`).
    private final class RenderState {
        let gain: GainControl
        let tapChannels: Int
        /// Gain applied at the end of the previous buffer; ramping from it avoids zipper noise.
        var currentGain: Float

        init(gain: GainControl, tapChannels: Int) {
            self.gain = gain
            self.tapChannels = tapChannels
            self.currentGain = gain.value
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

        let startGain = state.currentGain
        let endGain = state.gain.value
        state.currentGain = endGain

        for oc in 0..<totalOut {
            guard let (dst, dstStride, dstFrames) = channel(outList, oc) else { continue }

            if totalOut == 1, inChannels >= 2,
               let (l, ls, lf) = channel(inList, inOffset), let (r, rs, rf) = channel(inList, inOffset + 1) {
                let frames = min(dstFrames, lf, rf)
                for f in 0..<frames {
                    let g = startGain + (endGain - startGain) * Float(f) / Float(frames)
                    dst[f * dstStride] = clip((l[f * ls] + r[f * rs]) * 0.5 * g)
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
                let g = startGain + (endGain - startGain) * Float(f) / Float(frames)
                dst[f * dstStride] = clip(src[f * srcStride] * g)
            }
        }
    }

    @inline(__always)
    private static func clip(_ x: Float) -> Float { min(1, max(-1, x)) }
}
