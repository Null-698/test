import AVFAudio
import Foundation
import Synchronization

/// Stage 2 iPhone audio bridge.
///
/// Network audio is now native 48 kHz / mono / PCM16 / 10 ms. Playback keeps
/// that exact clock and frame size all the way into AVAudioPlayerNode. The
/// main mixer is allowed to perform any final route conversion required by
/// Receiver/Speaker/Bluetooth. There is no old 8 kHz resampler, cross-packet
/// interpolation, or +/-1-sample clock warping on the downlink path. A fixed
/// 80 ms runway and 5 ms restart fade are used only to absorb scheduling bursts
/// and prevent hard edge clicks; packet samples otherwise remain one-to-one.
enum CallAudioRouteChoice: String, CaseIterable, Identifiable, Sendable {
    case receiver
    case speaker
    case bluetooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .receiver: return "iPhone"
        case .speaker: return "Speaker"
        case .bluetooth: return "Bluetooth"
        }
    }

}


private final class MicSPSCRing {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Int16>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init(capacity: Int) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0)
        self.capacity = capacity
        self.mask = capacity - 1
        self.storage = .allocate(capacity: capacity)
        self.storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    func reset() {
        readIndex.store(0, ordering: .relaxed)
        writeIndex.store(0, ordering: .relaxed)
    }

    var depth: Int {
        max(0, writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .acquiring))
    }

    func pushFloatChannels(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frameCount: Int,
        channelCount: Int
    ) -> Bool {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard capacity - (write - read) >= frameCount else { return false }

        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][frame]
            }
            storage[(write + frame) & mask] = AudioBridge.floatToPCM16Fast(
                sum / Float(channelCount)
            )
        }
        writeIndex.store(write + frameCount, ordering: .releasing)
        return true
    }

    func pushInt16Channels(
        _ channels: UnsafePointer<UnsafeMutablePointer<Int16>>,
        frameCount: Int,
        channelCount: Int
    ) -> Bool {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard capacity - (write - read) >= frameCount else { return false }

        for frame in 0..<frameCount {
            var sum: Int32 = 0
            for channel in 0..<channelCount {
                sum += Int32(channels[channel][frame])
            }
            storage[(write + frame) & mask] = Int16(
                clamping: sum / Int32(channelCount)
            )
        }
        writeIndex.store(write + frameCount, ordering: .releasing)
        return true
    }

    func pop(into output: UnsafeMutablePointer<Int16>, count: Int) -> Bool {
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        guard write - read >= count else { return false }

        for index in 0..<count {
            output[index] = storage[(read + index) & mask]
        }
        readIndex.store(read + count, ordering: .releasing)
        return true
    }
}

final class AudioBridge {
    struct Snapshot {
        let micRMS: Int
        let remoteRMS: Int
        let playbackQueueDepth: Int
        let playbackDrops: Int
        let voiceProcessingEnabled: Bool
        let inputSampleRate: Double
        let outputSampleRate: Double
        let engineRunning: Bool
        let playerPlaying: Bool
        let scheduledBuffers: Int
        let buffersScheduledTotal: Int
        let buffersPlayedTotal: Int
        let remotePacketsEnqueued: Int
        let configurationChanges: Int
        let ioBufferDuration: Double
        let inputLatency: Double
        let outputLatency: Double
        let directBufferedFrames: Int
        let directStartFrames: Int
        let lateFrames: Int
        let sequenceGaps: Int
        let latencyDrops: Int
        let streamResets: Int
        let rendererUnderruns: Int
        let rebufferEvents: Int
        let maxPacketGapMS: Double
        let audioRoute: String
    }

    private static let networkRate = 48_000.0
    private static let networkSamplesPerFrame = 480
    private static let networkBytesPerFrame = 960
    private static let zeroNetworkFrame = Data(count: networkBytesPerFrame)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    // Playback and microphone work must never contend on the same serial queue.
    // The audio tap only writes into a preallocated SPSC ring on the native
    // 48 kHz path; packetization/UDP send happens on a dedicated worker.
    private let playbackQueue = DispatchQueue(
        label: "J6Handset.Audio.Playback48",
        qos: .userInteractive
    )
    private let micFallbackQueue = DispatchQueue(
        label: "J6Handset.Audio.MicFallback",
        qos: .userInteractive
    )
    private let statsLock = NSLock()
    private let micCallbackLock = NSLock()
    private let micSignal = DispatchSemaphore(value: 0)
    private let micRing = MicSPSCRing(capacity: 16_384)
    private let bridgeRunning = Atomic<Bool>(false)
    private let microphoneMutedAtomic = Atomic<Bool>(false)
    private let micRingDroppedSamples = Atomic<Int>(0)
    private let micWorkerGeneration = Atomic<UInt64>(0)
    private var micWorker: Thread?

    private var running = false
    private var tapInstalled = false
    private var onMicFrame: ((Data) -> Void)?

    // Fallback path used only if an HFP route exposes a non-48 kHz input. It is
    // isolated from playback so resampling/allocation cannot starve the caller.
    private var micPacketSamples: [Int16] = []
    private var micPacketReadIndex = 0
    private var micFallbackSource: [Float] = []
    private var micFallbackPosition = 0.0
    private var micFallbackRate = 0.0

    // Stage 2 Direct-48 playback. There is deliberately no adaptive jitter
    // algorithm, PLC synthesis, time-stretching, packet interpolation, or
    // sample-rate conversion here. A packet is 480 PCM16 samples at 48 kHz
    // and becomes one 480-frame AVAudioPCMBuffer at 48 kHz.
    //
    // We retain only a fixed startup/runway FIFO. UDP delivery is bursty even
    // on a local WLAN; feeding each datagram straight into a nearly empty
    // player would turn normal scheduler variation into audible underruns.
    private var remoteFIFO: [Data] = []
    private var remoteFIFOReadIndex = 0
    private let fixedStartFrames = 8       // fixed 80 ms startup/rebuffer cushion
    private let scheduleTarget = 18         // keep a deeper scheduled runway; no added steady-state latency
    private let maxRemoteFIFOFrames = 64    // bound latency if sender surges
    private let fadeSamples = 240            // 5 ms click-free fade at 48 kHz
    private var directPlaybackStarted = false
    private var fadeInNextBuffer = true
    private var lastRemoteSequence: UInt32?
    private var lastRemoteArrivalNS: UInt64?
    private var maxRemotePacketGapNS: UInt64 = 0
    private var directLateFrames = 0
    private var directSequenceGaps = 0
    private var directOverflowDrops = 0
    private var directStreamResets = 0
    private var directRebuffers = 0

    private var scheduledBuffers = 0
    private var remoteSessionID: UInt32?
    private var playbackGeneration: UInt64 = 0
    private var rendererUnderruns = 0
    private var remoteRMSSampleCounter = 0
    private var remotePacketsEnqueued = 0
    private var buffersScheduledTotal = 0
    private var buffersPlayedTotal = 0

    private var playbackFormat: AVAudioFormat?
    // AVAudioEngine graph lifecycle is intentionally persistent. iOS can throw
    // an Objective-C NSException while disconnecting/detaching a player node
    // during a CallKit / route reconfiguration. Keep the player attached and
    // connected across call-audio restarts; only stop the engine/player.
    private var playerGraphConfigured = false

    private var micRMS = 0
    private var remoteRMS = 0
    private var playbackDrops = 0
    private var voiceProcessingEnabled = false
    private var inputSampleRate = 0.0
    private var outputSampleRate = 0.0
    private var configurationChanges = 0
    private var configurationObserver: NSObjectProtocol?
    private var actualIOBufferDuration = 0.0
    private var actualInputLatency = 0.0
    private var actualOutputLatency = 0.0

    init() {
        DiagnosticLog.active?.log("AUDIO", "AudioBridge.init")
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.statsLock.lock()
            self.configurationChanges += 1
            let changes = self.configurationChanges
            self.statsLock.unlock()
            DiagnosticLog.active?.log(
                "AUDIO",
                "engine_configuration_change count=\(changes) engineRunning=\(self.engine.isRunning) playerPlaying=\(self.player.isPlaying) route=\(Self.describeCurrentRoute())"
            )
        }
    }

    deinit {
        bridgeRunning.store(false, ordering: .releasing)
        _ = micWorkerGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        micSignal.signal()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func prepareAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        DiagnosticLog.active?.log(
            "AUDIO",
            "prepare_session before category=\(session.category.rawValue) mode=\(session.mode.rawValue) rate=\(session.sampleRate) io=\(session.ioBufferDuration) route=\(Self.describeCurrentRoute())"
        )

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP]
        )

        try? session.overrideOutputAudioPort(.none)
        try? session.setPreferredSampleRate(Self.networkRate)
        try session.setPreferredIOBufferDuration(0.005)
        DiagnosticLog.active?.log(
            "AUDIO",
            "prepare_session after category=\(session.category.rawValue) mode=\(session.mode.rawValue) preferredRate=48000 preferredIO=5ms route=\(Self.describeCurrentRoute())"
        )
    }


    func availableCallRoutes() -> [CallAudioRouteChoice] {
        let session = AVAudioSession.sharedInstance()
        var result: [CallAudioRouteChoice] = [.receiver, .speaker]

        let hasBluetoothInput = session.availableInputs?.contains {
            $0.portType == .bluetoothHFP
        } ?? false
        let hasBluetoothOutput = session.currentRoute.outputs.contains {
            $0.portType == .bluetoothHFP ||
                $0.portType == .bluetoothA2DP ||
                $0.portType == .bluetoothLE
        }
        if hasBluetoothInput || hasBluetoothOutput {
            result.append(.bluetooth)
        }
        return result
    }

    func currentCallRouteChoice() -> CallAudioRouteChoice {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outputs.contains(where: {
            $0.portType == .bluetoothHFP ||
                $0.portType == .bluetoothA2DP ||
                $0.portType == .bluetoothLE
        }) {
            return .bluetooth
        }
        if outputs.contains(where: { $0.portType == .builtInSpeaker }) {
            return .speaker
        }
        return .receiver
    }

    func selectCallRoute(_ choice: CallAudioRouteChoice) throws {
        try Self.selectSystemCallRoute(choice)
    }

    /// Applies only the AVAudioSession route change. This is intentionally
    /// static so callers can perform the potentially blocking system route
    /// operation away from the main UI actor without moving the AudioBridge
    /// engine object across concurrency domains.
    static func selectSystemCallRoute(_ choice: CallAudioRouteChoice) throws {
        let session = AVAudioSession.sharedInstance()
        let builtInMic = session.availableInputs?.first {
            $0.portType == .builtInMic
        }

        switch choice {
        case .receiver:
            try session.overrideOutputAudioPort(.none)
            if let builtInMic {
                try session.setPreferredInput(builtInMic)
            }

        case .speaker:
            if let builtInMic {
                try session.setPreferredInput(builtInMic)
            }
            try session.overrideOutputAudioPort(.speaker)

        case .bluetooth:
            guard let bluetooth = session.availableInputs?.first(where: {
                $0.portType == .bluetoothHFP
            }) else {
                throw AudioError.bluetoothRouteUnavailable
            }
            // Clearing the speaker override before selecting HFP lets iOS
            // route both input and output to the chosen Bluetooth call device.
            try session.overrideOutputAudioPort(.none)
            try session.setPreferredInput(bluetooth)
        }
    }

    func start(
        audioSessionAlreadyActive: Bool = false,
        onMicFrame: @escaping (Data) -> Void
    ) throws {
        DiagnosticLog.active?.log(
            "AUDIO",
            "start begin sessionAlreadyActive=\(audioSessionAlreadyActive) engine=\(engine.isRunning) player=\(player.isPlaying) graphConfigured=\(playerGraphConfigured)"
        )
        stop(deactivateSession: !audioSessionAlreadyActive)

        micCallbackLock.lock()
        self.onMicFrame = onMicFrame
        micCallbackLock.unlock()

        let session = AVAudioSession.sharedInstance()

        if !audioSessionAlreadyActive {
            try prepareAudioSession()
            try session.setActive(true)
            DiagnosticLog.active?.log(
                "AUDIO",
                "session_set_active true rate=\(session.sampleRate) io=\(session.ioBufferDuration) route=\(Self.describeCurrentRoute())"
            )
        } else {
            DiagnosticLog.active?.log(
                "AUDIO",
                "using_CallKit_active_session rate=\(session.sampleRate) io=\(session.ioBufferDuration) route=\(Self.describeCurrentRoute())"
            )
        }

        // Respect the route selected by CallKit/the user. The old build
        // automatically preferred any connected HFP device on every audio
        // restart, which made Speaker/Receiver appear to snap back to AirPods.
        let inputNode = engine.inputNode

        do {
            try inputNode.setVoiceProcessingEnabled(true)
            voiceProcessingEnabled = inputNode.isVoiceProcessingEnabled
            DiagnosticLog.active?.log(
                "AUDIO",
                "voice_processing enabled=\(voiceProcessingEnabled)"
            )
        } catch {
            voiceProcessingEnabled = false
            DiagnosticLog.active?.log(
                "AUDIO",
                "voice_processing FAILED error=\(error.localizedDescription)"
            )
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0
        else {
            throw AudioError.invalidInputFormat
        }

        // Critical Stage 2 change: the player node input is always the network
        // format, not the device output rate. mainMixerNode performs any final
        // hardware-route conversion after our exact 48 kHz telephony stream.
        guard let networkPlaybackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.networkRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioError.invalidOutputFormat
        }

        playbackFormat = networkPlaybackFormat
        inputSampleRate = inputFormat.sampleRate

        let outputNode = engine.outputNode
        let hardwareOutput = outputNode.inputFormat(forBus: 0)
        let mixerBefore = engine.mainMixerNode.outputFormat(forBus: 0)

        DiagnosticLog.active?.log(
            "AUDIO",
            "formats_before input=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch mixer=\(mixerBefore.sampleRate)Hz/\(mixerBefore.channelCount)ch outputHW=\(hardwareOutput.sampleRate)Hz/\(hardwareOutput.channelCount)ch sessionRate=\(session.sampleRate) playback=48000Hz/1ch route=\(Self.describeCurrentRoute())"
        )

        // Configure the player graph only once. AVAudioEngine.stop() preserves
        // the graph, so there is no reason to detach/reconnect on every call or
        // watchdog restart. Avoiding graph teardown is critical on iOS 26:
        // disconnectNodeOutput can raise an Objective-C NSException while the
        // CallKit audio session is being reconfigured.
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
            DiagnosticLog.active?.log("AUDIO", "player attached")
        }

        if !playerGraphConfigured {
            engine.connect(
                player,
                to: engine.mainMixerNode,
                format: networkPlaybackFormat
            )

            // The previous build accepted a 48 kHz player input while the
            // main mixer stayed at 44.1 kHz. For the built-in call route the
            // active AVAudioSession/output hardware is 48 kHz, so explicitly
            // pin mainMixer -> outputNode to that hardware format. This keeps
            // the entire app-side downlink graph at 48 kHz. If a Bluetooth
            // route later requires another hardware rate, Core Audio performs
            // only that unavoidable final route conversion.
            if hardwareOutput.sampleRate > 0,
               hardwareOutput.channelCount > 0,
               abs(hardwareOutput.sampleRate - Self.networkRate) < 1.0 {
                engine.connect(
                    engine.mainMixerNode,
                    to: outputNode,
                    format: hardwareOutput
                )
                DiagnosticLog.active?.log(
                    "AUDIO",
                    "direct48 mixer_to_output pinned=\(hardwareOutput.sampleRate)Hz/\(hardwareOutput.channelCount)ch"
                )
            } else {
                DiagnosticLog.active?.log(
                    "AUDIO",
                    "direct48 mixer_to_output not_pinned outputHW=\(hardwareOutput.sampleRate)Hz/\(hardwareOutput.channelCount)ch"
                )
            }

            playerGraphConfigured = true
            DiagnosticLog.active?.log(
                "AUDIO",
                "player connected direct48 format=48000/mono/float32"
            )
        }

        let mixerOutput = engine.mainMixerNode.outputFormat(forBus: 0)
        outputSampleRate = mixerOutput.sampleRate > 0
            ? mixerOutput.sampleRate
            : session.sampleRate
        DiagnosticLog.active?.log(
            "AUDIO",
            "formats_after mixer=\(mixerOutput.sampleRate)Hz/\(mixerOutput.channelCount)ch outputHW=\(outputNode.inputFormat(forBus: 0).sampleRate)Hz/\(outputNode.inputFormat(forBus: 0).channelCount)ch"
        )

        let requestedTapFrames = AVAudioFrameCount(
            max(128, Int((inputFormat.sampleRate * 0.005).rounded()))
        )

        inputNode.installTap(
            onBus: 0,
            bufferSize: requestedTapFrames,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.captureInputBuffer(buffer)
        }
        tapInstalled = true
        DiagnosticLog.active?.log(
            "AUDIO",
            "mic_tap installed requestedFrames=\(requestedTapFrames) inputRate=\(inputFormat.sampleRate)"
        )

        engine.prepare()
        try engine.start()
        DiagnosticLog.active?.log(
            "AUDIO",
            "engine_started engine=\(engine.isRunning) player=\(player.isPlaying) outputVolume=\(session.outputVolume) route=\(Self.describeCurrentRoute())"
        )

        statsLock.lock()
        actualIOBufferDuration = session.ioBufferDuration
        actualInputLatency = session.inputLatency
        actualOutputLatency = session.outputLatency
        statsLock.unlock()

        playbackQueue.sync {
            running = true
            resetDirectPlaybackState(resetCounters: true)
            scheduledBuffers = 0
            remoteSessionID = nil
            playbackGeneration &+= 1
            rendererUnderruns = 0
            remoteRMSSampleCounter = 0
            remotePacketsEnqueued = 0
            buffersScheduledTotal = 0
            buffersPlayedTotal = 0
        }

        micFallbackQueue.sync {
            micPacketSamples.removeAll(keepingCapacity: true)
            micPacketReadIndex = 0
            micFallbackSource.removeAll(keepingCapacity: true)
            micFallbackPosition = 0
            micFallbackRate = inputFormat.sampleRate
        }
        micRing.reset()
        micRingDroppedSamples.store(0, ordering: .relaxed)
        bridgeRunning.store(true, ordering: .releasing)
        if abs(inputFormat.sampleRate - Self.networkRate) < 1.0 {
            let generation = micWorkerGeneration.wrappingAdd(
                1,
                ordering: .acquiringAndReleasing
            ).newValue
            startMicWorker(generation: generation)
        }

        DiagnosticLog.active?.log(
            "AUDIO",
            "start ready io=\(session.ioBufferDuration)s inLatency=\(session.inputLatency)s outLatency=\(session.outputLatency)s"
        )
    }

    func stop(deactivateSession: Bool = true) {
        DiagnosticLog.active?.log(
            "AUDIO",
            "stop begin deactivateSession=\(deactivateSession) engine=\(engine.isRunning) player=\(player.isPlaying) tap=\(tapInstalled)"
        )
        bridgeRunning.store(false, ordering: .releasing)
        _ = micWorkerGeneration.wrappingAdd(1, ordering: .acquiringAndReleasing)
        micSignal.signal()

        playbackQueue.sync {
            running = false
            playbackGeneration &+= 1
            resetDirectPlaybackState(resetCounters: false)
            scheduledBuffers = 0
            remoteSessionID = nil
        }

        micFallbackQueue.async { [weak self] in
            self?.micPacketSamples.removeAll(keepingCapacity: true)
            self?.micPacketReadIndex = 0
            self?.micFallbackSource.removeAll(keepingCapacity: true)
            self?.micFallbackPosition = 0
        }
        micRing.reset()

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        player.stop()
        engine.stop()

        // Deliberately DO NOT disconnect or detach `player` here. Crash reports
        // from the device show AVAudioEngine.disconnectNodeOutput raising an
        // NSException during restart. The graph is reusable after engine.stop().
        playbackFormat = nil
        micCallbackLock.lock()
        onMicFrame = nil
        micCallbackLock.unlock()

        if deactivateSession {
            do {
                try AVAudioSession.sharedInstance().setActive(
                    false,
                    options: [.notifyOthersOnDeactivation]
                )
                DiagnosticLog.active?.log("AUDIO", "session_set_active false")
            } catch {
                DiagnosticLog.active?.log(
                    "AUDIO",
                    "session_deactivate FAILED error=\(error.localizedDescription)"
                )
            }
        }
        DiagnosticLog.active?.log(
            "AUDIO",
            "stop complete engine=\(engine.isRunning) player=\(player.isPlaying)"
        )
    }

    /// Recover a transient Core Audio stop without tearing down UDP, the
    /// player graph, or the packet sessions. This is intentionally minimal:
    /// if iOS can restart the existing graph in place we keep the call stream
    /// continuous; RelayController escalates only if this fails repeatedly.
    func recoverEngineInPlace() -> Bool {
        if engine.isRunning { return true }
        guard bridgeRunning.load(ordering: .acquiring) else { return false }

        do {
            engine.prepare()
            try engine.start()
            playbackQueue.async { [weak self] in
                guard let self else { return }
                if self.scheduledBuffers > 0 && !self.player.isPlaying {
                    self.player.play()
                }
                self.fillPlaybackSchedule()
            }
            DiagnosticLog.active?.log(
                "AUDIO",
                "engine_recover_in_place success engine=\(engine.isRunning) player=\(player.isPlaying) route=\(Self.describeCurrentRoute())"
            )
            return engine.isRunning
        } catch {
            DiagnosticLog.active?.log(
                "AUDIO",
                "engine_recover_in_place FAILED error=\(error.localizedDescription) route=\(Self.describeCurrentRoute())"
            )
            return false
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMutedAtomic.store(muted, ordering: .releasing)
    }

    func enqueueRemotePacket(_ packet: AudioWirePacket) {
        playbackQueue.async { [weak self] in
            guard let self, self.running else {
                DiagnosticLog.active?.log("AUDIO", "remote_packet dropped bridge_not_running")
                return
            }

            self.remotePacketsEnqueued += 1

            self.remoteRMSSampleCounter += 1
            if self.remoteRMSSampleCounter >= 10 {
                self.remoteRMSSampleCounter = 0
                let rms = Self.rmsOfPCM16LE(packet.pcm)
                self.statsLock.lock()
                self.remoteRMS = rms
                self.statsLock.unlock()
            }

            if let currentSession = self.remoteSessionID,
               currentSession != packet.sessionID {
                DiagnosticLog.active?.log(
                    "REMOTE",
                    "session_change old=\(currentSession) new=\(packet.sessionID) seq=\(packet.sequence)"
                )
                self.directStreamResets += 1
                self.softPlaybackTransitionForStreamChange()
            }

            self.remoteSessionID = packet.sessionID

            if let previousArrival = self.lastRemoteArrivalNS,
               packet.arrivalUptimeNS >= previousArrival {
                self.maxRemotePacketGapNS = max(
                    self.maxRemotePacketGapNS,
                    packet.arrivalUptimeNS - previousArrival
                )
            }
            self.lastRemoteArrivalNS = packet.arrivalUptimeNS

            if let lastSequence = self.lastRemoteSequence {
                let distance = AudioWirePacket.signedDistance(
                    packet.sequence,
                    lastSequence
                )

                if distance <= 0 {
                    self.directLateFrames += 1
                    if self.directLateFrames <= 3 || self.directLateFrames % 100 == 0 {
                        DiagnosticLog.active?.log(
                            "REMOTE",
                            "direct48 drop late_or_duplicate seq=\(packet.sequence) last=\(lastSequence) count=\(self.directLateFrames)"
                        )
                    }
                    return
                }

                if distance > 2_000 {
                    self.directStreamResets += 1
                    DiagnosticLog.active?.log(
                        "REMOTE",
                        "direct48 sequence_jump last=\(lastSequence) new=\(packet.sequence) distance=\(distance)"
                    )
                    self.softPlaybackTransitionForStreamChange()
                } else if distance > 1 {
                    self.directSequenceGaps += Int(distance - 1)
                    DiagnosticLog.active?.log(
                        "REMOTE",
                        "direct48 sequence_gap missing=\(distance - 1) last=\(lastSequence) new=\(packet.sequence) total=\(self.directSequenceGaps)"
                    )
                }
            }

            self.lastRemoteSequence = packet.sequence
            self.appendDirectRemoteFrame(packet.pcm)
            self.fillPlaybackSchedule()
        }
    }

    func snapshot() -> Snapshot {
        statsLock.lock()
        let micRMS = micRMS
        let remoteRMS = remoteRMS
        let voice = voiceProcessingEnabled
        let inRate = inputSampleRate
        let outRate = outputSampleRate
        let configChanges = configurationChanges
        let ioDuration = actualIOBufferDuration
        let inputLatency = actualInputLatency
        let outputLatency = actualOutputLatency
        statsLock.unlock()

        let engineRunning = engine.isRunning

        var queueDepth = 0
        var rendererUnderruns = 0
        var drops = 0
        var scheduled = 0
        var scheduledTotal = 0
        var playedTotal = 0
        var remoteEnqueued = 0
        var fifoDepth = 0
        var late = 0
        var gaps = 0
        var overflow = 0
        var resets = 0
        var rebuffers = 0
        var maxGapMS = 0.0

        playbackQueue.sync {
            fifoDepth = self.directFIFOCount
            rendererUnderruns = self.rendererUnderruns
            overflow = self.directOverflowDrops
            drops = self.playbackDrops + overflow
            scheduled = self.scheduledBuffers
            scheduledTotal = self.buffersScheduledTotal
            playedTotal = self.buffersPlayedTotal
            remoteEnqueued = self.remotePacketsEnqueued
            queueDepth = fifoDepth + scheduled
            late = self.directLateFrames
            gaps = self.directSequenceGaps
            resets = self.directStreamResets
            rebuffers = self.directRebuffers
            maxGapMS = Double(self.maxRemotePacketGapNS) / 1_000_000.0
        }

        return Snapshot(
            micRMS: micRMS,
            remoteRMS: remoteRMS,
            playbackQueueDepth: queueDepth,
            playbackDrops: drops,
            voiceProcessingEnabled: voice,
            inputSampleRate: inRate,
            outputSampleRate: outRate,
            engineRunning: engineRunning,
            playerPlaying: player.isPlaying,
            scheduledBuffers: scheduled,
            buffersScheduledTotal: scheduledTotal,
            buffersPlayedTotal: playedTotal,
            remotePacketsEnqueued: remoteEnqueued,
            configurationChanges: configChanges,
            ioBufferDuration: ioDuration,
            inputLatency: inputLatency,
            outputLatency: outputLatency,
            directBufferedFrames: fifoDepth,
            directStartFrames: fixedStartFrames,
            lateFrames: late,
            sequenceGaps: gaps,
            latencyDrops: overflow,
            streamResets: resets,
            rendererUnderruns: rendererUnderruns,
            rebufferEvents: rebuffers,
            maxPacketGapMS: maxGapMS,
            audioRoute: Self.describeCurrentRoute()
        )
    }

    private func captureInputBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, bridgeRunning.load(ordering: .acquiring) else { return }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return }

        let rate = buffer.format.sampleRate
        if abs(rate - Self.networkRate) < 1.0 {
            let pushed: Bool
            if let channels = buffer.floatChannelData {
                pushed = micRing.pushFloatChannels(
                    channels,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            } else if let channels = buffer.int16ChannelData {
                pushed = micRing.pushInt16Channels(
                    channels,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            } else {
                return
            }

            if pushed {
                micSignal.signal()
            } else {
                micRingDroppedSamples.wrappingAdd(
                    frameCount,
                    ordering: .relaxed
                )
            }
            return
        }

        // Non-48 kHz HFP fallback. This copy never shares the playback queue.
        var mono = [Float](repeating: 0, count: frameCount)
        if let channels = buffer.floatChannelData {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channels[channel][frame] }
                mono[frame] = sum / Float(channelCount)
            }
        } else if let channels = buffer.int16ChannelData {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += Float(channels[channel][frame]) / 32768.0
                }
                mono[frame] = sum / Float(channelCount)
            }
        } else {
            return
        }

        micFallbackQueue.async { [weak self] in
            self?.processMicSamples(mono, inputRate: rate)
        }
    }

    private func startMicWorker(generation: UInt64) {
        let worker = Thread { [weak self] in
            self?.runMicWorker(generation: generation)
        }
        worker.name = "J6MicPacketWorker"
        worker.qualityOfService = .userInteractive
        micWorker = worker
        worker.start()
    }

    private func runMicWorker(generation: UInt64) {
        let scratch = UnsafeMutablePointer<Int16>.allocate(
            capacity: Self.networkSamplesPerFrame
        )
        defer { scratch.deallocate() }

        while bridgeRunning.load(ordering: .acquiring),
              micWorkerGeneration.load(ordering: .acquiring) == generation {
            _ = micSignal.wait(timeout: .now() + .milliseconds(100))
            guard bridgeRunning.load(ordering: .acquiring),
                  micWorkerGeneration.load(ordering: .acquiring) == generation
            else { break }

            while micRing.pop(
                into: scratch,
                count: Self.networkSamplesPerFrame
            ) {
                emitDirectMicPacket(from: scratch)
                if !bridgeRunning.load(ordering: .acquiring) ||
                    micWorkerGeneration.load(ordering: .acquiring) != generation {
                    break
                }
            }
        }
    }

    private func emitDirectMicPacket(from samples: UnsafePointer<Int16>) {
        let muted = microphoneMutedAtomic.load(ordering: .acquiring)
        let frame: Data
        let rms: Int

        if muted {
            frame = Self.zeroNetworkFrame
            rms = 0
        } else {
            var sum = 0.0
            var data = Data(count: Self.networkBytesPerFrame)
            data.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for index in 0..<Self.networkSamplesPerFrame {
                    let sample = samples[index]
                    let value = UInt16(bitPattern: sample)
                    bytes[index * 2] = UInt8(value & 0xff)
                    bytes[index * 2 + 1] = UInt8((value >> 8) & 0xff)
                    let numeric = Double(sample)
                    sum += numeric * numeric
                }
            }
            frame = data
            rms = Int(sqrt(sum / Double(Self.networkSamplesPerFrame)))
        }

        statsLock.lock()
        micRMS = rms
        statsLock.unlock()

        micCallbackLock.lock()
        let callback = onMicFrame
        micCallbackLock.unlock()
        callback?(frame)
    }

    private func processMicSamples(
        _ samples: [Float],
        inputRate: Double
    ) {
        guard bridgeRunning.load(ordering: .acquiring), inputRate > 0 else { return }

        if abs(inputRate - Self.networkRate) < 1.0 {
            // Native Stage 2 fast path: no sample-rate conversion.
            if abs(micFallbackRate - inputRate) >= 1.0 {
                resetMicFallback(rate: inputRate)
            }

            appendMicFloatSamples(samples)
            emitCompleteMicPackets()
            return
        }

        // Route-rate fallback for Bluetooth or another non-48k input format.
        processMicFallbackResample(samples, inputRate: inputRate)
    }

    private func appendMicFloatSamples(_ samples: [Float]) {
        micPacketSamples.reserveCapacity(
            micPacketSamples.count + samples.count
        )

        for sample in samples {
            micPacketSamples.append(Self.floatToPCM16Fast(sample))
        }
    }

    private func processMicFallbackResample(
        _ samples: [Float],
        inputRate: Double
    ) {
        if abs(micFallbackRate - inputRate) > 0.5 {
            resetMicFallback(rate: inputRate)
        }

        micFallbackSource.append(contentsOf: samples)

        let step = inputRate / Self.networkRate
        guard step > 0 else { return }

        while micFallbackPosition + 1.0 < Double(micFallbackSource.count) {
            let base = Int(micFallbackPosition)
            let fraction = Float(
                micFallbackPosition - Double(base)
            )

            let a = micFallbackSource[base]
            let b = micFallbackSource[base + 1]
            let sample = a + (b - a) * fraction

            micPacketSamples.append(Self.floatToPCM16Fast(sample))
            micFallbackPosition += step
        }

        let consumed = Int(micFallbackPosition)
        if consumed > 4_096 {
            let removeCount = consumed - 1
            micFallbackSource.removeFirst(removeCount)
            micFallbackPosition -= Double(removeCount)
        }

        emitCompleteMicPackets()
    }

    private func resetMicFallback(rate: Double) {
        micFallbackSource.removeAll(keepingCapacity: true)
        micFallbackPosition = 0
        micFallbackRate = rate
    }

    private func emitCompleteMicPackets() {
        while micPacketSamples.count - micPacketReadIndex >= Self.networkSamplesPerFrame {
            let start = micPacketReadIndex
            let frame: Data
            let rms: Int

            if microphoneMutedAtomic.load(ordering: .acquiring) {
                frame = Self.zeroNetworkFrame
                rms = 0
            } else {
                var sum = 0.0
                var data = Data(count: Self.networkBytesPerFrame)

                data.withUnsafeMutableBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)

                    for index in 0..<Self.networkSamplesPerFrame {
                        let sample = micPacketSamples[start + index]
                        let value = UInt16(bitPattern: sample)

                        bytes[index * 2] = UInt8(value & 0xff)
                        bytes[index * 2 + 1] = UInt8((value >> 8) & 0xff)

                        let numeric = Double(sample)
                        sum += numeric * numeric
                    }
                }

                frame = data
                rms = Int(
                    sqrt(sum / Double(Self.networkSamplesPerFrame))
                )
            }

            micPacketReadIndex += Self.networkSamplesPerFrame

            if micPacketReadIndex >= Self.networkSamplesPerFrame * 16 {
                micPacketSamples.removeFirst(micPacketReadIndex)
                micPacketReadIndex = 0
            }

            statsLock.lock()
            micRMS = rms
            statsLock.unlock()

            micCallbackLock.lock()
            let callback = onMicFrame
            micCallbackLock.unlock()
            callback?(frame)
        }
    }

    private var directFIFOCount: Int {
        max(0, remoteFIFO.count - remoteFIFOReadIndex)
    }

    private func resetDirectPlaybackState(resetCounters: Bool) {
        remoteFIFO.removeAll(keepingCapacity: true)
        remoteFIFOReadIndex = 0
        directPlaybackStarted = false
        fadeInNextBuffer = true
        lastRemoteSequence = nil
        lastRemoteArrivalNS = nil

        if resetCounters {
            maxRemotePacketGapNS = 0
            directLateFrames = 0
            directSequenceGaps = 0
            directOverflowDrops = 0
            directStreamResets = 0
            directRebuffers = 0
        }
    }

    private func appendDirectRemoteFrame(_ frame: Data) {
        remoteFIFO.append(frame)

        while directFIFOCount > maxRemoteFIFOFrames {
            remoteFIFOReadIndex += 1
            directOverflowDrops += 1
        }

        compactDirectFIFOIfNeeded()
    }

    private func popDirectRemoteFrame() -> Data? {
        guard remoteFIFOReadIndex < remoteFIFO.count else {
            return nil
        }

        let frame = remoteFIFO[remoteFIFOReadIndex]
        remoteFIFOReadIndex += 1
        compactDirectFIFOIfNeeded()
        return frame
    }

    private func compactDirectFIFOIfNeeded() {
        if remoteFIFOReadIndex >= 256 ||
            (remoteFIFOReadIndex > 0 && remoteFIFOReadIndex * 2 >= remoteFIFO.count) {
            remoteFIFO.removeFirst(remoteFIFOReadIndex)
            remoteFIFOReadIndex = 0
        }
    }

    private func softPlaybackTransitionForStreamChange() {
        // Preserve already-scheduled native 48 kHz audio across a sender-session
        // change. Stopping AVAudioPlayerNode here used to manufacture a hard
        // discontinuity at DIALING -> ACTIVE even when Samsung's PCM was otherwise
        // continuous. Drop only unscheduled stale FIFO data and let the existing
        // runway drain naturally into the new session.
        remoteFIFO.removeAll(keepingCapacity: true)
        remoteFIFOReadIndex = 0
        lastRemoteSequence = nil
        lastRemoteArrivalNS = nil
        directPlaybackStarted = scheduledBuffers > 0
        if scheduledBuffers == 0 {
            fadeInNextBuffer = true
        }
        DiagnosticLog.active?.log(
            "RENDER",
            "direct48 soft_session_transition inFlight=\(scheduledBuffers) player=\(player.isPlaying)"
        )
    }

    private func fillPlaybackSchedule() {
        guard running else { return }

        if !directPlaybackStarted {
            guard directFIFOCount >= fixedStartFrames else {
                return
            }
            directPlaybackStarted = true
            DiagnosticLog.active?.log(
                "RENDER",
                "direct48 START fifo=\(directFIFOCount) fixedStart=\(fixedStartFrames) scheduleTarget=\(scheduleTarget)"
            )
        }

        let generation = playbackGeneration

        while scheduledBuffers < scheduleTarget,
              let frame = popDirectRemoteFrame() {
            let applyFadeIn = fadeInNextBuffer
            if applyFadeIn { fadeInNextBuffer = false }

            guard let buffer = makeNative48kPlaybackBuffer(
                from: frame,
                fadeIn: applyFadeIn
            ) else {
                if applyFadeIn { fadeInNextBuffer = true }
                playbackDrops += 1
                DiagnosticLog.active?.log(
                    "RENDER",
                    "make_buffer FAILED drops=\(playbackDrops) bytes=\(frame.count)"
                )
                continue
            }

            scheduledBuffers += 1
            buffersScheduledTotal += 1
            player.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard let self else { return }

                self.playbackQueue.async {
                    guard generation == self.playbackGeneration else {
                        return
                    }

                    self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
                    self.buffersPlayedTotal += 1
                    self.fillPlaybackSchedule()

                    if self.scheduledBuffers == 0,
                       self.running,
                       self.remoteSessionID != nil {
                        self.rendererUnderruns += 1
                        self.directRebuffers += 1
                        self.directPlaybackStarted = false
                        self.fadeInNextBuffer = true
                        DiagnosticLog.active?.log(
                            "RENDER",
                            "direct48 UNDERRUN count=\(self.rendererUnderruns) rebuffer=\(self.directRebuffers) fifo=\(self.directFIFOCount)"
                        )
                    }
                }
            }
        }

        if scheduledBuffers > 0 && !player.isPlaying {
            player.play()
            DiagnosticLog.active?.log(
                "RENDER",
                "direct48 player.play inFlight=\(scheduledBuffers) fifo=\(directFIFOCount) engine=\(engine.isRunning) route=\(Self.describeCurrentRoute())"
            )
        }
    }

    private func makeNative48kPlaybackBuffer(
        from frame: Data,
        fadeIn: Bool
    ) -> AVAudioPCMBuffer? {
        guard frame.count == Self.networkBytesPerFrame,
              let playbackFormat,
              abs(playbackFormat.sampleRate - Self.networkRate) < 0.5
        else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(Self.networkSamplesPerFrame)
        ),
        let output = buffer.floatChannelData?[0]
        else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(Self.networkSamplesPerFrame)

        frame.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)

            for index in 0..<Self.networkSamplesPerFrame {
                let offset = index * 2
                let value =
                    UInt16(bytes[offset]) |
                    (UInt16(bytes[offset + 1]) << 8)
                let sample = Int16(bitPattern: value)
                var valueFloat = Float(sample) / 32768.0
                if fadeIn && index < fadeSamples && fadeSamples > 1 {
                    valueFloat *= Float(index) / Float(fadeSamples - 1)
                }
                output[index] = valueFloat
            }
        }

        return buffer
    }

    fileprivate static func floatToPCM16Fast(_ sample: Float) -> Int16 {
        let bounded = min(1.0, max(-1.0, sample))
        let scaled = Int((bounded * 32767.0).rounded())
        return Int16(clamping: scaled)
    }

    private static func describeCurrentRoute() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute

        let outputs = route.outputs.map { routePortLabel($0) }
        let inputs = route.inputs.map { routePortLabel($0) }

        let outputText =
            outputs.isEmpty ? "No output" : outputs.joined(separator: ", ")
        let inputText =
            inputs.isEmpty ? "No input" : inputs.joined(separator: ", ")

        return outputText + " ← " + inputText
    }

    private static func routePortLabel(
        _ port: AVAudioSessionPortDescription
    ) -> String {
        let type: String

        switch port.portType {
        case .bluetoothHFP:
            type = "Bluetooth HFP"
        case .bluetoothA2DP:
            type = "Bluetooth A2DP"
        case .bluetoothLE:
            type = "Bluetooth LE"
        case .builtInSpeaker:
            type = "Speaker"
        case .builtInReceiver:
            type = "Receiver"
        case .builtInMic:
            type = "iPhone mic"
        case .headphones:
            type = "Headphones"
        case .headsetMic:
            type = "Headset mic"
        default:
            type = port.portType.rawValue
        }

        if port.portName.isEmpty {
            return type
        }

        return port.portName + " (" + type + ")"
    }

    private static func rmsOfPCM16LE(_ data: Data) -> Int {
        guard data.count >= 2 else { return 0 }

        var sum = 0.0
        var count = 0

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0

            while index + 1 < bytes.count {
                let raw =
                    UInt16(bytes[index]) |
                    (UInt16(bytes[index + 1]) << 8)
                let sample = Int16(bitPattern: raw)
                let value = Double(sample)

                sum += value * value
                count += 1
                index += 2
            }
        }

        guard count > 0 else { return 0 }
        return Int(sqrt(sum / Double(count)))
    }

    enum AudioError: Error {
        case invalidInputFormat
        case invalidOutputFormat
        case bluetoothRouteUnavailable
    }
}
