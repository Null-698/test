import Combine
import CoreBluetooth
import Foundation

final class BLECallController: NSObject, ObservableObject {

    struct RemoteCall: Identifiable, Equatable {
        let id: Int
        var state: String
        var number: String
        var supportsHold: Bool

        var isLive: Bool {
            state != "DISCONNECTED" && state != "DISCONNECTING"
        }
    }

    static let serviceUUID =
        CBUUID(string: "8B52D000-7F2A-4B7A-8E32-A17B459F2001")
    static let stateUUID =
        CBUUID(string: "8B52D001-7F2A-4B7A-8E32-A17B459F2001")
    static let commandUUID =
        CBUUID(string: "8B52D002-7F2A-4B7A-8E32-A17B459F2001")

    @Published private(set) var bluetoothStatus = "Starting Bluetooth…"
    @Published private(set) var isConnected = false
    @Published private(set) var isScanning = false
    @Published private(set) var callState = "IDLE"
    @Published private(set) var callerID = ""

    // UI-facing state. For outbound calls this changes immediately when
    // Dial is tapped, rather than waiting for the J6 Telecom notification
    // to make the BLE round trip back to the iPhone.
    @Published private(set) var uiCallState = "IDLE"
    @Published private(set) var uiCallerID = ""
    @Published private(set) var lastWireState = "STATE|IDLE|"
    @Published private(set) var audioPeerStatus = "Waiting for BLE…"
    @Published private(set) var j6LanIP = ""
    @Published private(set) var remoteCalls: [Int: RemoteCall] = [:]

    @Published var dialNumber = ""

    // One-shot USSD state. The request executes on the J6 SIM through
    // Android TelephonyManager and the response is reassembled from BLE
    // chunks here. This never enters CallKit or the call-audio path.
    @Published private(set) var ussdPending = false
    @Published private(set) var ussdRequest = ""
    @Published private(set) var ussdResponse = ""
    @Published private(set) var ussdSucceeded = false
    @Published var isUssdSheetPresented = false

    private var ussdRequestID = ""
    private var ussdChunkStatus = ""
    private var ussdExpectedChunks = 0
    private var ussdChunks: [Int: String] = [:]
    private var ussdTimeoutWorkItem: DispatchWorkItem?

    // SMS is bulk/non-real-time data. Messages are reassembled from small BLE
    // chunks and handed to SMSController. The live audio path remains UDP.
    private struct SMSQueuedCommand {
        let requestID: String
        let wire: String
    }

    private var smsExpectedChunks: [String: Int] = [:]
    private var smsChunks: [String: [Int: String]] = [:]
    private var smsCommandQueue: [SMSQueuedCommand] = []

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var stateCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var intentionalDisconnect = false
    private var gattRecoveryInProgress = false

    private let savedPeripheralKey = "J6BlePeripheralIdentifier"

    override init() {
        super.init()

        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionRestoreIdentifierKey:
                    "com.regis.j6handset.central"
            ]
        )
    }

    private var connectionOptions: [String: Any] {
        var options: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ]

        if #available(iOS 17.0, *) {
            // Let CoreBluetooth own reconnection timing in the background.
            // This survives J6 radio/reboot interruptions much better than
            // app-level scan timers.
            options[CBConnectPeripheralOptionEnableAutoReconnect] = true
        }

        return options
    }

    private func resumePeripheral(_ candidate: CBPeripheral) {
        peripheral = candidate
        candidate.delegate = self

        switch candidate.state {
        case .connected:
            isConnected = true
            bluetoothStatus =
                "Restored — connecting…"
            candidate.discoverServices([Self.serviceUUID])

        case .connecting:
            isConnected = false
            bluetoothStatus =
                "Waiting for connection…"

        default:
            isConnected = false
            connect(candidate)
        }
    }

    private func reconnectKnownPeripheral() -> Bool {
        if let peripheral {
            resumePeripheral(peripheral)
            return true
        }

        return trySavedPeripheral()
    }

    func scan() {
        guard central.state == .poweredOn else {
            bluetoothStatus = "Bluetooth is not powered on."
            return
        }

        if isConnected {
            return
        }

        central.stopScan()
        isScanning = true
        bluetoothStatus = "Scanning…"

        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ]
        )
    }

    func disconnect() {
        intentionalDisconnect = true
        central.stopScan()
        isScanning = false

        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        } else {
            clearConnection()
        }
    }

    @discardableResult
    func answer() -> Bool {
        sendCommand("CMD|ANSWER")
    }

    @discardableResult
    func reject() -> Bool {
        sendCommand("CMD|REJECT")
    }

    @discardableResult
    func answerCall(id: Int) -> Bool {
        sendCommand("CMD|ANSWER_CALL|\(id)")
    }

    @discardableResult
    func rejectCall(id: Int) -> Bool {
        sendCommand("CMD|REJECT_CALL|\(id)")
    }

    @discardableResult
    func hangupCall(id: Int) -> Bool {
        sendCommand("CMD|HANGUP_CALL|\(id)")
    }

    @discardableResult
    func setHeld(callID: Int, held: Bool) -> Bool {
        sendCommand(held
            ? "CMD|HOLD_CALL|\(callID)"
            : "CMD|UNHOLD_CALL|\(callID)")
    }

    @discardableResult
    func swapCalls() -> Bool {
        sendCommand("CMD|SWAP")
    }

    @discardableResult
    func syncState() -> Bool {
        sendCommand("CMD|SYNC")
    }

    @discardableResult
    func hangup() -> Bool {
        if uiCallState != "IDLE" &&
           uiCallState != "DISCONNECTED" {
            uiCallState = "DISCONNECTING"
        }

        return sendCommand("CMD|HANGUP")
    }

    @discardableResult
    func ping() -> Bool {
        sendCommand("CMD|PING")
    }

    @discardableResult
    func syncSMS() -> Bool {
        // J6 keeps only unacknowledged incoming messages. iPhone is the
        // canonical history, so reconnect sync asks for the pending queue only.
        sendCommand("CMD|SMS_SYNC|0")
    }

    @discardableResult
    private func acknowledgeSMS(_ messageID: String) -> Bool {
        guard !messageID.isEmpty, messageID.count <= 64 else { return false }
        return sendCommand("CMD|SMS_ACK|\(messageID)")
    }

    /// Queues a carrier SMS through the J6 SIM. Returns a request ID after all
    /// BLE chunks are queued locally; Android later returns SMS_SEND_RESULT.
    func sendSMS(to rawRecipient: String, body rawBody: String) -> String? {
        let recipient = rawRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !recipient.isEmpty, recipient.count <= 64 else {
            bluetoothStatus = "Invalid SMS recipient."
            DiagnosticLog.active?.log(
                "SMS",
                "send_rejected reason=BAD_RECIPIENT recipientChars=\(recipient.count) bodyChars=\(body.count)"
            )
            return nil
        }
        guard !body.isEmpty, body.count <= 4_096 else {
            bluetoothStatus = body.isEmpty ? "SMS message is empty." : "SMS is too long."
            DiagnosticLog.active?.log(
                "SMS",
                "send_rejected reason=BAD_BODY recipientChars=\(recipient.count) bodyChars=\(body.count)"
            )
            return nil
        }
        guard let peripheral,
              let commandCharacteristic,
              peripheral.state == .connected,
              commandCharacteristic.properties.contains(.writeWithoutResponse)
        else {
            bluetoothStatus = "Bluetooth is not ready for SMS."
            DiagnosticLog.active?.log(
                "SMS",
                "send_rejected reason=BLE_NOT_READY recipientChars=\(recipient.count) bodyChars=\(body.count)"
            )
            return nil
        }

        let envelope: [String: Any] = [
            "to": recipient,
            "body": body
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              !data.isEmpty
        else {
            bluetoothStatus = "Unable to encode SMS."
            DiagnosticLog.active?.log(
                "SMS",
                "send_rejected reason=ENCODE_FAILED recipientChars=\(recipient.count) bodyChars=\(body.count)"
            )
            return nil
        }

        let encoded = data.base64EncodedString()
        let chunkSize = 64
        var chunks: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(
                index,
                offsetBy: chunkSize,
                limitedBy: encoded.endIndex
            ) ?? encoded.endIndex
            chunks.append(String(encoded[index..<end]))
            index = end
        }

        guard !chunks.isEmpty, chunks.count <= 256 else {
            bluetoothStatus = "SMS is too long."
            DiagnosticLog.active?.log(
                "SMS",
                "send_rejected reason=TOO_MANY_BLE_CHUNKS chunks=\(chunks.count) bodyChars=\(body.count)"
            )
            return nil
        }

        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        DiagnosticLog.active?.log(
            "SMS",
            "send_queued request=\(String(requestID.prefix(8))) recipientChars=\(recipient.count) bodyChars=\(body.count) bleChunks=\(chunks.count) encodedBytes=\(data.count)"
        )
        for (partIndex, chunk) in chunks.enumerated() {
            smsCommandQueue.append(
                SMSQueuedCommand(
                    requestID: requestID,
                    wire: "CMD|SMS_SEND|\(requestID)|\(partIndex + 1),\(chunks.count),\(chunk)"
                )
            )
        }
        drainSMSCommandQueue()
        bluetoothStatus = "Sending SMS…"
        return requestID
    }

    private func drainSMSCommandQueue() {
        guard let peripheral,
              let commandCharacteristic,
              peripheral.state == .connected,
              commandCharacteristic.properties.contains(.writeWithoutResponse)
        else { return }

        while !smsCommandQueue.isEmpty && peripheral.canSendWriteWithoutResponse {
            let command = smsCommandQueue.removeFirst()
            peripheral.writeValue(
                Data(command.wire.utf8),
                for: commandCharacteristic,
                type: .withoutResponse
            )
        }
    }

    func audioReady() {
        _ = sendCommand("CMD|AUDIO_READY")
        audioPeerStatus = "iPhone call audio ready"
    }

    @discardableResult
    func sendDtmf(_ rawDigits: String) -> Bool {
        let digits = rawDigits.filter {
            $0.isNumber || $0 == "*" || $0 == "#"
        }

        guard !digits.isEmpty,
              digits.count <= 32,
              digits.count == rawDigits.count
        else {
            bluetoothStatus = "Invalid DTMF digits."
            return false
        }

        guard callState == "ACTIVE" ||
              uiCallState == "ACTIVE"
        else {
            bluetoothStatus = "DTMF requires an active call."
            return false
        }

        return sendCommand("CMD|DTMF|\(digits)")
    }

    func dial() {
        _ = performDial(number: dialNumber)
    }

    @discardableResult
    func prepareOutgoingUI(number rawNumber: String) -> Bool {
        let number = rawNumber.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard isValidDialString(number) else {
            bluetoothStatus = "Enter a valid phone number."
            return false
        }

        guard isConnected,
              peripheral != nil,
              commandCharacteristic != nil
        else {
            bluetoothStatus = "Bluetooth is not connected."
            return false
        }

        uiCallState = "DIALING"
        uiCallerID = number
        return true
    }

    @discardableResult
    func performDial(number rawNumber: String) -> Bool {
        let number = rawNumber.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard prepareOutgoingUI(number: number) else {
            return false
        }

        // Do not rely on a separate AUDIO_PEER write having reached the J6.
        // After an app reinstall/relaunch the BLE control link can become ready
        // before that configuration write has completed, which lets Telecom
        // start the cellular route locally for a moment. Carry the current
        // iPhone Wi-Fi address in the same DIAL command so the J6 can commit the
        // peer before it places the carrier call.
        let peerIP = (LocalIPAddress.currentIPv4() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidIPv4(peerIP) else {
            bluetoothStatus = "No usable iPhone Wi-Fi IPv4 for call audio."
            audioPeerStatus = "Call not started: audio peer unavailable."
            clearOptimisticOutgoingUI()
            return false
        }

        let sent = sendCommand("CMD|DIAL|\(number)|\(peerIP)")
        if sent {
            audioPeerStatus = "Call audio peer armed."
        } else {
            clearOptimisticOutgoingUI()
        }
        return sent
    }

    func clearOptimisticOutgoingUI() {
        if callState == "IDLE" ||
           callState == "DISCONNECTED" {
            uiCallState = callState
            uiCallerID = ""
        }
    }

    @discardableResult
    func sendUssd(_ rawCode: String) -> Bool {
        let code = rawCode.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard isValidUssdCode(code) else {
            bluetoothStatus = "Enter a valid USSD code."
            return false
        }

        guard !ussdPending else {
            bluetoothStatus = "A USSD request is already running."
            isUssdSheetPresented = true
            return false
        }

        guard callState == "IDLE" ||
              callState == "DISCONNECTED" else {
            bluetoothStatus = "USSD is unavailable during a call."
            return false
        }

        guard isConnected, peripheral != nil,
              commandCharacteristic != nil else {
            bluetoothStatus = "Bluetooth is not connected."
            return false
        }

        let requestID = String(UInt32.random(in: 1...UInt32.max))
        ussdTimeoutWorkItem?.cancel()
        ussdRequestID = requestID
        ussdRequest = code
        ussdResponse = ""
        ussdSucceeded = false
        ussdPending = true
        ussdChunkStatus = ""
        ussdExpectedChunks = 0
        ussdChunks.removeAll(keepingCapacity: true)
        isUssdSheetPresented = true

        guard sendCommand("CMD|USSD|\(requestID)|\(code)") else {
            ussdPending = false
            ussdResponse = "Unable to send the USSD request."
            return false
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.ussdPending,
                  self.ussdRequestID == requestID else {
                return
            }

            self.ussdPending = false
            self.ussdSucceeded = false
            self.ussdResponse = "USSD request timed out."
            self.bluetoothStatus = "USSD request timed out."
        }
        ussdTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 35.0,
            execute: timeout
        )
        return true
    }

    func dismissUssdSheet() {
        isUssdSheetPresented = false
    }

    func configureAudioPeer(ip: String? = nil) {
        let candidate = (ip ?? LocalIPAddress.currentIPv4() ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard isValidIPv4(candidate) else {
            audioPeerStatus = "No usable iPhone Wi-Fi IPv4 yet."
            return
        }

        guard commandCharacteristic != nil, peripheral != nil else {
            audioPeerStatus = "Will send iPhone IP after BLE connects."
            return
        }

        _ = sendCommand("CMD|AUDIO_PEER|\(candidate)")
        audioPeerStatus = "Sent iPhone IP: \(candidate)"
    }

    private func trySavedPeripheral() -> Bool {
        guard
            let raw = UserDefaults.standard.string(
                forKey: savedPeripheralKey
            ),
            let uuid = UUID(uuidString: raw)
        else {
            return false
        }

        let known = central.retrievePeripherals(
            withIdentifiers: [uuid]
        )

        guard let saved = known.first else {
            return false
        }

        bluetoothStatus = "Reconnecting…"
        connect(saved)
        return true
    }

    private func connect(_ candidate: CBPeripheral) {
        central.stopScan()
        isScanning = false

        peripheral = candidate
        stateCharacteristic = nil
        commandCharacteristic = nil

        candidate.delegate = self
        intentionalDisconnect = false

        bluetoothStatus = "Connecting…"
        central.connect(
            candidate,
            options: connectionOptions
        )
    }

    private func recoverStaleGatt(_ reason: String) {
        guard !intentionalDisconnect else { return }

        stateCharacteristic = nil
        commandCharacteristic = nil
        isConnected = false

        guard central.state == .poweredOn else {
            bluetoothStatus = "Bluetooth unavailable."
            return
        }

        guard !gattRecoveryInProgress else { return }
        gattRecoveryInProgress = true
        bluetoothStatus = "Refreshing Bluetooth connection…"

        guard let peripheral else {
            gattRecoveryInProgress = false
            scan()
            return
        }

        peripheral.delegate = self

        if peripheral.state == .connected ||
           peripheral.state == .connecting {
            central.cancelPeripheralConnection(peripheral)

            // Safety net for Samsung/CoreBluetooth races where the disconnect
            // callback is delayed after the Android GATT server is replaced.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak peripheral] in
                guard let self,
                      self.gattRecoveryInProgress,
                      !self.intentionalDisconnect,
                      self.central.state == .poweredOn
                else { return }

                if let peripheral,
                   peripheral.state != .disconnected {
                    self.central.cancelPeripheralConnection(peripheral)
                }
                self.gattRecoveryInProgress = false
                self.peripheral = nil
                self.scan()
            }
        } else {
            gattRecoveryInProgress = false
            self.peripheral = nil
            scan()
        }

        DiagnosticLog.active?.log("BLE", "GATT recovery: \(reason)")
    }

    private func clearConnection() {
        peripheral = nil
        stateCharacteristic = nil
        commandCharacteristic = nil
        isConnected = false
        if !smsCommandQueue.isEmpty {
            let unsentRequestIDs = Set(smsCommandQueue.map(\.requestID))
            smsCommandQueue.removeAll(keepingCapacity: true)
            SMSController.shared.failSendingMessages(
                requestIDs: unsentRequestIDs
            )
        }

        if central.state == .poweredOn {
            bluetoothStatus = "Disconnected — scanning again…"

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if !self.isConnected {
                    self.scan()
                }
            }
        } else {
            bluetoothStatus = "Bluetooth unavailable."
        }
    }

    @discardableResult
    private func sendCommand(_ wire: String) -> Bool {
        guard
            let peripheral,
            let commandCharacteristic
        else {
            bluetoothStatus = "Bluetooth is not connected."
            return false
        }

        let data = Data(wire.utf8)

        let writeType: CBCharacteristicWriteType =
            commandCharacteristic.properties.contains(.write)
                ? .withResponse
                : .withoutResponse

        peripheral.writeValue(
            data,
            for: commandCharacteristic,
            type: writeType
        )

        let operation = wire.split(separator: "|", maxSplits: 2)
            .dropFirst()
            .first
            .map(String.init) ?? "command"
        bluetoothStatus = "Sent \(operation)."
        return true
    }

    private func handleStateData(_ data: Data) {
        guard let wire = String(data: data, encoding: .utf8) else {
            return
        }

        lastWireState = wire

        if wire.hasPrefix("USSD|") {
            handleUssdWire(wire)
            return
        }

        if wire.hasPrefix("SMS|") {
            handleSmsWire(wire)
            return
        }

        if wire.hasPrefix("SMS_SYNC_DONE|") {
            let count = wire.split(separator: "|", maxSplits: 1)
                .dropFirst().first.map(String.init) ?? "?"
            DiagnosticLog.active?.log("SMS", "sync_done pendingFromJ6=\(count)")
            return
        }

        if wire.hasPrefix("SMS_SEND_RESULT|") {
            handleSmsSendResult(wire)
            return
        }

        if wire.hasPrefix("NET|") {
            let ip = String(wire.dropFirst(4))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidIPv4(ip) {
                if j6LanIP != ip {
                    DiagnosticLog.active?.log(
                        "NET",
                        "J6 BLE endpoint old=\(j6LanIP.isEmpty ? "none" : j6LanIP) new=\(ip)"
                    )
                }
                j6LanIP = ip
                audioPeerStatus = "J6 LAN: \(ip)"
            }
            return
        }

        if wire.hasPrefix("CALL|") {
            let fields = wire.split(
                separator: "|",
                maxSplits: 4,
                omittingEmptySubsequences: false
            )
            guard fields.count >= 5,
                  let id = Int(fields[1])
            else {
                return
            }

            let state = String(fields[2])
            let supportsHold = fields[3] == "1"
            let number = String(fields[4])
            remoteCalls[id] = RemoteCall(
                id: id,
                state: state,
                number: number,
                supportsHold: supportsHold
            )

            DiagnosticLog.active?.log(
                "CALL",
                "remote id=\(id) state=\(state) hold=\(supportsHold) number=\(number)"
            )

            if state == "DISCONNECTED" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard self.remoteCalls[id]?.state == "DISCONNECTED" else {
                        return
                    }
                    self.remoteCalls.removeValue(forKey: id)
                }
            }
            return
        }

        let parts = wire.split(
            separator: "|",
            maxSplits: 2,
            omittingEmptySubsequences: false
        )

        guard parts.count >= 2, parts[0] == "STATE" else {
            return
        }

        let newState = String(parts[1])
        let newCallerID =
            parts.count >= 3 ? String(parts[2]) : ""

        // Android transports command/control failures on the legacy STATE
        // characteristic as STATE|ERROR|<reason>, but ERROR is not a GSM
        // call state. This includes BAD_CALL_ID as well as transient audio,
        // DTMF, hold, sync, and setup command failures. Never let one of
        // those messages replace the authoritative carrier state or tear
        // down CallKit/audio while the real call continues independently.
        // RINGING/CONNECTING/DIALING/ACTIVE/IDLE/DISCONNECTED remain the
        // only lifecycle states.
        if newState == "ERROR" {
            bluetoothStatus = newCallerID.isEmpty
                ? "Call command error"
                : "Call command error: \(newCallerID)"
            DiagnosticLog.active?.log(
                "BLE",
                "ignored command-level ERROR reason=\(newCallerID.isEmpty ? "unknown" : newCallerID); preserving call state=\(callState) ui=\(uiCallState)"
            )
            return
        }

        callerID = newCallerID
        callState = newState
        uiCallState = newState

        if !newCallerID.isEmpty {
            uiCallerID = newCallerID
        } else if newState == "IDLE" ||
                  newState == "DISCONNECTED" {
            uiCallerID = ""
        }

    }

    private func handleSmsWire(_ wire: String) {
        let fields = wire.split(
            separator: "|",
            maxSplits: 4,
            omittingEmptySubsequences: false
        )
        guard fields.count == 5 else { return }

        let messageID = String(fields[1])
        guard !messageID.isEmpty,
              let part = Int(fields[2]),
              let total = Int(fields[3]),
              part >= 1,
              total >= 1,
              part <= total,
              total <= 512
        else { return }

        if smsExpectedChunks[messageID] != total {
            smsExpectedChunks[messageID] = total
            smsChunks[messageID] = [:]
        }
        smsChunks[messageID, default: [:]][part] = String(fields[4])

        guard smsChunks[messageID]?.count == total else { return }

        var encoded = ""
        for index in 1...total {
            guard let chunk = smsChunks[messageID]?[index] else { return }
            encoded += chunk
        }

        defer {
            smsExpectedChunks.removeValue(forKey: messageID)
            smsChunks.removeValue(forKey: messageID)
        }

        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let id = json["id"] as? String,
              id == messageID,
              let sender = json["sender"] as? String,
              let body = json["body"] as? String
        else { return }

        let timestampMs: Int64
        if let value = json["ts"] as? NSNumber {
            timestampMs = value.int64Value
        } else if let value = json["ts"] as? Int64 {
            timestampMs = value
        } else {
            return
        }

        DiagnosticLog.active?.log(
            "SMS",
            "incoming_reassembled id=\(String(id.prefix(8))) senderChars=\(sender.count) bodyChars=\(body.count) bleChunks=\(total)"
        )

        SMSController.shared.receive(
            id: id,
            timestampMs: timestampMs,
            sender: sender,
            body: body
        ) { [weak self] in
            // ACK only after iPhone's atomic sms.json write succeeds. If BLE
            // drops first, J6 keeps the pending copy and reconnect sync retries.
            let queued = self?.acknowledgeSMS(id) ?? false
            DiagnosticLog.active?.log(
                "SMS",
                "incoming_persisted id=\(String(id.prefix(8))) ackQueued=\(queued)"
            )
        }
    }

    private func handleSmsSendResult(_ wire: String) {
        let fields = wire.split(
            separator: "|",
            maxSplits: 3,
            omittingEmptySubsequences: false
        )
        guard fields.count == 4 else { return }

        let requestID = String(fields[1])
        let status = String(fields[2])
        let detail = String(fields[3])
        guard !requestID.isEmpty else { return }

        DiagnosticLog.active?.log(
            "SMS",
            "send_result request=\(String(requestID.prefix(8))) status=\(status) detail=\(detail)"
        )

        switch status {
        case "OK", "SENT":
            SMSController.shared.updateOutgoingStatus(
                requestID: requestID,
                status: .sent
            )
            bluetoothStatus = "SMS sent."

        case "DELIVERED":
            SMSController.shared.updateOutgoingStatus(
                requestID: requestID,
                status: .delivered
            )
            bluetoothStatus = "SMS delivered."

        default:
            SMSController.shared.updateOutgoingStatus(
                requestID: requestID,
                status: .failed
            )
            bluetoothStatus = "SMS failed: \(detail)"
        }
    }

    private func handleUssdWire(_ wire: String) {
        let fields = wire.split(
            separator: "|",
            maxSplits: 5,
            omittingEmptySubsequences: false
        )

        guard fields.count == 6 else {
            return
        }

        let requestID = String(fields[1])
        let status = String(fields[2])
        guard requestID == ussdRequestID,
              let part = Int(fields[3]),
              let total = Int(fields[4]),
              part >= 1, total >= 1, part <= total,
              total <= 128 else {
            return
        }

        if ussdChunkStatus != status ||
           ussdExpectedChunks != total {
            ussdChunkStatus = status
            ussdExpectedChunks = total
            ussdChunks.removeAll(keepingCapacity: true)
        }

        ussdChunks[part] = String(fields[5])
        guard ussdChunks.count == total else {
            return
        }

        var encoded = ""
        for index in 1...total {
            guard let chunk = ussdChunks[index] else {
                return
            }
            encoded += chunk
        }

        let decoded: String
        if let data = Data(base64Encoded: encoded),
           let text = String(data: data, encoding: .utf8) {
            decoded = text
        } else {
            decoded = "Unreadable USSD response."
        }

        ussdTimeoutWorkItem?.cancel()
        ussdTimeoutWorkItem = nil
        ussdPending = false
        ussdSucceeded = (status == "OK")
        ussdResponse = decoded
        isUssdSheetPresented = true
        bluetoothStatus = ussdSucceeded
            ? "USSD response received."
            : "USSD request failed."

        ussdChunks.removeAll(keepingCapacity: true)
    }

    private func isValidUssdCode(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 80,
              value.first == "*" || value.first == "#",
              value.last == "#" else {
            return false
        }

        return value.allSatisfy {
            $0.isNumber || $0 == "*" || $0 == "#" || $0 == "+"
        }
    }

    private func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }

        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isNumber }),
                  let value = Int(part),
                  (0...255).contains(value)
            else {
                return false
            }
        }

        return true
    }

    private func isValidDialString(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 40 else {
            return false
        }

        for char in value {
            guard char.isNumber ||
                    char == "+" ||
                    char == "*" ||
                    char == "#"
            else {
                return false
            }
        }

        return true
    }
}

extension BLECallController: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth ready."

            // Prefer a pending/restored/saved connection. CoreBluetooth keeps
            // connection work on our behalf while the app is suspended.
            if !reconnectKnownPeripheral() {
                scan()
            }

        case .poweredOff:
            bluetoothStatus = "Bluetooth is off."
            clearConnection()

        case .unauthorized:
            bluetoothStatus = "Bluetooth permission denied."
            clearConnection()

        case .unsupported:
            bluetoothStatus = "Bluetooth LE unsupported."
            clearConnection()

        case .resetting:
            bluetoothStatus = "Bluetooth resetting…"

        case .unknown:
            bluetoothStatus = "Bluetooth state unknown."

        @unknown default:
            bluetoothStatus = "Bluetooth state changed."
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        guard let restored =
            dict[CBCentralManagerRestoredStatePeripheralsKey]
                as? [CBPeripheral],
              !restored.isEmpty
        else {
            bluetoothStatus =
                "Bluetooth restored without a peripheral."
            return
        }

        let savedID = UserDefaults.standard.string(
            forKey: savedPeripheralKey
        )

        let restoredJ6 =
            restored.first {
                $0.identifier.uuidString == savedID
            } ?? restored[0]

        intentionalDisconnect = false
        bluetoothStatus = "Restoring Bluetooth…"
        resumePeripheral(restoredJ6)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        bluetoothStatus = "Device found — connecting…"
        connect(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        UserDefaults.standard.set(
            peripheral.identifier.uuidString,
            forKey: savedPeripheralKey
        )

        self.peripheral = peripheral
        peripheral.delegate = self
        intentionalDisconnect = false
        gattRecoveryInProgress = false

        isConnected = true
        bluetoothStatus = "Connected — discovering call service…"

        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        stateCharacteristic = nil
        commandCharacteristic = nil
        self.peripheral = peripheral
        peripheral.delegate = self

        if intentionalDisconnect {
            bluetoothStatus = "Disconnected."
            clearConnection()
            return
        }

        bluetoothStatus =
            "Connection unavailable — reconnecting…"

        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1.0
        ) { [weak self, weak peripheral] in
            guard let self,
                  let peripheral,
                  !self.intentionalDisconnect,
                  self.central.state == .poweredOn,
                  peripheral.state == .disconnected
            else {
                return
            }

            self.central.connect(
                peripheral,
                options: self.connectionOptions
            )
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        handlePeripheralDisconnect(
            peripheral,
            systemIsReconnecting: false,
            error: error
        )
    }

    @available(iOS 17.0, *)
    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        handlePeripheralDisconnect(
            peripheral,
            systemIsReconnecting: isReconnecting,
            error: error
        )
    }

    private func handlePeripheralDisconnect(
        _ peripheral: CBPeripheral,
        systemIsReconnecting: Bool,
        error: Error?
    ) {
        isConnected = false
        stateCharacteristic = nil
        commandCharacteristic = nil
        self.peripheral = peripheral
        peripheral.delegate = self

        if intentionalDisconnect {
            bluetoothStatus = "Disconnected."
            clearConnection()
            return
        }

        if gattRecoveryInProgress {
            gattRecoveryInProgress = false
            self.peripheral = nil
            bluetoothStatus = "Bluetooth refreshed — reconnecting…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self,
                      !self.intentionalDisconnect,
                      self.central.state == .poweredOn,
                      !self.isConnected
                else { return }
                self.scan()
            }
            return
        }

        if systemIsReconnecting {
            bluetoothStatus =
                "Connection lost — iOS is reconnecting…"
            return
        }

        bluetoothStatus =
            "Connection lost — reconnecting…"

        if central.state == .poweredOn &&
           peripheral.state == .disconnected {
            central.connect(
                peripheral,
                options: connectionOptions
            )
        }
    }
}

extension BLECallController: CBPeripheralDelegate {

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error {
            bluetoothStatus =
                "Service discovery failed: \(error.localizedDescription)"
            recoverStaleGatt("service discovery failed")
            return
        }

        guard let service = peripheral.services?.first(
            where: { $0.uuid == Self.serviceUUID }
        ) else {
            bluetoothStatus = "Call service not found."
            recoverStaleGatt("call service missing")
            return
        }

        peripheral.discoverCharacteristics(
            [Self.stateUUID, Self.commandUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            bluetoothStatus =
                "Characteristic discovery failed: \(error.localizedDescription)"
            recoverStaleGatt("characteristic discovery failed")
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.stateUUID:
                stateCharacteristic = characteristic

            case Self.commandUUID:
                commandCharacteristic = characteristic

            default:
                break
            }
        }

        guard
            let stateCharacteristic,
            commandCharacteristic != nil
        else {
            bluetoothStatus = "Bluetooth service unavailable."
            recoverStaleGatt("characteristics incomplete")
            return
        }

        peripheral.setNotifyValue(
            true,
            for: stateCharacteristic
        )

        peripheral.readValue(for: stateCharacteristic)
        bluetoothStatus = "Bluetooth control ready."

        // Tell the J6 where to send UDP downlink audio. The encrypted
        // characteristic write also participates in the normal pairing flow.
        configureAudioPeer()
        _ = syncState()
        _ = syncSMS()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            bluetoothStatus =
                "Notify setup failed: \(error.localizedDescription)"
            recoverStaleGatt("notification setup failed")
            return
        }

        if characteristic.uuid == Self.stateUUID,
           characteristic.isNotifying {
            bluetoothStatus = "Call notifications enabled."
            peripheral.readValue(for: characteristic)
            configureAudioPeer()
            _ = syncState()
            _ = syncSMS()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            bluetoothStatus =
                "State read failed: \(error.localizedDescription)"
            recoverStaleGatt("state read failed")
            return
        }

        guard characteristic.uuid == Self.stateUUID,
              let data = characteristic.value
        else {
            return
        }

        handleStateData(data)
    }

    func peripheralIsReady(
        toSendWriteWithoutResponse peripheral: CBPeripheral
    ) {
        drainSMSCommandQueue()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            bluetoothStatus =
                "Command failed: \(error.localizedDescription)"

            if uiCallState == "DIALING" &&
               callState == "IDLE" {
                uiCallState = "IDLE"
                uiCallerID = ""
            }

            recoverStaleGatt("command write failed")
        }
    }
}
