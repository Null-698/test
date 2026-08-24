import AVFAudio
import CallKit
import Combine
import Foundation
import UIKit
import UserNotifications

@MainActor
final class CallKitCoordinator: NSObject, ObservableObject {

    enum Direction {
        case incoming
        case outgoing
    }

    private struct HistoryContext {
        var number: String
        let direction: CallHistoryStore.Direction
        let startedAt: Date
        var connectedAt: Date?
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
    private let callHistory: CallHistoryStore
    private let provider: CXProvider
    private let callController = CXCallController()

    private let savedCallUUIDKey = "J6CallKitActiveUUID"
    private var cancellables = Set<AnyCancellable>()

    private var currentNumber = ""
    private var previousCellularState = "IDLE"
    private var outgoingConnectingReported = false
    private var outgoingConnectedReported = false
    private var currentCallEverActive = false
    private var outgoingCarrierStateSeen = false
    private var incomingReportTask: Task<Void, Never>?
    private var remoteCallUUIDs: [Int: UUID] = [:]
    private var remoteCallIDs: [UUID: Int] = [:]
    private var pendingRemoteIncomingReports: Set<Int> = []
    private var locallyEndingUUIDs: Set<UUID> = []
    private var pendingOutgoingStartUUIDs: Set<UUID> = []
    private var cancelledOutgoingStartUUIDs: Set<UUID> = []
    private var answeredIncomingUUIDs: Set<UUID> = []
    private var previousRemoteCallStates: [Int: String] = [:]
    private var historyContexts: [UUID: HistoryContext] = [:]

    init(
        ble: BLECallController,
        relay: RelayController,
        contacts: ContactResolver,
        callHistory: CallHistoryStore
    ) {
        self.ble = ble
        self.relay = relay
        self.contacts = contacts
        self.callHistory = callHistory

        let configuration = CXProviderConfiguration()
        // Best-effort invisible provider-name workaround. `localizedName` is
        // deprecated/no-longer-supported on iOS 26, so use KVC to avoid a
        // deprecated-symbol warning while still covering system versions/UI
        // paths that continue to read the legacy provider label. Do not make
        // CFBundleDisplayName invisible because that would also affect the app.
        configuration.setValue("\u{200B}", forKey: "localizedName")
        configuration.supportsVideo = false
        // Call waiting is two separate calls, not a conference group.
        // Allow two simultaneous groups of one call each; grouping itself
        // remains disabled in CXCallUpdate.
        configuration.maximumCallGroups = 2
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        configuration.includesCallsInRecents = true
        // iOS 26 owns provider identity in the system call UI. Do not add a
        // custom provider glyph here; let CallKit render its native chrome.
        // Per-caller identity is supplied through the real phone-number handle
        // below so the system can perform its own Contacts/photo lookup.
        configuration.iconTemplateImageData = nil

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
        currentCallEverActive = false
        outgoingCarrierStateSeen = false

        let basicMetadata =
            contacts.basicMetadata(for: number)
        applyCallMetadata(basicMetadata)

        let uuid = UUID()
        let handle = CXHandle(
            type: .phoneNumber,
            value: basicMetadata.normalizedNumber
        )

        currentCallUUID = uuid
        pendingOutgoingStartUUIDs.insert(uuid)
        persistCallUUID(uuid)
        currentDirection = .outgoing
        currentNumber = number
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

                self.pendingOutgoingStartUUIDs.remove(uuid)
                let wasCancelled =
                    self.cancelledOutgoingStartUUIDs.remove(uuid) != nil

                // Ending immediately after tapping Call can make the pending
                // CXStartCallAction fail. That failure is cancellation, not a
                // reason to fall back to a direct BLE dial.
                if wasCancelled || self.currentCallUUID != uuid {
                    self.finishCancelledOutgoingSetup(uuid: uuid)
                    return
                }

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
                        "CallKit unavailable and cellular dial failed. "
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

        // Record cancellation before asking CallKit to end the call. The start
        // transaction may still be queued, and its failure callback or provider
        // action must never reinterpret this End as permission to dial again.
        if pendingOutgoingStartUUIDs.contains(uuid) {
            cancelledOutgoingStartUUIDs.insert(uuid)
            finishCancelledOutgoingSetup(uuid: uuid)
        }

        request(
            CXTransaction(
                action: CXEndCallAction(call: uuid)
            ),
            failure: { [weak self] error in
                guard let self else { return }

                if self.cancelledOutgoingStartUUIDs.contains(uuid) {
                    // The pending Start remains tombstoned until CallKit either
                    // rejects it or delivers its provider action.
                    self.finishCancelledOutgoingSetup(uuid: uuid)
                    return
                }

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

    @discardableResult
    func playDtmf(_ rawDigit: String) -> Bool {
        guard let uuid = currentCallUUID,
              ble.callState == "ACTIVE"
        else {
            status = "DTMF requires an active CallKit call."
            return false
        }

        let digit = rawDigit.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard digit.count == 1,
              digit.allSatisfy({
                  $0.isNumber || $0 == "*" || $0 == "#"
              })
        else {
            status = "Invalid DTMF digit."
            return false
        }

        // Submit the same CXPlayDTMFCallAction used by the native system
        // in-call keypad. CallKit provides the local audible DTMF feedback;
        // provider(_:perform:) below forwards the digit to the J6 network call.
        let action = CXPlayDTMFCallAction(
            call: uuid,
            digits: digit,
            type: .singleTone
        )

        request(
            CXTransaction(action: action),
            failure: { [weak self] error in
                guard let self else { return }
                self.status =
                    "DTMF CallKit action failed: "
                    + self.describeCallKitError(error)
            }
        )

        return true
    }

    func declineWaitingCall(id: Int) {
        if let uuid = remoteCallUUIDs[id] {
            request(CXTransaction(action: CXEndCallAction(call: uuid)))
        } else {
            _ = ble.rejectCall(id: id)
        }
    }

    func acceptWaitingCall(id: Int, endingCurrent: Bool) {
        guard let waitingUUID = remoteCallUUIDs[id] else {
            if endingCurrent, let activeID = activeRemoteCallID() {
                _ = ble.hangupCall(id: activeID)
            } else if let activeID = activeRemoteCallID() {
                _ = ble.setHeld(callID: activeID, held: true)
            }
            _ = ble.answerCall(id: id)
            return
        }

        var actions: [CXAction] = []
        if let currentCallUUID,
           currentCallUUID != waitingUUID {
            if endingCurrent {
                actions.append(CXEndCallAction(call: currentCallUUID))
            } else {
                actions.append(
                    CXSetHeldCallAction(
                        call: currentCallUUID,
                        onHold: true
                    )
                )
            }
        }
        actions.append(CXAnswerCallAction(call: waitingUUID))
        request(CXTransaction(actions: actions))
    }

    func swapCalls() {
        guard let active = ble.remoteCalls.values.first(where: {
            $0.state == "ACTIVE"
        }),
        let held = ble.remoteCalls.values.first(where: {
            $0.state == "HOLDING"
        }),
        let activeUUID = remoteCallUUIDs[active.id],
        let heldUUID = remoteCallUUIDs[held.id]
        else {
            _ = ble.swapCalls()
            return
        }

        request(
            CXTransaction(actions: [
                CXSetHeldCallAction(call: activeUUID, onHold: true),
                CXSetHeldCallAction(call: heldUUID, onHold: false)
            ])
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


        ble.$remoteCalls
            .sink { [weak self] calls in
                self?.syncRemoteCalls(calls)
            }
            .store(in: &cancellables)

        ble.$j6LanIP
            .removeDuplicates()
            .filter { !$0.isEmpty }
            .sink { [weak self] ip in
                self?.relay.adoptJ6LanIP(ip)
            }
            .store(in: &cancellables)

        relay.$localIP
            .removeDuplicates()
            .sink { [weak self] ip in
                guard let self,
                      self.ble.isConnected,
                      ip != "Not detected"
                else { return }
                self.ble.configureAudioPeer(ip: ip)
                _ = self.ble.syncState()
            }
            .store(in: &cancellables)
    }

    private func handleCellularState(_ state: String) {
        let oldState = previousCellularState
        let commandError = state == "ERROR"

        // ERROR is a command/control transport result, never an authoritative
        // GSM lifecycle state. BLECallController filters it before publishing
        // callState, but keep this second guard here so a future producer can
        // never tear down CallKit/audio by accidentally forwarding ERROR.
        if !commandError {
            relay.handleCellularState(state)
        }

        if state == "ACTIVE" && relay.micStreamingReady {
            ble.audioReady()
        }

        switch state {
        case "RINGING":
            reportIncomingIfNeeded(
                number: ble.callerID
            )

        case "CONNECTING", "DIALING":
            if currentDirection == .outgoing {
                outgoingCarrierStateSeen = true
            }
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
            currentCallEverActive = true
            if currentDirection == .outgoing {
                outgoingCarrierStateSeen = true
            }
            if connectedAt == nil {
                connectedAt = Date()
            }
            if let uuid = currentCallUUID {
                markHistoryConnected(uuid: uuid)
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

        case "IDLE":
            // After CXStartCallAction is fulfilled there can be a short window
            // where the BLE aggregate state still says IDLE while Android
            // Telecom/carrier setup has not published the new call object yet.
            // Do not kill the CallKit call merely because carrier setup is
            // slow. Once CONNECTING/DIALING/ACTIVE has been observed, IDLE is
            // authoritative again. DISCONNECTED is always authoritative.
            if currentDirection == .outgoing,
               !outgoingCarrierStateSeen,
               !currentCallEverActive {
                DiagnosticLog.active?.log(
                    "CALLKIT",
                    "ignored pre-carrier IDLE while outgoing setup is pending"
                )
                status = "Waiting for carrier call setup"
            } else {
                cancelPendingIncomingReport()
                finishSystemCall(
                    previousState: oldState,
                    currentState: state
                )
            }

        case "DISCONNECTED":
            cancelPendingIncomingReport()
            finishSystemCall(
                previousState: oldState,
                currentState: state
            )

        case "ERROR":
            // Defensive fallback only. ERROR is not a carrier call state and
            // must never end the system call. Wait for an authoritative
            // IDLE/DISCONNECTED transition instead.
            DiagnosticLog.active?.log(
                "CALLKIT",
                "ignored non-authoritative ERROR; waiting for carrier call state"
            )
            status = "Call control error ignored"

        default:
            break
        }

        if !commandError {
            previousCellularState = state
        }
    }

    private func reportIncomingIfNeeded(number: String) {
        // If CallKit already knows about this ringing call, refresh metadata
        // if the J6 later provides a more complete caller number.
        if let uuid = currentCallUUID {
            guard !number.isEmpty else { return }

            updateHistoryNumber(uuid: uuid, number: number)
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
        currentCallEverActive = false
        outgoingCarrierStateSeen = false

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

            // Resolve Contacts BEFORE the first CallKit report. For a match,
            // makeCallUpdate uses the phone number from that CNContact and lets
            // iOS own Contacts identity resolution from the very first system
            // presentation (Lock Screen / Dynamic Island / call UI).
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
            self.beginHistory(
                uuid: uuid,
                direction: .incoming,
                number: lookupNumber
            )
            self.incomingReportTask = nil
            self.bindCurrentCallToRemoteIfPossible()

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
                self.abandonHistory(uuid: uuid)

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

        let endedAt = Date()
        let endedLocally = locallyEndingUUIDs.remove(uuid) != nil
        let answerWasRequested = answeredIncomingUUIDs.remove(uuid) != nil
        let wasUnansweredIncoming =
            currentDirection == .incoming &&
            previousState == "RINGING" &&
            !endedLocally &&
            !answerWasRequested
        let wasFailedOutgoing =
            currentDirection == .outgoing &&
            !currentCallEverActive &&
            !outgoingConnectedReported

        if !endedLocally {
            let reason: CXCallEndedReason

            if wasUnansweredIncoming {
                reason = .unanswered
            } else if wasFailedOutgoing {
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
                endedAt: endedAt,
                reason: reason
            )
        }

        let number = currentNumber.isEmpty
            ? displayPhoneNumber
            : currentNumber

        if wasUnansweredIncoming {
            scheduleMissedCallNotification(
                number: number,
                callUUID: uuid
            )
        }

        finalizeHistory(
            uuid: uuid,
            outcome: wasUnansweredIncoming
                ? .missed
                : (wasFailedOutgoing ? .failed : .completed),
            endedAt: endedAt,
            fallbackNumber: number
        )

        clearCurrentCall()
    }

    private func activeRemoteCallID() -> Int? {
        ble.remoteCalls.values.first(where: { $0.state == "ACTIVE" })?.id
    }

    private func bindCurrentCallToRemoteIfPossible() {
        guard let uuid = currentCallUUID,
              remoteCallIDs[uuid] == nil
        else { return }

        let candidates = ble.remoteCalls.values.filter {
            $0.isLive && remoteCallUUIDs[$0.id] == nil
        }
        guard !candidates.isEmpty else { return }

        let normalizedCurrent = currentNumber.filter { $0.isNumber || $0 == "+" }
        let match = candidates.first(where: {
            let n = $0.number.filter { $0.isNumber || $0 == "+" }
            return !normalizedCurrent.isEmpty && n == normalizedCurrent
        }) ?? (candidates.count == 1 ? candidates[0] : nil)

        guard let match else { return }
        remoteCallUUIDs[match.id] = uuid
        remoteCallIDs[uuid] = match.id
        DiagnosticLog.active?.log(
            "CALLKIT",
            "bound primary uuid=\(uuid) remoteID=\(match.id) state=\(match.state)"
        )
    }

    private func syncRemoteCalls(
        _ calls: [Int: BLECallController.RemoteCall]
    ) {
        bindCurrentCallToRemoteIfPossible()

        for call in calls.values {
            let previousRemoteState = previousRemoteCallStates[call.id]

            if call.state == "RINGING",
               remoteCallUUIDs[call.id] == nil {
                // The first ringing call is handled by the legacy STATE path,
                // which performs the contact lookup before its initial report.
                // Any additional ringing call is call waiting.
                if currentCallUUID != nil {
                    reportWaitingIncoming(call)
                }
            }

            if call.state == "DISCONNECTED" {
                finishRemoteCall(
                    id: call.id,
                    lastState: previousRemoteState ?? call.state
                )
            }

            previousRemoteCallStates[call.id] = call.state
        }

        let visibleIDs = Set(calls.keys)
        previousRemoteCallStates = previousRemoteCallStates.filter {
            visibleIDs.contains($0.key)
        }

        // Once Telecom switches the waiting call to ACTIVE, make it the
        // foreground identity for our custom UI while the other call remains
        // mapped/held in CallKit.
        if let active = calls.values.first(where: { $0.state == "ACTIVE" }),
           let uuid = remoteCallUUIDs[active.id] {
            markHistoryConnected(uuid: uuid)

            if currentCallUUID != uuid {
                currentCallUUID = uuid
                persistCallUUID(uuid)
                currentDirection = .incoming
                currentNumber = active.number
                currentCallEverActive = true
                connectedAt = Date()
                let basic = contacts.basicMetadata(for: active.number)
                applyCallMetadata(basic)
            }
        }
    }

    private func reportWaitingIncoming(
        _ call: BLECallController.RemoteCall
    ) {
        guard !pendingRemoteIncomingReports.contains(call.id),
              remoteCallUUIDs[call.id] == nil
        else { return }

        pendingRemoteIncomingReports.insert(call.id)
        let remoteID = call.id
        let number = call.number.isEmpty ? "Unknown" : call.number

        Task { [weak self] in
            guard let self else { return }
            let metadata = await self.contacts.resolve(number: number)

            guard self.ble.remoteCalls[remoteID]?.state == "RINGING",
                  self.remoteCallUUIDs[remoteID] == nil
            else {
                self.pendingRemoteIncomingReports.remove(remoteID)
                return
            }

            let uuid = UUID()
            self.remoteCallUUIDs[remoteID] = uuid
            self.remoteCallIDs[uuid] = remoteID
            self.beginHistory(
                uuid: uuid,
                direction: .incoming,
                number: number
            )
            self.pendingRemoteIncomingReports.remove(remoteID)

            do {
                try await self.provider.reportNewIncomingCall(
                    with: uuid,
                    update: self.makeCallUpdate(metadata: metadata)
                )
                self.status = "Call waiting: \(metadata.displayName ?? metadata.formattedNumber)"
                DiagnosticLog.active?.log(
                    "CALLKIT",
                    "reported waiting remoteID=\(remoteID) uuid=\(uuid)"
                )
            } catch {
                self.abandonHistory(uuid: uuid)
                self.remoteCallUUIDs.removeValue(forKey: remoteID)
                self.remoteCallIDs.removeValue(forKey: uuid)
                self.status = "Call waiting UI failed: \(error.localizedDescription)"
            }
        }
    }

    private func finishRemoteCall(id: Int, lastState: String) {
        guard let uuid = remoteCallUUIDs[id] else { return }

        let otherLiveCallExists = ble.remoteCalls.values.contains {
            $0.id != id && $0.isLive
        }
        if uuid == currentCallUUID && !otherLiveCallExists {
            // The legacy aggregate STATE will immediately become IDLE and
            // finish the final call with the more accurate unanswered/failed
            // reason. Avoid a duplicate provider end report here.
            return
        }

        let endedAt = Date()
        let number = ble.remoteCalls[id]?.number ?? ""
        let endedLocally = locallyEndingUUIDs.remove(uuid) != nil
        let answerWasRequested = answeredIncomingUUIDs.remove(uuid) != nil
        let wasUnansweredIncoming =
            lastState == "RINGING" &&
            !endedLocally &&
            !answerWasRequested

        if !endedLocally {
            provider.reportCall(
                with: uuid,
                endedAt: endedAt,
                reason: wasUnansweredIncoming ? .unanswered : .remoteEnded
            )
        }

        if wasUnansweredIncoming {
            scheduleMissedCallNotification(
                number: number,
                callUUID: uuid
            )
        }

        finalizeHistory(
            uuid: uuid,
            outcome: wasUnansweredIncoming ? .missed : .completed,
            endedAt: endedAt,
            fallbackNumber: number
        )

        remoteCallUUIDs.removeValue(forKey: id)
        remoteCallIDs.removeValue(forKey: uuid)
        pendingRemoteIncomingReports.remove(id)

        if currentCallUUID == uuid {
            if let next = ble.remoteCalls.values.first(where: {
                $0.isLive && $0.id != id
            }), let nextUUID = remoteCallUUIDs[next.id] {
                currentCallUUID = nextUUID
                persistCallUUID(nextUUID)
                currentNumber = next.number
                applyCallMetadata(contacts.basicMetadata(for: next.number))
                connectedAt = next.state == "ACTIVE" ? Date() : nil
                if next.state == "ACTIVE" {
                    markHistoryConnected(uuid: nextUUID)
                }
            }
        }
    }

    private func scheduleMissedCallNotification(
        number: String,
        callUUID: UUID
    ) {
        let lookupNumber = number.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        Task { [weak self] in
            guard let self else { return }

            let metadata: ContactCallMetadata
            if lookupNumber.isEmpty || lookupNumber == "Unknown" {
                metadata = self.contacts.basicMetadata(for: "Unknown")
            } else {
                metadata = await self.contacts.resolve(number: lookupNumber)
            }

            let content = UNMutableNotificationContent()
            content.title = "Missed Call"

            let name = metadata.displayName?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ) ?? ""
            let formattedNumber = metadata.formattedNumber.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

            if !name.isEmpty &&
               !formattedNumber.isEmpty &&
               formattedNumber != name {
                content.body = "\(name)  •  \(formattedNumber)"
            } else if !name.isEmpty {
                content.body = name
            } else if !formattedNumber.isEmpty &&
                      formattedNumber != "Unknown" {
                content.body = formattedNumber
            } else {
                content.body = "Unknown caller"
            }

            content.sound = .default
            content.categoryIdentifier =
                J6NotificationDelegate.missedCallCategoryID
            content.threadIdentifier = "j6.missed-calls"
            content.userInfo = [
                "missedCall": true,
                "caller": lookupNumber
            ]

            let request = UNNotificationRequest(
                identifier: "j6.missed-call.\(callUUID.uuidString)",
                content: content,
                trigger: nil
            )

            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                DiagnosticLog.active?.log(
                    "CALLKIT",
                    "missed_call_notification add_failed"
                )
            }
        }
    }

    private func makeCallUpdate(
        metadata: ContactCallMetadata
    ) -> CXCallUpdate {
        let update = CXCallUpdate()

        let handleValue: String
        if metadata.matchedContact,
           !metadata.formattedNumber.isEmpty {
            // For a Contacts match, hand CallKit the phone number exactly as
            // represented by that CNContact. iOS can then perform its own
            // caller identity lookup, including the contact photo/poster on
            // system surfaces that support it.
            handleValue = metadata.formattedNumber
        } else if !metadata.normalizedNumber.isEmpty {
            handleValue = metadata.normalizedNumber
        } else {
            handleValue = metadata.rawNumber
        }

        update.remoteHandle = CXHandle(
            type: .phoneNumber,
            value: handleValue
        )

        if !metadata.matchedContact,
           let name = metadata.displayName,
           !name.isEmpty {
            // A matched CNContact deliberately leaves localizedCallerName nil
            // so CallKit owns Contacts resolution instead of us overriding it.
            // Keep an explicit fallback only for non-Contacts metadata.
            update.localizedCallerName = name
        }

        update.hasVideo = false
        update.supportsHolding = true
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
        currentCallEverActive = call.hasConnected

        status = call.hasConnected
            ? "Restored active iOS CallKit call"
            : "Restored pending iOS CallKit call"
    }

    private func beginHistory(
        uuid: UUID,
        direction: CallHistoryStore.Direction,
        number: String,
        startedAt: Date = Date()
    ) {
        if var existing = historyContexts[uuid] {
            let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "Unknown" {
                existing.number = trimmed
                historyContexts[uuid] = existing
            }
            return
        }

        historyContexts[uuid] = HistoryContext(
            number: number.trimmingCharacters(in: .whitespacesAndNewlines),
            direction: direction,
            startedAt: startedAt,
            connectedAt: nil
        )
    }

    private func updateHistoryNumber(uuid: UUID, number: String) {
        guard var context = historyContexts[uuid] else { return }
        let trimmed = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty && trimmed != "Unknown" else { return }
        context.number = trimmed
        historyContexts[uuid] = context
    }

    private func markHistoryConnected(uuid: UUID) {
        guard var context = historyContexts[uuid],
              context.connectedAt == nil
        else { return }
        context.connectedAt = Date()
        historyContexts[uuid] = context
    }

    private func finalizeHistory(
        uuid: UUID,
        outcome: CallHistoryStore.Outcome,
        endedAt: Date,
        fallbackNumber: String
    ) {
        guard let context = historyContexts.removeValue(forKey: uuid) else {
            return
        }

        let storedNumber = context.number.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let fallback = fallbackNumber.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let finalNumber =
            storedNumber.isEmpty || storedNumber == "Unknown"
                ? (fallback.isEmpty ? "Unknown" : fallback)
                : storedNumber

        callHistory.record(
            id: uuid,
            startedAt: context.startedAt,
            endedAt: endedAt,
            number: finalNumber,
            direction: context.direction,
            outcome: outcome,
            connectedAt: context.connectedAt
        )
    }

    private func abandonHistory(uuid: UUID) {
        historyContexts.removeValue(forKey: uuid)
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
        remoteCallUUIDs.removeAll()
        remoteCallIDs.removeAll()
        pendingRemoteIncomingReports.removeAll()
        locallyEndingUUIDs.removeAll()
        pendingOutgoingStartUUIDs.removeAll()
        cancelledOutgoingStartUUIDs.removeAll()
        answeredIncomingUUIDs.removeAll()
        previousRemoteCallStates.removeAll()

        relay.disableCallKitAudioManagement()
        relay.handleCellularState(ble.callState)

        status = reason
    }

    private func finishCancelledOutgoingSetup(uuid: UUID) {
        ble.clearOptimisticOutgoingUI()
        relay.handleCellularState("IDLE")
        relay.disableCallKitAudioManagement()
        failedOutgoingNumber = nil

        if currentCallUUID == uuid {
            clearCurrentCall()
        }

        status = "Call cancelled"
    }

    private func describeCallKitError(_ error: Error) -> String {
        let nsError = error as NSError
        return
            "\(nsError.domain) code=\(nsError.code): "
            + nsError.localizedDescription
    }

    private func clearCurrentCall() {
        cancelPendingIncomingReport()
        if let uuid = currentCallUUID {
            if let remoteID = remoteCallIDs.removeValue(forKey: uuid) {
                remoteCallUUIDs.removeValue(forKey: remoteID)
                pendingRemoteIncomingReports.remove(remoteID)
            }
            locallyEndingUUIDs.remove(uuid)
            answeredIncomingUUIDs.remove(uuid)
        }
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
        currentCallEverActive = false
        outgoingCarrierStateSeen = false
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
        pendingOutgoingStartUUIDs.remove(action.callUUID)
        let wasCancelled =
            cancelledOutgoingStartUUIDs.contains(action.callUUID)
        let isStale =
            currentCallUUID != action.callUUID

        if wasCancelled || isStale {
            cancelledOutgoingStartUUIDs.insert(action.callUUID)
            DiagnosticLog.active?.log(
                "CALLKIT",
                "suppressed cancelled outgoing start uuid=\(action.callUUID)"
            )
            finishCancelledOutgoingSetup(uuid: action.callUUID)

            // Fulfill the queued Start so CallKit can retire the transaction,
            // then immediately report it ended. Never send CMD|DIAL here.
            action.fulfill()
            provider.reportCall(
                with: action.callUUID,
                endedAt: Date(),
                reason: .remoteEnded
            )
            return
        }

        relay.prepareCallKitAudioSession()

        // Pre-arm the iPhone audio lifecycle before the BLE/Telecom DIALING
        // round-trip. On a cold app launch, waiting for J6 to publish DIALING
        // can otherwise leave CallKit audio unprepared for the first moments of
        // the cellular call. CallKit still owns AVAudioSession activation; this
        // only marks audio as desired so didActivate can start immediately.
        relay.enableCallKitAudioManagement()
        relay.handleCellularState("DIALING")

        let number = action.handle.value
        let started = ble.performDial(
            number: number
        )

        if started {
            callKitAvailable = true

            currentCallUUID = action.callUUID
            persistCallUUID(action.callUUID)
            currentDirection = .outgoing
            currentNumber = number
            beginHistory(
                uuid: action.callUUID,
                direction: .outgoing,
                number: number
            )

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
            // Undo the optimistic audio pre-arm if the BLE command could not be
            // sent. No physical GSM call exists in this path.
            relay.handleCellularState("IDLE")
            relay.disableCallKitAudioManagement()
            failedOutgoingNumber =
                currentNumber.isEmpty
                    ? displayPhoneNumber
                    : currentNumber
            ble.clearOptimisticOutgoingUI()
            status =
                "Could not start cellular call"
            action.fail()
            provider.reportCall(
                with: action.callUUID,
                endedAt: Date(),
                reason: .failed
            )
            finalizeHistory(
                uuid: action.callUUID,
                outcome: .failed,
                endedAt: Date(),
                fallbackNumber: number
            )
            clearCurrentCall()
        }
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXAnswerCallAction
    ) {
        relay.prepareCallKitAudioSession()

        let sent: Bool
        if let remoteID = remoteCallIDs[action.callUUID] {
            sent = ble.answerCall(id: remoteID)
        } else {
            sent = ble.answer()
        }

        if sent {
            answeredIncomingUUIDs.insert(action.callUUID)
            status = "Call answered"
            action.fulfill()
        } else {
            status = "Bluetooth unavailable while answering"
            action.fail()
        }
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXEndCallAction
    ) {
        if pendingOutgoingStartUUIDs.contains(action.callUUID) ||
           cancelledOutgoingStartUUIDs.contains(action.callUUID) {
            cancelledOutgoingStartUUIDs.insert(action.callUUID)
            pendingOutgoingStartUUIDs.remove(action.callUUID)
            finishCancelledOutgoingSetup(uuid: action.callUUID)
            action.fulfill()
            cancelledOutgoingStartUUIDs.remove(action.callUUID)
            return
        }

        locallyEndingUUIDs.insert(action.callUUID)

        let remoteID = remoteCallIDs[action.callUUID]
        let remoteState = remoteID.flatMap { ble.remoteCalls[$0]?.state }
        let anotherLiveCallExists: Bool
        if let remoteID {
            anotherLiveCallExists = ble.remoteCalls.values.contains { call in
                call.isLive && call.id != remoteID
            }
        } else {
            anotherLiveCallExists = false
        }

        // Rejecting a waiting call, ending a held call, or doing End & Accept
        // must not tear down the audio engine while another cellular call is
        // still present. Telecom will switch the media route underneath the
        // warm native relay.
        let endingForegroundAudio =
            !anotherLiveCallExists &&
            action.callUUID == currentCallUUID &&
            (remoteState == nil || remoteState == "ACTIVE" ||
                remoteState == "DIALING" || remoteState == "CONNECTING")
        if endingForegroundAudio {
            relay.handleCellularState("DISCONNECTING")
        }

        let sent: Bool
        if let remoteID {
            if remoteState == "RINGING" {
                sent = ble.rejectCall(id: remoteID)
            } else {
                sent = ble.hangupCall(id: remoteID)
            }
        } else if ble.callState == "RINGING" {
            sent = ble.reject()
        } else {
            sent = ble.hangup()
        }

        if sent {
            status = "Ending cellular call"
            action.fulfill()
        } else {
            locallyEndingUUIDs.remove(action.callUUID)
            status = "Bluetooth unavailable while ending call"
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
            status = "DTMF failed: Bluetooth unavailable"
            action.fail()
        }
    }

    func provider(
        _ provider: CXProvider,
        perform action: CXSetHeldCallAction
    ) {
        guard let remoteID = remoteCallIDs[action.callUUID] else {
            status = "Hold failed: call ID not synchronized"
            action.fail()
            return
        }

        let sent = ble.setHeld(
            callID: remoteID,
            held: action.isOnHold
        )
        if sent {
            status = action.isOnHold
                ? "Call placed on hold"
                : "Call resumed"
            action.fulfill()
        } else {
            status = "Hold/resume failed: Bluetooth unavailable"
            action.fail()
        }
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
        // Track the whole CallKit group so ending the secondary call does
        // not make the custom UI think there are no system calls left.
        systemCallPresent = callObserver.calls.contains { !$0.hasEnded }

        guard let currentCallUUID,
              call.uuid == currentCallUUID
        else {
            if remoteCallIDs[call.uuid] != nil {
                DiagnosticLog.active?.log(
                    "CALLKIT",
                    "secondary changed uuid=\(call.uuid) connected=\(call.hasConnected) held=\(call.isOnHold) ended=\(call.hasEnded)"
                )
            }
            return
        }

        systemCallConnected = call.hasConnected
        systemCallOutgoing = call.isOutgoing

        if call.hasEnded {
            clearPersistedCallUUID()
            status = "iOS system call ended"
        } else if call.isOnHold {
            status = "iOS system call on hold"
        } else if call.hasConnected {
            status = "iOS system call active"
        } else if call.isOutgoing {
            status = "iOS system outgoing call"
        } else {
            status = "iOS system incoming call"
        }
    }
}
