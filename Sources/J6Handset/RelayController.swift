import AVFAudio
import Combine
import Foundation
import Network

private actor CallAudioRouteSwitcher {
    func apply(_ route: CallAudioRouteChoice) -> String? {
        do {
            try AudioBridge.selectSystemCallRoute(route)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

struct RelayDiagnosticsSnapshot: Equatable {
    var sentFrames = 0
    var receivedFrames = 0
    var micRMS = 0
    var remoteRMS = 0
    var queueDepth = 0
    var drops = 0
    var voiceProcessing = false
    var ioBufferMS = 0.0
    var inputLatencyMS = 0.0
    var outputLatencyMS = 0.0
    var badWirePackets = 0
    var directBuffered = 0
    var directStartFrames = 0
    var lateFrames = 0
    var sequenceGaps = 0
    var latencyDrops = 0
    var streamResets = 0
    var rendererUnderruns = 0
    var rebufferEvents = 0
    var maxPacketGapMS = 0.0
    var audioRoute = "No active audio route"
}

@MainActor
final class RelayDiagnostics: ObservableObject {
    @Published private(set) var snapshot = RelayDiagnosticsSnapshot()

    func update(_ newSnapshot: RelayDiagnosticsSnapshot) {
        guard snapshot != newSnapshot else { return }
        snapshot = newSnapshot
    }
}

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
    @Published private(set) var micStreamingReady = false
    @Published private(set) var audioRestartCount = 0
    @Published private(set) var microphoneMuted = false
    @Published private(set) var callKitAudioSessionActive = false
    @Published private(set) var availableAudioRoutes: [CallAudioRouteChoice] = [.receiver, .speaker]
    @Published private(set) var selectedAudioRoute: CallAudioRouteChoice = .receiver
    @Published private(set) var isAudioRouteSwitching = false
    @Published var debugExportRequested = false
    @Published private(set) var debugExportText = ""
    @Published private(set) var debugExportFilename = "J6AudioDebug.txt"
    @Published private(set) var diagnosticLoggingEnabled = false
    @Published private(set) var debugLogStatus = "Disabled"

    let diagnostics = RelayDiagnostics()

    let receivePort: UInt16 = 41000
    let sendPort: UInt16 = 41001

    private let transport = UDPAudioTransport()
    private let audio = AudioBridge()
    private let audioRouteSwitcher = CallAudioRouteSwitcher()
    private var statsTimer: Timer?
    private var startInProgress = false
    private var startGeneration = 0
    private var desiredCallActive = false
    private var desiredAudioRunning = false
    private var retryCount = 0
    private var callKitManagedAudio = false
    private var audioRouteRequestGeneration = 0
    private var systemRouteChangeGeneration = 0
    private var audioRouteObserver: AnyCancellable?

    private let readyFrameThreshold = 10 // ~100 ms with 48 kHz / 10 ms packets
    private let stalledTickThreshold = 8
    private var lastWatchdogSentFrames = 0
    private var stalledTicks = 0
    private var watchdogRestartPending = false
    private var engineStoppedTicks = 0
    private var lastConfigurationChanges = 0
    private var lastCellularState = "UNKNOWN"
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(
        label: "J6Handset.NetworkPath",
        qos: .utility
    )

    init() {
        j6IP = UserDefaults.standard.string(forKey: Self.savedJ6IPKey)
            ?? "192.168.0.49"
        diagnosticLoggingEnabled = DiagnosticLog.shared.isEnabled()
        debugLogStatus = diagnosticLoggingEnabled
            ? "Enabled: \(DiagnosticLog.shared.liveFilename())"
            : "Disabled"
        DiagnosticLog.active?.log(
            "RELAY",
            "init j6IP=\(j6IP) localIP=\(localIP) liveLog=\(DiagnosticLog.shared.liveFilename())"
        )

        audioRouteObserver = NotificationCenter.default.publisher(
            for: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self else { return }
            self.handleSystemAudioRouteChange(notification)
        }

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshLocalIP()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    func enableCallKitAudioManagement() {
        callKitManagedAudio = true
        DiagnosticLog.active?.log("CALLKIT", "audio_management enabled")
    }

    func disableCallKitAudioManagement() {
        DiagnosticLog.active?.log("CALLKIT", "audio_management disabled")
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
        DiagnosticLog.active?.log("CALLKIT", "prepare_audio_session begin")
        do {
            try audio.prepareAudioSession()
            DiagnosticLog.active?.log("CALLKIT", "prepare_audio_session ok")
        } catch {
            DiagnosticLog.active?.log(
                "CALLKIT",
                "prepare_audio_session FAILED error=\(error.localizedDescription)"
            )
            status =
                "CallKit audio configuration failed: "
                + error.localizedDescription
        }
    }

    func setCallKitAudioSessionActive(_ active: Bool) {
        DiagnosticLog.active?.log(
            "CALLKIT",
            "audio_session_active=\(active) desiredAudio=\(desiredAudioRunning) running=\(isRunning) startInProgress=\(startInProgress)"
        )
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
        DiagnosticLog.active?.log("AUDIO", "microphone_muted=\(muted)")
        microphoneMuted = muted
        audio.setMicrophoneMuted(muted)
    }


    var hasExternalAudioRoute: Bool {
        availableAudioRoutes.contains(.bluetooth)
    }

    func refreshAudioRoutes() {
        let routes = audio.availableCallRoutes()
        if availableAudioRoutes != routes {
            availableAudioRoutes = routes
        }

        let currentRoute = audio.currentCallRouteChoice()
        if selectedAudioRoute != currentRoute {
            selectedAudioRoute = currentRoute
        }
    }

    func toggleBuiltInAudioRoute() {
        // Native Phone/CallKit behavior when there is no external call route:
        // one Audio tap toggles Receiver <-> Speaker. Never guess the current
        // state; always read AVAudioSession first.
        refreshAudioRoutes()
        guard !hasExternalAudioRoute else { return }

        let target: CallAudioRouteChoice =
            selectedAudioRoute == .speaker ? .receiver : .speaker
        selectAudioRoute(target)
    }

    func selectAudioRoute(_ route: CallAudioRouteChoice) {
        // AVAudioSession routing is asynchronous. Do not optimistically move
        // the UI selection: the real currentRoute is the single source of
        // truth for both this screen and CallKit's system UI. The route actor
        // serializes requests so rapid taps cannot overlap system operations.
        guard !isAudioRouteSwitching else { return }

        refreshAudioRoutes()
        if route == selectedAudioRoute { return }

        audioRouteRequestGeneration &+= 1
        let generation = audioRouteRequestGeneration
        isAudioRouteSwitching = true

        Task { [weak self] in
            guard let self else { return }
            let failure = await self.audioRouteSwitcher.apply(route)

            guard generation == self.audioRouteRequestGeneration else { return }

            if let failure {
                self.isAudioRouteSwitching = false
                self.status = "Audio route failed: \(failure)"
                DiagnosticLog.active?.log(
                    "AUDIO",
                    "route_request FAILED choice=\(route.rawValue) error=\(failure)"
                )
                self.refreshAudioRoutes()
                return
            }

            DiagnosticLog.active?.log(
                "AUDIO",
                "route_request submitted choice=\(route.rawValue)"
            )

            // Route-change notifications normally arrive first. This bounded
            // readback loop is only a fallback for devices/OS builds that
            // coalesce notifications. It never holds the UI thread.
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard generation == self.audioRouteRequestGeneration else { return }
                self.refreshAudioRoutes()

                if self.selectedAudioRoute == route {
                    self.isAudioRouteSwitching = false
                    self.status = "Audio route: \(route.title)"
                    DiagnosticLog.active?.log(
                        "AUDIO",
                        "route_request committed choice=\(route.rawValue)"
                    )
                    self.updateStats()
                    return
                }
            }

            self.isAudioRouteSwitching = false
            self.refreshAudioRoutes()
            self.updateStats()
            DiagnosticLog.active?.log(
                "AUDIO",
                "route_request settle_timeout requested=\(route.rawValue) actual=\(self.selectedAudioRoute.rawValue)"
            )
        }
    }

    private func handleSystemAudioRouteChange(_ notification: Notification) {
        systemRouteChangeGeneration &+= 1
        let generation = systemRouteChangeGeneration

        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))

        refreshAudioRoutes()
        DiagnosticLog.active?.log(
            "AUDIO",
            "system_route_changed reason=\(reason?.rawValue ?? 0) actual=\(selectedAudioRoute.rawValue) external=\(hasExternalAudioRoute)"
        )

        // A CallKit route switch can briefly stop AVAudioEngine while Core
        // Audio rebuilds its I/O graph. Wait until the system has committed the
        // route, then restart the existing graph in place. This avoids racing
        // the system route transaction with the watchdog.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, generation == self.systemRouteChangeGeneration else { return }

            self.refreshAudioRoutes()
            if self.desiredAudioRunning && self.isRunning {
                let snapshot = self.audio.snapshot()
                if !snapshot.engineRunning {
                    _ = self.audio.recoverEngineInPlace()
                }
            }
            self.updateStats()

            try? await Task.sleep(nanoseconds: 180_000_000)
            guard generation == self.systemRouteChangeGeneration else { return }
            self.refreshAudioRoutes()
            self.updateStats()
        }
    }

    func refreshLocalIP() {
        let old = localIP
        let updated = LocalIPAddress.currentIPv4() ?? "Not detected"
        guard updated != old else { return }
        localIP = updated
        DiagnosticLog.active?.log("NET", "local_ip old=\(old) new=\(updated)")
    }

    func adoptJ6LanIP(_ ip: String) {
        let candidate = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIPv4(candidate), candidate != j6IP else { return }

        let old = j6IP
        j6IP = candidate
        DiagnosticLog.active?.log(
            "NET",
            "J6 destination old=\(old) new=\(candidate) running=\(isRunning)"
        )

        if isRunning {
            do {
                try transport.updateRemoteHost(candidate, sendPort: sendPort)
                status = "Network path updated → \(candidate)"
            } catch {
                DiagnosticLog.active?.log(
                    "NET",
                    "J6 destination update FAILED error=\(error.localizedDescription)"
                )
                status = "J6 network update failed: \(error.localizedDescription)"
            }
        }
    }

    func handleCellularState(_ state: String) {
        let oldState = lastCellularState
        lastCellularState = state
        desiredCallActive = (state == "ACTIVE")
        desiredAudioRunning =
            state == "CONNECTING" ||
            state == "DIALING" ||
            state == "ACTIVE" ||
            state == "HOLDING"

        DiagnosticLog.active?.log(
            "CALL",
            "cellular_state \(oldState)->\(state) desiredAudio=\(desiredAudioRunning) running=\(isRunning) callKitActive=\(callKitAudioSessionActive)"
        )

        if desiredAudioRunning {
            retryCount = 0
            startAutomatically()

            if state == "DIALING" {
                status = "Listening for real cellular ringback…"
            } else if state == "CONNECTING" {
                status = "Preparing outgoing-call audio…"
            } else if state == "HOLDING" {
                status = "Call on hold — audio route kept warm"
            }
        } else if isRunning || startInProgress {
            stop(reason: "Call is \(state)")
        } else {
            status = "Waiting for call audio"
        }
    }

    func startAutomatically() {
        guard !isRunning, !startInProgress else {
            DiagnosticLog.active?.log(
                "RELAY",
                "start skipped running=\(isRunning) inProgress=\(startInProgress)"
            )
            return
        }

        if callKitManagedAudio && !callKitAudioSessionActive {
            status = "Waiting for CallKit audio session…"
            DiagnosticLog.active?.log(
                "RELAY",
                "start waiting_for_callkit desiredAudio=\(desiredAudioRunning)"
            )
            return
        }

        let host = j6IP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIPv4(host) else {
            status = "Enter the J6 Wi-Fi IPv4 address."
            DiagnosticLog.active?.log("RELAY", "start invalid_j6_ip value=\(host)")
            return
        }

        startGeneration += 1
        let generation = startGeneration
        startInProgress = true
        micStreamingReady = false
        lastWatchdogSentFrames = 0
        stalledTicks = 0
        watchdogRestartPending = false
        engineStoppedTicks = 0
        status = "Starting call audio…"
        DiagnosticLog.active?.log(
            "RELAY",
            "start begin gen=\(generation) host=\(host) rxPort=\(receivePort) txPort=\(sendPort) callKitManaged=\(callKitManagedAudio) callKitActive=\(callKitAudioSessionActive)"
        )

        Task {
            let microphoneGranted =
                await AVAudioApplication.requestRecordPermission()

            guard generation == startGeneration else { return }

            DiagnosticLog.active?.log(
                "AUDIO",
                "microphone_permission granted=\(microphoneGranted) gen=\(generation)"
            )

            guard microphoneGranted else {
                startInProgress = false
                status = "Microphone permission denied."
                return
            }

            do {
                transport.onState = { [weak self] message in
                    DiagnosticLog.active?.log("UDP", "state \(message)")
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
                DiagnosticLog.active?.log(
                    "RELAY",
                    "start SUCCESS gen=\(generation) engine=\(initialAudioStats.engineRunning) player=\(initialAudioStats.playerPlaying) inRate=\(initialAudioStats.inputSampleRate) outRate=\(initialAudioStats.outputSampleRate) route=\(initialAudioStats.audioRoute)"
                )
                startStatsTimer()
            } catch {
                DiagnosticLog.active?.log(
                    "RELAY",
                    "start FAILED gen=\(generation) error=\(String(describing: error)) localized=\(error.localizedDescription)"
                )
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
        DiagnosticLog.active?.log(
            "RELAY",
            "stop reason=\(reason) running=\(isRunning) inProgress=\(startInProgress) callKitManaged=\(callKitManagedAudio)"
        )
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
        engineStoppedTicks = 0
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

        diagnostics.update(
            RelayDiagnosticsSnapshot(
                sentFrames: network.sentFrames,
                receivedFrames: network.receivedFrames,
                micRMS: audioStats.micRMS,
                remoteRMS: audioStats.remoteRMS,
                queueDepth: audioStats.playbackQueueDepth,
                drops: audioStats.playbackDrops,
                voiceProcessing: audioStats.voiceProcessingEnabled,
                ioBufferMS: audioStats.ioBufferDuration * 1000.0,
                inputLatencyMS: audioStats.inputLatency * 1000.0,
                outputLatencyMS: audioStats.outputLatency * 1000.0,
                badWirePackets: network.badWirePackets,
                directBuffered: audioStats.directBufferedFrames,
                directStartFrames: audioStats.directStartFrames,
                lateFrames: audioStats.lateFrames,
                sequenceGaps: audioStats.sequenceGaps,
                latencyDrops: audioStats.latencyDrops,
                streamResets: audioStats.streamResets,
                rendererUnderruns: audioStats.rendererUnderruns,
                rebufferEvents: audioStats.rebufferEvents,
                maxPacketGapMS: audioStats.maxPacketGapMS,
                audioRoute: audioStats.audioRoute
            )
        )

        let routes = audio.availableCallRoutes()
        if availableAudioRoutes != routes {
            availableAudioRoutes = routes
        }

        let currentRoute = audio.currentCallRouteChoice()
        if selectedAudioRoute != currentRoute {
            selectedAudioRoute = currentRoute
        }

        guard isRunning else {
            lastWatchdogSentFrames = network.sentFrames
            lastConfigurationChanges = audioStats.configurationChanges
            return
        }

        if network.sendErrors > 0 || network.receiveErrors > 0 {
            let errorStatus =
                "Audio active with UDP errors: tx \(network.sendErrors), rx \(network.receiveErrors)"
            if status != errorStatus {
                status = errorStatus
            }
        }

        if audioStats.configurationChanges != lastConfigurationChanges {
            lastConfigurationChanges = audioStats.configurationChanges
            DiagnosticLog.active?.log(
                "WATCHDOG",
                "configuration_change observed engine=\(audioStats.engineRunning) changes=\(audioStats.configurationChanges)"
            )
        }

        if !audioStats.engineRunning {
            engineStoppedTicks += 1

            // First response is always an in-place Core Audio recovery. Do not
            // tear down the BSD socket or reset wire sessions for a transient
            // AVAudioEngine configuration blip.
            if engineStoppedTicks == 1 {
                DiagnosticLog.active?.log(
                    "WATCHDOG",
                    "soft_recovery attempt state=\(lastCellularState)"
                )
                if audio.recoverEngineInPlace() {
                    engineStoppedTicks = 0
                    stalledTicks = 0
                    status = "Audio recovered in place"
                    return
                }
            }

            // Allow one additional 250 ms observation tick before escalating.
            if engineStoppedTicks < 2 { return }

            scheduleWatchdogRestart(
                reason: "iOS audio engine remained stopped"
            )
            return
        }
        engineStoppedTicks = 0

        if !micStreamingReady &&
           network.sentFrames >= readyFrameThreshold {
            micStreamingReady = true
            stalledTicks = 0
            status = "Microphone stream verified"
            DiagnosticLog.active?.log(
                "RELAY",
                "microphone_stream_verified tx=\(network.sentFrames)"
            )
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
        status = "\(reason) — recovering audio…"
        DiagnosticLog.active?.log(
            "WATCHDOG",
            "audio_only_restart reason=\(reason) count=\(audioRestartCount) state=\(lastCellularState) keepUDP=true"
        )

        startGeneration += 1
        let restartGeneration = startGeneration
        micStreamingReady = false
        lastWatchdogSentFrames = transport.snapshot().sentFrames
        stalledTicks = 0
        engineStoppedTicks = 0

        // Keep the BSD UDP socket and J6v2 sessions alive. Only rebuild the
        // Core Audio side if the in-place attempt failed.
        audio.stop(deactivateSession: false)

        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)

            guard desiredAudioRunning,
                  restartGeneration == startGeneration
            else {
                watchdogRestartPending = false
                return
            }

            do {
                try audio.start(
                    audioSessionAlreadyActive:
                        callKitManagedAudio && callKitAudioSessionActive
                ) { [weak self] frame in
                    self?.transport.send(frame)
                }

                guard desiredAudioRunning,
                      restartGeneration == startGeneration
                else {
                    audio.stop(deactivateSession: false)
                    watchdogRestartPending = false
                    return
                }

                watchdogRestartPending = false
                isRunning = true
                micStreamingReady = false
                lastWatchdogSentFrames = transport.snapshot().sentFrames
                stalledTicks = 0
                engineStoppedTicks = 0
                lastConfigurationChanges = audio.snapshot().configurationChanges
                status = "Audio recovered — UDP preserved"
                DiagnosticLog.active?.log(
                    "WATCHDOG",
                    "audio_only_restart SUCCESS keepUDP=true"
                )
            } catch {
                DiagnosticLog.active?.log(
                    "WATCHDOG",
                    "audio_only_restart FAILED error=\(error.localizedDescription); escalating to full relay restart"
                )
                watchdogRestartPending = false
                isRunning = false
                startInProgress = false

                // Rare last-resort fallback. Only here do we permit the old
                // full transport restart behavior.
                transport.stop()
                audio.stop(deactivateSession: !callKitManagedAudio)
                startAutomatically()
            }
        }
    }

    func setDiagnosticLoggingEnabled(_ enabled: Bool) {
        DiagnosticLog.shared.setEnabled(enabled)
        diagnosticLoggingEnabled = DiagnosticLog.shared.isEnabled()
        debugExportRequested = false
        debugExportText = ""

        if diagnosticLoggingEnabled {
            debugLogStatus = "Enabled: \(DiagnosticLog.shared.liveFilename())"
            DiagnosticLog.active?.log("APP", "diagnostic_logging enabled")
        } else {
            debugLogStatus = "Disabled"
        }
    }

    func exportDebugLogNow() {
        guard diagnosticLoggingEnabled else {
            debugLogStatus = "Enable diagnostic logging first"
            return
        }
        logImmediateSnapshot(tag: "MANUAL_EXPORT")
        prepareDebugExport(reason: "manual")
    }

    func debugExportCompleted(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            debugLogStatus = "Exported: \(url.lastPathComponent)"
            DiagnosticLog.active?.log(
                "EXPORT",
                "file_export success url=\(url.path)"
            )
        case .failure(let error):
            debugLogStatus = "Export cancelled/failed: \(error.localizedDescription)"
            DiagnosticLog.active?.log(
                "EXPORT",
                "file_export failure error=\(error.localizedDescription)"
            )
        }
    }

    private func logImmediateSnapshot(tag: String) {
        let network = transport.snapshot()
        let audioStats = audio.snapshot()
        DiagnosticLog.active?.log(
            "SNAPSHOT",
            "tag=\(tag) call=\(lastCellularState) desiredAudio=\(desiredAudioRunning) running=\(isRunning) callKit=\(callKitAudioSessionActive) engine=\(audioStats.engineRunning) player=\(audioStats.playerPlaying) scheduled=\(audioStats.scheduledBuffers) scheduledTotal=\(audioStats.buffersScheduledTotal) playedTotal=\(audioStats.buffersPlayedTotal) remoteEnq=\(audioStats.remotePacketsEnqueued) tx=\(network.sentFrames) rx=\(network.receivedFrames) txErr=\(network.sendErrors) rxErr=\(network.receiveErrors) bad=\(network.badWirePackets) micRMS=\(audioStats.micRMS) remoteRMS=\(audioStats.remoteRMS) directFIFO=\(audioStats.directBufferedFrames)/\(audioStats.directStartFrames) gaps=\(audioStats.sequenceGaps) late=\(audioStats.lateFrames) overflow=\(audioStats.latencyDrops) underruns=\(audioStats.rendererUnderruns) route=\(audioStats.audioRoute)"
        )
    }

    private func prepareDebugExport(reason: String) {
        guard let snapshot = DiagnosticLog.shared.snapshot(reason: reason) else {
            debugLogStatus = "Could not create debug log snapshot"
            DiagnosticLog.active?.log("EXPORT", "snapshot FAILED reason=\(reason)")
            return
        }

        debugExportText = snapshot.text
        debugExportFilename = snapshot.url.lastPathComponent
        debugLogStatus = "Saved locally; choose Downloads in the save sheet"
        debugExportRequested = true
        DiagnosticLog.active?.log(
            "EXPORT",
            "snapshot ready local=\(snapshot.url.path) presenting_file_exporter"
        )
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
