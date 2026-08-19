import AVFAudio
import Combine
import Foundation

@MainActor
final class RelayController: ObservableObject {
    private static let savedJ6IPKey = "J6WifiIPv4"

    @Published var j6IP: String {
        didSet {
            UserDefaults.standard.set(j6IP, forKey: Self.savedJ6IPKey)
        }
    }

    @Published private(set) var localIP =
        LocalIPAddress.currentIPv4() ?? "Not detected"
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Waiting for active call"
    @Published private(set) var sentFrames = 0
    @Published private(set) var receivedFrames = 0
    @Published private(set) var micRMS = 0
    @Published private(set) var remoteRMS = 0
    @Published private(set) var queueDepth = 0
    @Published private(set) var drops = 0
    @Published private(set) var voiceProcessing = false
    @Published private(set) var micStreamingReady = false
    @Published private(set) var audioRestartCount = 0
    @Published private(set) var ioBufferMS = 0.0
    @Published private(set) var inputLatencyMS = 0.0
    @Published private(set) var outputLatencyMS = 0.0
    @Published private(set) var badWirePackets = 0
    @Published private(set) var jitterBuffered = 0
    @Published private(set) var jitterTarget = 0
    @Published private(set) var jitterMS = 0.0
    @Published private(set) var plcFrames = 0
    @Published private(set) var lateFrames = 0
    @Published private(set) var latencyDrops = 0
    @Published private(set) var clockShortens = 0
    @Published private(set) var clockStretches = 0
    @Published private(set) var streamResets = 0
    @Published private(set) var microphoneMuted = false
    @Published private(set) var callKitAudioSessionActive = false
    @Published private(set) var audioRoute = "No active audio route"

    let receivePort: UInt16 = 41000
    let sendPort: UInt16 = 41001

    private let transport = UDPAudioTransport()
    private let audio = AudioBridge()
    private var statsTimer: Timer?
    private var startInProgress = false
    private var startGeneration = 0
    private var desiredCallActive = false
    private var desiredAudioRunning = false
    private var retryCount = 0
    private var callKitManagedAudio = false

    private let readyFrameThreshold = 10 // ~100 ms with 10 ms packets
    private let stalledTickThreshold = 8
    private var lastWatchdogSentFrames = 0
    private var stalledTicks = 0
    private var watchdogRestartPending = false
    private var lastConfigurationChanges = 0

    init() {
        j6IP = UserDefaults.standard.string(forKey: Self.savedJ6IPKey)
            ?? "192.168.0.49"
    }

    func enableCallKitAudioManagement() {
        callKitManagedAudio = true
    }

    func disableCallKitAudioManagement() {
        callKitManagedAudio = false
        callKitAudioSessionActive = false

        // If CallKit becomes unavailable while a cellular call is already
        // dialing/active, immediately fall back to the proven app-managed
        // AVAudioSession path rather than leaving the call silent.
        if desiredAudioRunning && !isRunning && !startInProgress {
            startAutomatically()
        }
    }

    func prepareCallKitAudioSession() {
        do {
            try audio.prepareAudioSession()
        } catch {
            status =
                "CallKit audio configuration failed: "
                + error.localizedDescription
        }
    }

    func setCallKitAudioSessionActive(_ active: Bool) {
        callKitManagedAudio = true
        callKitAudioSessionActive = active

        if active {
            if desiredAudioRunning {
                startAutomatically()
            }
        } else if isRunning || startInProgress {
            stop(reason: "Waiting for CallKit audio session")
        }
    }

    func setMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
        audio.setMicrophoneMuted(muted)
    }

    func refreshLocalIP() {
        localIP = LocalIPAddress.currentIPv4() ?? "Not detected"
    }

    func handleCellularState(_ state: String) {
        desiredCallActive = (state == "ACTIVE")
        desiredAudioRunning =
            state == "CONNECTING" ||
            state == "DIALING" ||
            state == "ACTIVE"

        if desiredAudioRunning {
            retryCount = 0
            startAutomatically()

            if state == "DIALING" {
                status = "Listening for real cellular ringback…"
            } else if state == "CONNECTING" {
                status = "Preparing outgoing-call audio…"
            }
        } else if isRunning || startInProgress {
            stop(reason: "Call is \(state)")
        } else {
            status = "Waiting for call audio"
        }
    }

    func startAutomatically() {
        guard !isRunning, !startInProgress else { return }

        if callKitManagedAudio && !callKitAudioSessionActive {
            status = "Waiting for CallKit audio session…"
            return
        }

        let host = j6IP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIPv4(host) else {
            status = "Enter the J6 Wi-Fi IPv4 address."
            return
        }

        startGeneration += 1
        let generation = startGeneration
        startInProgress = true
        micStreamingReady = false
        lastWatchdogSentFrames = 0
        stalledTicks = 0
        watchdogRestartPending = false
        status = "Starting call audio…"

        Task {
            let microphoneGranted =
                await AVAudioApplication.requestRecordPermission()

            guard generation == startGeneration else { return }

            guard microphoneGranted else {
                startInProgress = false
                status = "Microphone permission denied."
                return
            }

            do {
                transport.onState = { [weak self] message in
                    Task { @MainActor in
                        if self?.isRunning == true {
                            self?.status = message
                        }
                    }
                }

                transport.onPacket = { [weak self] packet in
                    self?.audio.enqueueRemotePacket(packet)
                }

                try transport.start(
                    j6Host: host,
                    receivePort: receivePort,
                    sendPort: sendPort
                )

                try audio.start(
                    audioSessionAlreadyActive:
                        callKitManagedAudio &&
                        callKitAudioSessionActive
                ) { [weak self] frame in
                    self?.transport.send(frame)
                }

                guard generation == startGeneration else {
                    transport.stop()
                    audio.stop()
                    return
                }

                startInProgress = false
                retryCount = 0
                isRunning = true

                let initialAudioStats = audio.snapshot()
                lastConfigurationChanges =
                    initialAudioStats.configurationChanges

                status = "Audio started — verifying microphone stream…"
                startStatsTimer()
            } catch {
                transport.stop()
                audio.stop()
                startInProgress = false
                isRunning = false

                if desiredAudioRunning && retryCount < 3 {
                    retryCount += 1
                    status = "Audio start retry \(retryCount)/3…"

                    let retryGeneration = startGeneration
                    try? await Task.sleep(nanoseconds: 700_000_000)

                    guard desiredAudioRunning,
                          retryGeneration == startGeneration,
                          !isRunning,
                          !startInProgress
                    else {
                        return
                    }

                    startAutomatically()
                } else {
                    status = "Audio start failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func stop(reason: String = "Stopped") {
        startGeneration += 1
        startInProgress = false
        statsTimer?.invalidate()
        statsTimer = nil

        transport.stop()
        audio.stop(
            deactivateSession: !callKitManagedAudio
        )

        isRunning = false
        micStreamingReady = false
        lastWatchdogSentFrames = 0
        stalledTicks = 0
        watchdogRestartPending = false
        status = reason
        updateStats()
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStats()
            }
        }
        updateStats()
    }

    private func updateStats() {
        let network = transport.snapshot()
        let audioStats = audio.snapshot()

        sentFrames = network.sentFrames
        receivedFrames = network.receivedFrames
        micRMS = audioStats.micRMS
        remoteRMS = audioStats.remoteRMS
        queueDepth = audioStats.playbackQueueDepth
        drops = audioStats.playbackDrops
        voiceProcessing = audioStats.voiceProcessingEnabled
        ioBufferMS = audioStats.ioBufferDuration * 1000.0
        inputLatencyMS = audioStats.inputLatency * 1000.0
        outputLatencyMS = audioStats.outputLatency * 1000.0
        badWirePackets = network.badWirePackets
        jitterBuffered = audioStats.jitterBufferedFrames
        jitterTarget = audioStats.jitterTargetFrames
        jitterMS = audioStats.jitterMS
        plcFrames = audioStats.plcFrames
        lateFrames = audioStats.lateFrames
        latencyDrops = audioStats.latencyDrops
        clockShortens = audioStats.clockShortens
        clockStretches = audioStats.clockStretches
        streamResets = audioStats.streamResets
        audioRoute = audioStats.audioRoute

        guard isRunning else {
            lastWatchdogSentFrames = network.sentFrames
            lastConfigurationChanges = audioStats.configurationChanges
            return
        }

        if network.sendErrors > 0 || network.receiveErrors > 0 {
            status =
                "Audio active with UDP errors: tx \(network.sendErrors), rx \(network.receiveErrors)"
        }

        if audioStats.configurationChanges != lastConfigurationChanges {
            lastConfigurationChanges = audioStats.configurationChanges

            if !audioStats.engineRunning {
                scheduleWatchdogRestart(
                    reason: "iOS audio configuration changed"
                )
                return
            }
        }

        if !audioStats.engineRunning {
            scheduleWatchdogRestart(
                reason: "iOS audio engine stopped"
            )
            return
        }

        if !micStreamingReady &&
           network.sentFrames >= readyFrameThreshold {
            micStreamingReady = true
            stalledTicks = 0
            status = "Microphone stream verified"
        }

        if network.sentFrames > lastWatchdogSentFrames {
            stalledTicks = 0
        } else {
            stalledTicks += 1
        }

        lastWatchdogSentFrames = network.sentFrames

        if stalledTicks >= stalledTickThreshold {
            scheduleWatchdogRestart(
                reason: "microphone packets stalled"
            )
        }
    }

    private func scheduleWatchdogRestart(reason: String) {
        guard desiredAudioRunning,
              isRunning,
              !watchdogRestartPending
        else {
            return
        }

        watchdogRestartPending = true
        audioRestartCount += 1
        status = "\(reason) — restarting audio…"

        startGeneration += 1
        let restartGeneration = startGeneration

        statsTimer?.invalidate()
        statsTimer = nil

        transport.stop()
        audio.stop(
            deactivateSession: !callKitManagedAudio
        )

        isRunning = false
        micStreamingReady = false
        startInProgress = false
        lastWatchdogSentFrames = 0
        stalledTicks = 0

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)

            guard desiredAudioRunning,
                  restartGeneration == startGeneration
            else {
                watchdogRestartPending = false
                return
            }

            watchdogRestartPending = false
            startAutomatically()
        }
    }

    private func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isNumber }),
                  let octet = Int(part),
                  (0...255).contains(octet)
            else {
                return false
            }
        }
        return true
    }
}
