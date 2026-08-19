import Combine
import CoreBluetooth
import Foundation

final class BLECallController: NSObject, ObservableObject {

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

    @Published var dialNumber = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var stateCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var intentionalDisconnect = false

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
                "J6 restored — discovering call service…"
            candidate.discoverServices([Self.serviceUUID])

        case .connecting:
            isConnected = false
            bluetoothStatus =
                "Waiting for restored J6 connection…"

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
        bluetoothStatus = "Scanning for J6…"

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

    func audioReady() {
        _ = sendCommand("CMD|AUDIO_READY")
        audioPeerStatus = "iPhone call audio ready"
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
            bluetoothStatus = "J6 BLE is not connected."
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

        let sent = sendCommand("CMD|DIAL|\(number)")
        if !sent {
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

        bluetoothStatus = "Reconnecting to saved J6…"
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

        bluetoothStatus = "Connecting to J6…"
        central.connect(
            candidate,
            options: connectionOptions
        )
    }

    private func clearConnection() {
        peripheral = nil
        stateCharacteristic = nil
        commandCharacteristic = nil
        isConnected = false

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
            bluetoothStatus = "J6 BLE is not connected."
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

        bluetoothStatus = "Sent \(wire)"
        return true
    }

    private func handleStateData(_ data: Data) {
        guard let wire = String(data: data, encoding: .utf8) else {
            return
        }

        lastWireState = wire

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

        // Publish caller identity BEFORE callState. CallKit observes
        // callState, so RINGING must never be delivered while callerID still
        // contains the previous/empty value.
        callerID = newCallerID
        callState = newState

        // Once J6 reports a real state, it becomes authoritative.
        uiCallState = newState

        if !newCallerID.isEmpty {
            uiCallerID = newCallerID
        } else if newState == "IDLE" ||
                  newState == "DISCONNECTED" {
            uiCallerID = ""
        }

        if newState == "ERROR" {
            bluetoothStatus = "J6: \(newCallerID)"
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
        bluetoothStatus = "Restoring J6 BLE…"
        resumePeripheral(restoredJ6)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        bluetoothStatus = "Found J6 at RSSI \(RSSI)."
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
            bluetoothStatus = "J6 disconnected."
            clearConnection()
            return
        }

        bluetoothStatus =
            "J6 unavailable — reconnecting automatically…"

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

        if systemIsReconnecting {
            bluetoothStatus =
                "J6 link dropped — iOS is reconnecting…"
            return
        }

        bluetoothStatus =
            "J6 link dropped — reconnecting automatically…"

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
            return
        }

        guard let service = peripheral.services?.first(
            where: { $0.uuid == Self.serviceUUID }
        ) else {
            bluetoothStatus = "J6 call service not found."
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
            bluetoothStatus = "J6 BLE characteristics incomplete."
            return
        }

        peripheral.setNotifyValue(
            true,
            for: stateCharacteristic
        )

        peripheral.readValue(for: stateCharacteristic)
        bluetoothStatus = "J6 BLE control ready."

        // Tell the J6 where to send UDP downlink audio. The encrypted
        // characteristic write also participates in the normal pairing flow.
        configureAudioPeer()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            bluetoothStatus =
                "Notify setup failed: \(error.localizedDescription)"
            return
        }

        if characteristic.uuid == Self.stateUUID,
           characteristic.isNotifying {
            bluetoothStatus = "J6 call notifications enabled."
            peripheral.readValue(for: characteristic)
            configureAudioPeer()
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
            return
        }

        guard characteristic.uuid == Self.stateUUID,
              let data = characteristic.value
        else {
            return
        }

        handleStateData(data)
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
        }
    }
}
