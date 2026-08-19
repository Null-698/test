import AVFAudio
import Foundation

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
        let configurationChanges: Int
        let ioBufferDuration: Double
        let inputLatency: Double
        let outputLatency: Double
        let jitterBufferedFrames: Int
        let jitterTargetFrames: Int
        let jitterMS: Double
        let plcFrames: Int
        let lateFrames: Int
        let latencyDrops: Int
        let clockShortens: Int
        let clockStretches: Int
        let streamResets: Int
        let audioRoute: String
    }

    private static let networkRate = 8_000.0
    private static let networkSamplesPerFrame = 80
    private static let networkBytesPerFrame = 160

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private let audioQueue = DispatchQueue(label: "J6Handset.Audio")
    private let statsLock = NSLock()

    private var running = false
    private var tapInstalled = false
    private var onMicFrame: ((Data) -> Void)?

    // Microphone streaming resampler state.
    private var micInputSamples: [Float] = []
    private var micPosition = 0.0
    private var micInputRate = 0.0
    private var micPacketSamples: [Int16] = []

    // Remote playback. Packet arrival feeds a timestamp/sequence jitter
    // buffer; AVAudioPlayerNode remains the continuous hardware clock.
    private let remoteJitter = AudioJitterBuffer()
    private var scheduledBuffers = 0
    private let scheduleTarget = 4

    // Hold one 10 ms frame so resampling can interpolate continuously into
    // the first sample of the following packet. This removes the old packet
    // boundary discontinuity repeating 100 times per second.
    private var pendingPlaybackOutput: AudioJitterBuffer.Output?
    private var remoteSessionID: UInt32?

    private var playbackFormat: AVAudioFormat?

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
    private var microphoneMuted = false

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.statsLock.lock()
            self.configurationChanges += 1
            self.statsLock.unlock()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func prepareAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        let options: AVAudioSession.CategoryOptions = [
            .allowBluetoothHFP
        ]

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )

        try? session.overrideOutputAudioPort(.none)

        try? session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.005)
    }

    private func preferBluetoothCallRouteIfAvailable() {
        let session = AVAudioSession.sharedInstance()

        guard let inputs = session.availableInputs else {
            return
        }

        let bluetoothInputs = inputs.filter {
            $0.portType == .bluetoothHFP
        }

        guard !bluetoothInputs.isEmpty else {
            return
        }

        let currentBluetoothName =
            session.currentRoute.inputs.first(where: {
                $0.portType == .bluetoothHFP
            })?.portName
            ?? session.currentRoute.outputs.first(where: {
                $0.portType == .bluetoothHFP ||
                $0.portType == .bluetoothA2DP ||
                $0.portType == .bluetoothLE
            })?.portName

        let selected: AVAudioSessionPortDescription?

        if let currentBluetoothName {
            selected =
                bluetoothInputs.first(where: {
                    $0.portName == currentBluetoothName
                })
                ?? bluetoothInputs.first
        } else if bluetoothInputs.count == 1 {
            selected = bluetoothInputs[0]
        } else {
            selected = nil
        }

        if let selected {
            try? session.setPreferredInput(selected)
        }
    }

    func start(
        audioSessionAlreadyActive: Bool = false,
        onMicFrame: @escaping (Data) -> Void
    ) throws {
        stop(deactivateSession: !audioSessionAlreadyActive)

        self.onMicFrame = onMicFrame

        let session = AVAudioSession.sharedInstance()

        // When CallKit has already activated the session, do not reapply the
        // category here. That can disturb the route iOS just selected.
        if !audioSessionAlreadyActive {
            try prepareAudioSession()
            try session.setActive(true)
        }

        // Prefer a connected two-way Bluetooth call route (AirPods/headset)
        // when the choice is unambiguous.
        preferBluetoothCallRouteIfAvailable()

        let inputNode = engine.inputNode

        // Voice processing provides the iPhone-side echo cancellation /
        // voice processing that is appropriate for this two-way voice link.
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            voiceProcessingEnabled = inputNode.isVoiceProcessingEnabled
        } catch {
            // Keep the prototype usable even if the current route does not
            // permit voice processing. Headphones remain a good fallback.
            voiceProcessingEnabled = false
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.invalidInputFormat
        }

        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let deviceOutputRate = mixerFormat.sampleRate > 0
            ? mixerFormat.sampleRate
            : session.sampleRate

        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: deviceOutputRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioError.invalidOutputFormat
        }

        self.playbackFormat = playbackFormat
        inputSampleRate = inputFormat.sampleRate
        outputSampleRate = deviceOutputRate

        engine.attach(player)
        engine.connect(
            player,
            to: engine.mainMixerNode,
            format: playbackFormat
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

        engine.prepare()
        try engine.start()
        player.play()

        statsLock.lock()
        actualIOBufferDuration = session.ioBufferDuration
        actualInputLatency = session.inputLatency
        actualOutputLatency = session.outputLatency
        statsLock.unlock()

        audioQueue.sync {
            running = true
            micInputSamples.removeAll(keepingCapacity: true)
            micPacketSamples.removeAll(keepingCapacity: true)
            micPosition = 0
            micInputRate = inputFormat.sampleRate

            remoteJitter.reset()
            scheduledBuffers = 0
            pendingPlaybackOutput = nil
            remoteSessionID = nil
        }
    }

    func stop(deactivateSession: Bool = true) {
        audioQueue.sync {
            running = false
            remoteJitter.reset()
            scheduledBuffers = 0
            pendingPlaybackOutput = nil
            remoteSessionID = nil

            micInputSamples.removeAll()
            micPacketSamples.removeAll()
            micPosition = 0
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        player.stop()
        engine.stop()

        if engine.attachedNodes.contains(player) {
            engine.detach(player)
        }

        playbackFormat = nil
        onMicFrame = nil

        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        audioQueue.async { [weak self] in
            self?.microphoneMuted = muted
        }
    }

    func enqueueRemotePacket(_ packet: AudioWirePacket) {
        let rms = Self.rmsOfPCM16LE(packet.pcm)
        statsLock.lock()
        remoteRMS = rms
        statsLock.unlock()

        audioQueue.async { [weak self] in
            guard let self, self.running else { return }

            let streamChanged =
                self.remoteSessionID != nil &&
                self.remoteSessionID != packet.sessionID

            if streamChanged {
                // DIALING ringback and ACTIVE speech have different sender
                // sessions. Flush scheduled ringback before live speech.
                self.player.stop()
                self.scheduledBuffers = 0
                self.pendingPlaybackOutput = nil
            }

            self.remoteSessionID = packet.sessionID
            self.remoteJitter.push(packet)
            self.fillPlaybackSchedule()
        }
    }

    func snapshot() -> Snapshot {
        statsLock.lock()
        let micRMS = micRMS
        let remoteRMS = remoteRMS
        let drops = playbackDrops
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
        var jitterStats: AudioJitterBuffer.Snapshot!
        audioQueue.sync {
            jitterStats = remoteJitter.snapshot()
            queueDepth =
                jitterStats.bufferedFrames +
                scheduledBuffers +
                (pendingPlaybackOutput == nil ? 0 : 1)
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
            configurationChanges: configChanges,
            ioBufferDuration: ioDuration,
            inputLatency: inputLatency,
            outputLatency: outputLatency,
            jitterBufferedFrames: jitterStats.bufferedFrames,
            jitterTargetFrames: jitterStats.targetFrames,
            jitterMS: jitterStats.jitterMS,
            plcFrames: jitterStats.plcFrames,
            lateFrames: jitterStats.lateFrames,
            latencyDrops: jitterStats.latencyDrops,
            clockShortens: jitterStats.clockShortens,
            clockStretches: jitterStats.clockStretches,
            streamResets: jitterStats.streamResets,
            audioRoute: Self.describeCurrentRoute()
        )
    }

    private func captureInputBuffer(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)

        if let channels = buffer.floatChannelData {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += channels[channel][frame]
                }
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

        let rate = buffer.format.sampleRate

        audioQueue.async { [weak self] in
            self?.processMicSamples(mono, inputRate: rate)
        }
    }

    private func processMicSamples(_ samples: [Float], inputRate: Double) {
        guard running, inputRate > 0 else { return }

        if abs(micInputRate - inputRate) > 0.5 {
            micInputRate = inputRate
            micInputSamples.removeAll()
            micPacketSamples.removeAll()
            micPosition = 0
        }

        micInputSamples.append(contentsOf: samples)

        let step = inputRate / Self.networkRate
        guard step > 0 else { return }

        while micPosition + 1.0 < Double(micInputSamples.count) {
            let base = Int(micPosition)
            let fraction = Float(micPosition - Double(base))

            let a = micInputSamples[base]
            let b = micInputSamples[base + 1]
            let sample = a + (b - a) * fraction

            let scaled = Int((sample * 32767.0).rounded())
            micPacketSamples.append(Int16(clamping: scaled))

            micPosition += step

            while micPacketSamples.count >= Self.networkSamplesPerFrame {
                let packetSamples = Array(
                    micPacketSamples.prefix(Self.networkSamplesPerFrame)
                )
                micPacketSamples.removeFirst(Self.networkSamplesPerFrame)

                let capturedFrame =
                    packetSamples.withUnsafeBufferPointer { pointer in
                        Data(
                            bytes: pointer.baseAddress!,
                            count:
                                pointer.count
                                * MemoryLayout<Int16>.size
                        )
                    }

                let frame: Data
                let rms: Int

                if microphoneMuted {
                    // Keep network/audio clocks continuous while muted.
                    // Sending timed zero PCM is safer than stopping uplink
                    // packets and forcing the J6 jitter buffer to recover.
                    frame = Data(
                        count: Self.networkBytesPerFrame
                    )
                    rms = 0
                } else {
                    frame = capturedFrame
                    rms = Self.rmsOfPCM16LE(frame)
                }

                statsLock.lock()
                micRMS = rms
                statsLock.unlock()

                onMicFrame?(frame)
            }
        }

        // Keep the sample immediately before the fractional cursor so the
        // next callback can interpolate across the buffer boundary.
        let consumed = Int(micPosition)
        if consumed > 1 {
            let removeCount = consumed - 1
            micInputSamples.removeFirst(removeCount)
            micPosition -= Double(removeCount)
        }
    }

    private func fillPlaybackSchedule() {
        guard running else { return }

        while scheduledBuffers < scheduleTarget {
            if pendingPlaybackOutput == nil {
                let allowPLC = scheduledBuffers <= 1
                pendingPlaybackOutput = remoteJitter.pop(
                    playoutQueuedFrames: scheduledBuffers,
                    allowConcealment: allowPLC
                )

                if pendingPlaybackOutput == nil {
                    break
                }
            }

            guard let current = pendingPlaybackOutput else {
                break
            }

            // Do not call a packet lost while >=20 ms remains scheduled.
            let allowPLC = scheduledBuffers <= 1
            guard let next = remoteJitter.pop(
                playoutQueuedFrames: scheduledBuffers + 1,
                allowConcealment: allowPLC
            ) else {
                break
            }

            guard let nextFirstSample = Self.firstPCM16Sample(next.pcm),
                  let buffer = makePlaybackBuffer(
                    from: current.pcm,
                    nextFirstSample: nextFirstSample,
                    outputFrameAdjustment:
                        current.outputFrameAdjustment
                  )
            else {
                pendingPlaybackOutput = next
                continue
            }

            pendingPlaybackOutput = next
            scheduledBuffers += 1

            player.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard let self else { return }
                self.audioQueue.async {
                    self.scheduledBuffers = max(
                        0,
                        self.scheduledBuffers - 1
                    )
                    self.fillPlaybackSchedule()
                }
            }
        }

        if !player.isPlaying && scheduledBuffers > 0 {
            player.play()
        }
    }

    private func makePlaybackBuffer(
        from frame: Data,
        nextFirstSample: Int16,
        outputFrameAdjustment: Int
    ) -> AVAudioPCMBuffer? {
        guard frame.count == Self.networkBytesPerFrame,
              let playbackFormat else {
            return nil
        }

        var networkSamples = [Int16](
            repeating: 0,
            count: Self.networkSamplesPerFrame
        )

        _ = networkSamples.withUnsafeMutableBytes { destination in
            frame.copyBytes(to: destination)
        }

        let nominalOutputFrames = max(
            1,
            Int(
                (
                    Double(Self.networkSamplesPerFrame)
                    * playbackFormat.sampleRate
                    / Self.networkRate
                ).rounded()
            )
        )
        let outputFrames = max(
            1,
            nominalOutputFrames + outputFrameAdjustment
        )

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(outputFrames)
        ), let output = buffer.floatChannelData?[0] else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(outputFrames)

        if outputFrames == 1 {
            output[0] = Float(networkSamples[0]) / 32768.0
            return buffer
        }

        // Render exactly one 10 ms source interval into the selected output
        // duration. For source position [79, 80), interpolate sample 79 into
        // the FIRST sample of the next packet instead of holding sample 79.
        for index in 0..<outputFrames {
            let position =
                Double(index)
                * Double(Self.networkSamplesPerFrame)
                / Double(outputFrames)

            let base = min(
                Self.networkSamplesPerFrame - 1,
                Int(position)
            )
            let fraction = Float(position - Double(base))

            let first = Float(networkSamples[base])
            let second: Float

            if base + 1 < networkSamples.count {
                second = Float(networkSamples[base + 1])
            } else {
                second = Float(nextFirstSample)
            }

            output[index] =
                (first + (second - first) * fraction) / 32768.0
        }

        return buffer
    }

    private static func firstPCM16Sample(_ data: Data) -> Int16? {
        guard data.count >= 2 else { return nil }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let value =
                UInt16(bytes[0]) |
                (UInt16(bytes[1]) << 8)
            return Int16(bitPattern: value)
        }
    }

    private static func describeCurrentRoute() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute

        let outputs = route.outputs.map {
            routePortLabel($0)
        }
        let inputs = route.inputs.map {
            routePortLabel($0)
        }

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
                let raw = UInt16(bytes[index])
                    | (UInt16(bytes[index + 1]) << 8)
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
    }
}
