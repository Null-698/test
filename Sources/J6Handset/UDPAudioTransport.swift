import Foundation
import Network

final class UDPAudioTransport {
    struct Snapshot {
        let sentFrames: Int
        let receivedFrames: Int
        let sendErrors: Int
        let receiveErrors: Int
        let badWirePackets: Int
    }

    var onPacket: ((AudioWirePacket) -> Void)?
    var onState: ((String) -> Void)?

    private let queue = DispatchQueue(
        label: "J6Handset.UDP",
        qos: .userInteractive
    )
    private let lock = NSLock()

    private var listener: NWListener?
    private var sender: NWConnection?
    private var receivers: [ObjectIdentifier: NWConnection] = [:]

    // Timestamp/sequence are driven by produced audio frames, not timers.
    private var sendSessionID = UInt32.random(in: UInt32.min...UInt32.max)
    private var sendSequence = UInt32.random(in: UInt32.min...UInt32.max)
    private var sendTimestamp = UInt32.random(in: UInt32.min...UInt32.max)

    private var sentFrames = 0
    private var receivedFrames = 0
    private var sendErrors = 0
    private var receiveErrors = 0
    private var badWirePackets = 0

    func start(
        j6Host: String,
        receivePort: UInt16 = 41000,
        sendPort: UInt16 = 41001
    ) throws {
        stop()

        guard let listenPort = NWEndpoint.Port(rawValue: receivePort),
              let destinationPort = NWEndpoint.Port(rawValue: sendPort)
        else {
            throw TransportError.invalidPort
        }

        resetCounters()
        sendSessionID = UInt32.random(in: UInt32.min...UInt32.max)
        sendSequence = UInt32.random(in: UInt32.min...UInt32.max)
        sendTimestamp = UInt32.random(in: UInt32.min...UInt32.max)

        let listener = try NWListener(using: .udp, on: listenPort)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState?("UDP listening on \(receivePort)")
            case .waiting(let error):
                self.onState?(
                    "UDP listener waiting: \(error.localizedDescription)"
                )
            case .failed(let error):
                self.incrementReceiveErrors()
                self.onState?(
                    "UDP listener failed: \(error.localizedDescription)"
                )
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        let sender = NWConnection(
            host: NWEndpoint.Host(j6Host),
            port: destinationPort,
            using: .udp
        )
        self.sender = sender

        sender.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState?("UDP ready → \(j6Host):\(sendPort)")
            case .waiting(let error):
                self.onState?(
                    "UDP sender waiting: \(error.localizedDescription)"
                )
            case .failed(let error):
                self.incrementSendErrors()
                self.onState?(
                    "UDP sender failed: \(error.localizedDescription)"
                )
            default:
                break
            }
        }
        sender.start(queue: queue)
    }

    func send(_ pcm: Data) {
        guard pcm.count == AudioWirePacket.payloadBytes else { return }

        queue.async { [weak self] in
            guard let self,
                  let sender = self.sender
            else {
                return
            }

            let packet = AudioWirePacket(
                sessionID: self.sendSessionID,
                sequence: self.sendSequence,
                timestamp: self.sendTimestamp,
                pcm: pcm,
                arrivalUptimeNS: 0
            ).encoded()

            self.sendSequence &+= 1
            self.sendTimestamp &+= AudioWirePacket.samplesPerPacket

            sender.send(
                content: packet,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error == nil {
                        self.incrementSentFrames()
                    } else {
                        self.incrementSendErrors()
                    }
                }
            )
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil

        sender?.cancel()
        sender = nil

        for connection in receivers.values {
            connection.cancel()
        }
        receivers.removeAll()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        return Snapshot(
            sentFrames: sentFrames,
            receivedFrames: receivedFrames,
            sendErrors: sendErrors,
            receiveErrors: receiveErrors,
            badWirePackets: badWirePackets
        )
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        receivers[id] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }

            switch state {
            case .ready:
                self.receiveNext(on: connection)
            case .failed:
                self.incrementReceiveErrors()
                self.receivers.removeValue(
                    forKey: ObjectIdentifier(connection)
                )
            case .cancelled:
                self.receivers.removeValue(
                    forKey: ObjectIdentifier(connection)
                )
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                if let packet = AudioWirePacket.decode(data) {
                    self.incrementReceivedFrames()
                    self.onPacket?(packet)
                } else {
                    self.incrementBadWirePackets()
                }
            }

            if error == nil {
                self.receiveNext(on: connection)
            } else {
                self.incrementReceiveErrors()
                connection.cancel()
                self.receivers.removeValue(
                    forKey: ObjectIdentifier(connection)
                )
            }
        }
    }

    private func resetCounters() {
        lock.lock()
        sentFrames = 0
        receivedFrames = 0
        sendErrors = 0
        receiveErrors = 0
        badWirePackets = 0
        lock.unlock()
    }

    private func incrementSentFrames() {
        lock.lock()
        sentFrames += 1
        lock.unlock()
    }

    private func incrementReceivedFrames() {
        lock.lock()
        receivedFrames += 1
        lock.unlock()
    }

    private func incrementSendErrors() {
        lock.lock()
        sendErrors += 1
        lock.unlock()
    }

    private func incrementReceiveErrors() {
        lock.lock()
        receiveErrors += 1
        lock.unlock()
    }

    private func incrementBadWirePackets() {
        lock.lock()
        badWirePackets += 1
        lock.unlock()
    }

    enum TransportError: Error {
        case invalidPort
    }
}
