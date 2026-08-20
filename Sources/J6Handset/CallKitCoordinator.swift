import AVFAudio
import CallKit
import Combine
import Foundation
import UIKit

@MainActor
final class CallKitCoordinator: NSObject, ObservableObject {

    enum Direction {
        case incoming
        case outgoing
    }

    @Published private(set) var status = "CallKit ready"
    @Published private(set) var currentCallUUID: UUID?
    @Published private(set) var currentDirection: Direction?
    @Published private(set) var systemAudioActive = false
    @Published private(set) var isMuted = false
    @Published private(set) var callKitAvailable = true
    @Published private(set) var systemCallPresent = false
    @Published private(set) var systemCallConnected = false
    @Published private(set) var systemCallOutgoing = false

    @Published private(set) var displayCallerName = ""
    @Published private(set) var displayPhoneNumber = ""
    @Published private(set) var contactMatched = false
    @Published private(set) var contactThumbnailImageData: Data?

    // UI state that must survive recreation of the custom call screen.
    @Published private(set) var connectedAt: Date?
    @Published private(set) var failedOutgoingNumber: String?

    private let ble: BLECallController
    private let relay: RelayController
    private let contacts: ContactResolver
    private let provider: CXProvider
    private let callController = CXCallController()

    private let savedCallUUIDKey = "J6CallKitActiveUUID"
    private var cancellables = Set<AnyCancellable>()

    private var currentNumber = ""
    private var previousCellularState = "IDLE"
    private var outgoingConnectingReported = false
    private var outgoingConnectedReported = false
    private var localEndRequested = false
    private var incomingReportTask: Task<Void, Never>?

    init(
        ble: BLECallController,
        relay: RelayController,
        contacts: ContactResolver
    ) {
        self.ble = ble
        self.relay = relay
        self.contacts = contacts

        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = true
        configuration.iconTemplateImageData =
            Self.makeProviderIconData()

        provider = CXProvider(configuration: configuration)

        super.init()

        provider.setDelegate(self, queue: .main)
        callController.callObserver.setDelegate(
            self,
            queue: .main
        )

        restoreObservedCallIfPossible()

        relay.enableCallKitAudioManagement()
        bindRuntime()
    }

    // MARK: - App UI actions

    func startOutgoing(number rawNumber: String) {
        let number = rawNumber.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard currentCallUUID == nil else {
            status = "A call is already in progress."
            return
        }

        guard ble.prepareOutgoingUI(number: number) else {
            status = ble.bluetoothStatus
            return
        }

        relay.enableCallKitAudioManagement()
        callKitAvailable = true
        failedOutgoingNumber = nil
        connectedAt = nil

        let basicMetadata =
            contacts.basicMetadata(for: number)
        applyCallMetadata(basicMetadata)

        let uuid = UUID()
        let handle = CXHandle(
            type: .phoneNumber,
            value: basicMetadata.normalizedNumber
        )

        currentCallUUID = uuid
        persistCallUUID(uuid)
        currentDirection = .outgoing
        currentNumber = number
        localEndRequested = false
        outgoingConnectingReported = false
        outgoingConnectedReported = false

        let action = CXStartCallAction(
            call: uuid,
            handle: handle
        )
        action.isVideo = false

        request(
            CXTransaction(action: action),
            failure: { [weak self] error in
                guard let self else { return }

                let detail = self.describeCallKitError(error)
                self.fallbackToAppManagedCall(
                    reason: "CallKit start rejected: " + detail
                )

                // The CallKit transaction was rejected, so its provider
                // delegate never started the real J6 call. Keep the user
                // action working by falling back to the proven BLE path.
                if self.ble.performDial(number: number) {
                    self.status =
                        "CallKit unavailable; calling with in-app controls. "
                        + detail
                } else {
                    self.ble.clearOptimisticOutgoingUI()
                    self.status =
                        "CallKit unavailable and J6 dial failed. "
                        + detail
                }
            }
        )
    }

    func answerCurrentCall() {
        guard let uuid = currentCallUUID else {
            // Fallback for a foreground-only call if CallKit reporting was
            // rejected by the system for some reason.
            _ = ble.answer()
            return
        }

        request(
            CXTransaction(
                action: CXAnswerCallAction(call: uuid)
            ),
            failure: { [weak self] error in
                guard let self else { return }
                let detail = self.describeCallKitError(error)
                self.fallbackToAppManagedCall(
                    reason: "CallKit answer failed: " + detail
                )
                _ = self.ble.answer()
            }
        )
    }

    func endCurrentCall() {
        guard let uuid = currentCallUUID else {
            if ble.callState == "RINGING" {
                _ = ble.reject()
            } else {
                _ = ble.hangup()
            }
            return
        }

        request(
            CXTransaction(
                action: CXEndCallAction(call: uuid)
            ),
            failure: { [weak self] error in
                guard let self else { return }
                let detail = self.describeCallKitError(error)
                self.fallbackToAppManagedCall(
                    reason: "CallKit end failed: " + detail
                )

                if self.ble.callState == "RINGING" {
                    _ = self.ble.reject()
                } else {
                    _ = self.ble.hangup()
                }
            }
        )
    }

    func setMuted(_ muted: Bool) {
        guard let uuid = currentCallUUID else {
            relay.setMicrophoneMuted(muted)
            isMuted = muted
            return
        }

        request(
            CXTransaction(
                action: CXSetMutedCallAction(
                    call: uuid,
                    muted: muted
                )
            ),
            failure: { [weak self] error in
                guard let self else { return }
                let detail = self.describeCallKitError(error)
                self.fallbackToAppManagedCall(
                    reason: "CallKit mute failed: " + detail
                )
                self.isMuted = muted
                self.relay.setMicrophoneMuted(muted)
            }
        )
    }

    func dismissFailedOutgoingCall() {
        failedOutgoingNumber = nil
    }

    // MARK: - Runtime binding

    private func bindRuntime() {
        ble.$callState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.handleCellularState(state)
            }
            .store(in: &cancellables)

        relay.$micStreamingReady
            .removeDuplicates()
            .sink { [weak self] ready in
                guard let self,
                      ready,
                      self.ble.callState == "ACTIVE"
                else {
                    return
                }

                self.ble.audioReady()
            }
            .store(in: &cancellables)

        ble.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self, connected else { return }
                self.relay.refreshLocalIP()
                self.ble.configureAudioPeer(
                    ip: self.relay.localIP
                )
            }
            .store(in: &cancellables)
    }

    private func handleCellularState(_ state: String) {
        let oldState = previousCellularState

        // Audio lifecycle is app-level now, not dependent on ContentView
        // being visible.
        relay.handleCellularState(state)

        if state == "ACTIVE" && relay.micStreamingReady {
            ble.audioReady()
        }

        switch state {
        case "RINGING":
            reportIncomingIfNeeded(
                number: ble.callerID
            )

        case "CONNECTING", "DIALING":
            if currentDirection == .outgoing,
               let uuid = currentCallUUID,
               !outgoingConnectingReported {
                outgoingConnectingReported = true
                provider.reportOutgoingCall(
                    with: uuid,
                    startedConnectingAt: Date()
                )
            }

        case "ACTIVE":
            if connectedAt == nil {
                connectedAt = Date()
            }

            if currentDirection == .outgoing,
               let uuid = currentCallUUID,
               !outgoingConnectedReported {
                outgoingConnectedReported = true
                provider.reportOutgoingCall(
                    with: uuid,
                    connectedAt: Date()
                )
            }

        case "DISCONNECTED", "IDLE":
            cancelPendingIncomingReport()
            finishSystemCall(
                previousState: oldState,
                currentState: state
            )

        case "ERROR":
            cancelPendingIncomingReport()
            if let uuid = currentCallUUID {
                provider.reportCall(
                    with: uuid,
                    endedAt: Date(),
                    reason: .failed
                )
                clearCurrentCall()
            }

        default:
            break
        }

        previousCellularState = state
    }

    private func reportIncomingIfNeeded(number: String) {
        // If CallKit already knows about this ringing call, refresh metadata
        // if the J6 later provides a more complete caller number.
        if let uuid = currentCallUUID {
            guard !number.isEmpty else { return }

            resolveContactMetadata(
                number: number,
                callUUID: uuid
            )
            return
        }

        // Only one initial incoming report may be prepared at a time.
        guard incomingReportTask == nil else {
            return
        }

        relay.enableCallKitAudioManagement()
        callKitAvailable = true
        failedOutgoingNumber = nil
        connectedAt = nil

        let rawNumber = number.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        // BLECallController now publishes callerID before RINGING, so this
        // should normally be populated. Keep a safe fallback for withheld
        // caller ID / network-provided private numbers.
        let lookupNumber =
            rawNumber.isEmpty ? "Unknown" : rawNumber

        incomingReportTask = Task { [weak self] in
            guard let self else { return }

            // Resolve Contacts BEFORE the first CallKit report. This means the
            // locked-screen incoming UI receives localizedCallerName in its
            // initial CXCallUpdate instead of first displaying "Unknown" and
            // relying on a later reportCall(updated:) refresh.
            let metadata =
                await self.contacts.resolve(
                    number: lookupNumber
                )

            guard !Task.isCancelled else {
                self.incomingReportTask = nil
                return
            }

            guard self.ble.callState == "RINGING",
                  self.currentCallUUID == nil
            else {
                self.incomingReportTask = nil
                return
            }

            let uuid = UUID()

            self.applyCallMetadata(metadata)

            let update = self.makeCallUpdate(
                metadata: metadata
            )

            self.currentCallUUID = uuid
            self.persistCallUUID(uuid)
            self.currentDirection = .incoming
            self.currentNumber = lookupNumber
            self.localEndRequested = false
            self.incomingReportTask = nil

            do {
                try await self.provider.reportNewIncomingCall(
                    with: uuid,
                    update: update
                )

                self.callKitAvailable = true
                self.status =
                    metadata.displayName.map {
                        "Incoming call: \($0)"
                    }
                    ?? "Incoming call shown by CallKit"
            } catch {
                let detail =
                    self.describeCallKitError(error)

                // CallKit UI failure must never reject the real GSM call.
                // Keep BLE RINGING alive for the in-app fallback path.
                self.fallbackToAppManagedCall(
                    reason:
                        "Incoming CallKit unavailable; "
                        + "use in-app Answer/Reject. "
                        + detail
                )
            }
        }
    }

    private func cancelPendingIncomingReport() {
        incomingReportTask?.cancel()
        incomingReportTask = nil
    }

    private func finishSystemCall(
        previousState: String,
        currentState: String
    ) {
        guard let uuid = currentCallUUID else {
            return
        }

        if !localEndRequested {
            let reason: CXCallEndedReason

            if currentDirection == .incoming &&
               previousState == "RINGING" {
                reason = .unanswered
            } else if currentDirection == .outgoing &&
                        !outgoingConnectedReported {
                reason = .failed
                failedOutgoingNumber =
                    currentNumber.isEmpty
                        ? displayPhoneNumber
                        : currentNumber
            } else {
                reason = .remoteEnded
            }

            provider.reportCall(
                with: uuid,
                endedAt: Date(),
                reason: reason
            )
        }

        clearCurrentCall()
    }

    private func makeCallUpdate(
        metadata: ContactCallMetadata
    ) -> CXCallUpdate {
        let update = CXCallUpdate()

        let handleValue =
            metadata.normalizedNumber.isEmpty
                ? metadata.rawNumber
                : metadata.normalizedNumber

        update.remoteHandle = CXHandle(
            type: .phoneNumber,
            value: handleValue
        )

        if let name = metadata.displayName,
           !name.isEmpty {
            // Apple can derive names from Contacts automatically from the
            // remoteHandle; when our explicit lookup succeeds, provide the
            // same resolved name so CallKit and our app stay identical.
            update.localizedCallerName = name
        }

        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = true
        return update
    }

    private func applyCallMetadata(
        _ metadata: ContactCallMetadata
    ) {
        displayCallerName =
            metadata.displayName ?? ""
        displayPhoneNumber =
            metadata.formattedNumber
        contactMatched =
            metadata.matchedContact
        contactThumbnailImageData =
            metadata.thumbnailImageData
    }

    private func resolveContactMetadata(
        number: String,
        callUUID: UUID
    ) {
        Task { [weak self] in
            guard let self else { return }

            let metadata =
                await self.contacts.resolve(
                    number: number
                )

            guard self.currentCallUUID == callUUID else {
                return
            }

            self.applyCallMetadata(metadata)

            // Push late-resolved contact name / canonical number into the
            // already-visible native CallKit call.
            self.provider.reportCall(
                with: callUUID,
                updated: self.makeCallUpdate(
                    metadata: metadata
                )
            )
        }
    }

    private func persistCallUUID(_ uuid: UUID) {
        UserDefaults.standard.set(
            uuid.uuidString,
            forKey: savedCallUUIDKey
        )
    }

    private func clearPersistedCallUUID() {
        UserDefaults.standard.removeObject(
            forKey: savedCallUUIDKey
        )
    }

    private func restoreObservedCallIfPossible() {
        guard
            let raw = UserDefaults.standard.string(
                forKey: savedCallUUIDKey
            ),
            let savedUUID = UUID(uuidString: raw)
        else {
            return
        }

        guard let call =
            callController.callObserver.calls.first(
                where: { $0.uuid == savedUUID }
            )
        else {
            clearPersistedCallUUID()
            return
        }

        currentCallUUID = call.uuid
        systemCallPresent = !call.hasEnded
        systemCallConnected = call.hasConnected
        systemCallOutgoing = call.isOutgoing
        currentDirection = call.isOutgoing
            ? .outgoing
            : .incoming

        status = call.hasConnected
            ? "Restored active iOS CallKit call"
            : "Restored pending iOS CallKit call"
    }

    private static func makeProviderIconData() -> Data? {
        let size = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: size)

        let image = renderer.image { _ in
            UIColor.clear.setFill()
            UIRectFill(
                CGRect(origin: .zero, size: size)
            )

            guard let symbol = UIImage(
                systemName: "phone.fill"
            )?.withTintColor(
                .white,
                renderingMode: .alwaysOriginal
            ) else {
                return
            }

            let target = CGRect(
                x: 6,
                y: 6,
                width: 28,
                height: 28
            )
            symbol.draw(in: target)
        }

        return image.pngData()
    }

    private func fallbackToAppManagedCall(reason: String) {
        cancelPendingIncomingReport()
        callKitAvailable = false

        // Forget CallKit's UUID/provider state but preserve the authoritative
        // BLE/GSM call state and the optimistic iPhone call UI.
        currentCallUUID = nil
        clearPersistedCallUUID()
        currentDirection = nil
        currentNumber = ""
        outgoingConnectingReported = false
        outgoingConnectedReported = false
        localEndRequested = false

        relay.disableCallKitAudioManagement()
        relay.handleCellularState(ble.callState)

        status = reason
    }

    private func describeCallKitError(_ error: Error) -> String {
        let nsError = error as NSError
        return
            "\(nsError.domain) code=\(nsError.code): "
            + nsError.localizedDescription
    }

    private func clearCurrentCall() {
        cancelPendingIncomingReport()
        currentCallUUID = nil
        clearPersistedCallUUID()
        currentDirection = nil
        systemCallPresent = false
        systemCallConnected = false
        systemCallOutgoing = false
        currentNumber = ""
        displayCallerName = ""
        displayPhoneNumber = ""
        contactMatched = false
        contactThumbnailImageData = nil
        outgoingConnectingReported = false
        outgoingConnectedReported = false
        localEndRequested = false
        connectedAt = nil

        if isMuted {
            isMuted = false
            relay.setMicrophoneMuted(false)
        }
    }

    private func request(
        _ transaction: CXTransaction,
        failure: ((Error) -> Void)? = nil
    ) {
        callController.request(transaction) {
            [weak self] error in

            guard let error else { return }

            Task { @MainActor in
                if let failure {
                    failure(error)
                } else {
                    self?.status =
                        "CallKit action failed: "
                        + error.localizedDescription
                }
            }
        }
    }
}

// MARK: - CXProviderDelegate

extension CallKitCoordinator: @preconcurrency CXProviderDelegate {

    func providerDidReset(
        _ provider: CXProvider
    ) {
        // Provider reset is a CallKit/system event, not a reason to terminate
        // the physical GSM call on the J6. Fail open to the original app UI
        // and app-managed audio instead.
        systemAudioActive = false
        fallbackToAppManagedCall(
            reason:
                "CallKit provider reset; "
                + "continuing with in-app call controls"
        )
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXStartCallAction
    ) {
        relay.prepareCallKitAudioSession()

        let number = action.handle.value
        let started = ble.performDial(
            number: number
        )

        if started {
            callKitAvailable = true
            relay.enableCallKitAudioManagement()

            currentCallUUID = action.callUUID
            persistCallUUID(action.callUUID)
            currentDirection = .outgoing
            currentNumber = number

            let basic =
                contacts.basicMetadata(for: number)
            applyCallMetadata(basic)

            provider.reportCall(
                with: action.callUUID,
                updated: makeCallUpdate(
                    metadata: basic
                )
            )

            resolveContactMetadata(
                number: number,
                callUUID: action.callUUID
            )

            if !outgoingConnectingReported {
                outgoingConnectingReported = true
                provider.reportOutgoingCall(
                    with: action.callUUID,
                    startedConnectingAt: Date()
                )
            }

            status = "Outgoing cellular call started"
            action.fulfill()
        } else {
            failedOutgoingNumber =
                currentNumber.isEmpty
                    ? displayPhoneNumber
                    : currentNumber
            ble.clearOptimisticOutgoingUI()
            status =
                "Could not send cellular dial command to J6"
            action.fail()
            provider.reportCall(
                with: action.callUUID,
                endedAt: Date(),
                reason: .failed
            )
            clearCurrentCall()
        }
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXAnswerCallAction
    ) {
        relay.prepareCallKitAudioSession()

        if ble.answer() {
            status = "Answer sent to J6"
            action.fulfill()
        } else {
            status = "J6 BLE unavailable while answering"
            action.fail()
        }
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXEndCallAction
    ) {
        localEndRequested = true

        // Stop local call audio immediately. The real J6 DISCONNECTED
        // state follows and completes cleanup.
        relay.handleCellularState("DISCONNECTING")

        let sent: Bool
        if ble.callState == "RINGING" {
            sent = ble.reject()
        } else {
            sent = ble.hangup()
        }

        if sent {
            status = "Ending cellular call"
            action.fulfill()
        } else {
            localEndRequested = false
            status = "J6 BLE unavailable while ending call"
            action.fail()
        }
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXSetMutedCallAction
    ) {
        isMuted = action.isMuted
        relay.setMicrophoneMuted(action.isMuted)
        status = action.isMuted
            ? "Microphone muted"
            : "Microphone unmuted"
        action.fulfill()
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXPlayDTMFCallAction
    ) {
        guard currentCallUUID == action.callUUID,
              ble.callState == "ACTIVE"
        else {
            status = "DTMF rejected: no active cellular call"
            action.fail()
            return
        }

        // CallKit plays the local keypad feedback itself. We forward only the
        // actual digits to the J6, where Telecom injects them into the live
        // GSM call.
        if ble.sendDtmf(action.digits) {
            status = "DTMF sent: \(action.digits)"
            action.fulfill()
        } else {
            status = "DTMF failed: J6 BLE unavailable"
            action.fail()
        }
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXSetHeldCallAction
    ) {
        // The J6 BLE protocol currently has no hold/resume command.
        action.fail()
    }

    func provider(
        _ provider: CXProvider,
        didActivate audioSession: AVAudioSession
    ) {
        systemAudioActive = true
        relay.setCallKitAudioSessionActive(true)
        status = "CallKit audio session active"
    }

    func provider(
        _ provider: CXProvider,
        didDeactivate audioSession: AVAudioSession
    ) {
        systemAudioActive = false
        relay.setCallKitAudioSessionActive(false)
        status = "CallKit audio session inactive"
    }

    func provider(
        _ provider: CXProvider,
        timedOutPerforming action: CXAction
    ) {
        status =
            "CallKit action timed out: "
            + String(describing: type(of: action))
    }
}


// MARK: - CXCallObserverDelegate

extension CallKitCoordinator:
    @preconcurrency CXCallObserverDelegate {

    func callObserver(
        _ callObserver: CXCallObserver,
        callChanged call: CXCall
    ) {
        guard let currentCallUUID,
              call.uuid == currentCallUUID
        else {
            return
        }

        systemCallPresent = !call.hasEnded
        systemCallConnected = call.hasConnected
        systemCallOutgoing = call.isOutgoing

        if call.hasEnded {
            clearPersistedCallUUID()
        }

        if call.hasEnded {
            status = "iOS system call ended"
        } else if call.hasConnected {
            status = "iOS system call active"
        } else if call.isOutgoing {
            status = "iOS system outgoing call"
        } else {
            status = "iOS system incoming call"
        }
    }
}
