import Darwin
import Foundation

/// Fixed-port UDP transport for the Stage 2 native HAL audio stream.
///
/// Network.framework's UDP listener models inbound datagrams as NWConnection
/// flows. On the J6's 10 ms stream that produced a new inbound connection for
/// essentially every datagram on the tested iOS build, while receiveMessage()
/// never delivered the datagram payload. A single BSD datagram socket is a
/// better fit here: one socket is bound to 41000 and recvfrom() drains every
/// incoming J6v2 packet directly.
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

    // RX and TX are intentionally independent. A burst of microphone sends
    // must not delay draining the caller's UDP socket, and a receive burst must
    // not hold up 10 ms mic packets.
    private let receiveQueue = DispatchQueue(
        label: "J6Handset.UDP.BSD.RX",
        qos: .userInteractive
    )
    private let sendQueue = DispatchQueue(
        label: "J6Handset.UDP.BSD.TX",
        qos: .userInteractive
    )
    private let receiveQueueKey = DispatchSpecificKey<UInt8>()
    private let sendQueueKey = DispatchSpecificKey<UInt8>()
    private let lock = NSLock()

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var destination = sockaddr_in()
    private var destinationDescription = "not configured"
    private var receiveScratch = [UInt8](repeating: 0, count: 2_048)

    // Timestamp/sequence are driven by produced audio frames, not timers.
    private var sendSessionID = UInt32.random(in: UInt32.min...UInt32.max)
    private var sendSequence = UInt32.random(in: UInt32.min...UInt32.max)
    private var sendTimestamp = UInt32.random(in: UInt32.min...UInt32.max)

    private var sentFrames = 0
    private var receivedFrames = 0
    private var sendErrors = 0
    private var receiveErrors = 0
    private var badWirePackets = 0
    private var debugSendErrorsObserved = 0
    private var debugReceiveErrorsObserved = 0

    init() {
        receiveQueue.setSpecific(key: receiveQueueKey, value: 1)
        sendQueue.setSpecific(key: sendQueueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start(
        j6Host: String,
        receivePort: UInt16 = 41000,
        sendPort: UInt16 = 41001
    ) throws {
        DiagnosticLog.active?.log(
            "UDP",
            "BSD start begin j6=\(j6Host):\(sendPort) bind=0.0.0.0:\(receivePort)"
        )
        stop()

        guard receivePort != 0, sendPort != 0 else {
            throw TransportError.invalidPort
        }

        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(sendPort).bigEndian

        let parseResult = j6Host.withCString { hostCString in
            inet_pton(AF_INET, hostCString, &remote.sin_addr)
        }
        guard parseResult == 1 else {
            throw TransportError.invalidHost(j6Host)
        }

        let fd = Darwin.socket(
            AF_INET,
            SOCK_DGRAM,
            IPPROTO_UDP
        )
        guard fd >= 0 else {
            throw TransportError.socketCreate(errno)
        }

        do {
            try configureSocket(fd)
            try bindSocket(fd, port: receivePort)
        } catch {
            Darwin.close(fd)
            throw error
        }

        resetCounters()
        sendSessionID = UInt32.random(in: UInt32.min...UInt32.max)
        sendSequence = UInt32.random(in: UInt32.min...UInt32.max)
        sendTimestamp = UInt32.random(in: UInt32.min...UInt32.max)
        debugSendErrorsObserved = 0
        debugReceiveErrorsObserved = 0

        sendQueue.sync {
            socketFD = fd
            destination = remote
            destinationDescription = "\(j6Host):\(sendPort)"
        }

        DiagnosticLog.active?.log(
            "UDP",
            "wire_session txSession=\(sendSessionID) startSeq=\(sendSequence) startTs=\(sendTimestamp)"
        )

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: receiveQueue
        )
        source.setEventHandler { [weak self] in
            self?.drainReceiveSocket(fd)
        }
        readSource = source
        source.resume()

        DiagnosticLog.active?.log(
            "UDP",
            "BSD socket READY fd=\(fd) local=0.0.0.0:\(receivePort) remote=\(destinationDescription)"
        )
        onState?("UDP ready ↔ \(j6Host)")
    }

    func updateRemoteHost(
        _ j6Host: String,
        sendPort: UInt16 = 41001
    ) throws {
        guard sendPort != 0 else { throw TransportError.invalidPort }

        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(sendPort).bigEndian

        let parsed = j6Host.withCString { hostCString in
            inet_pton(AF_INET, hostCString, &remote.sin_addr)
        }
        guard parsed == 1 else {
            throw TransportError.invalidHost(j6Host)
        }

        let apply = {
            self.destination = remote
            self.destinationDescription = "\(j6Host):\(sendPort)"
            DiagnosticLog.active?.log(
                "UDP",
                "BSD destination updated remote=\(self.destinationDescription) fd=\(self.socketFD)"
            )
        }

        if DispatchQueue.getSpecific(key: sendQueueKey) != nil {
            apply()
        } else {
            sendQueue.sync(execute: apply)
        }
        onState?("UDP ready ↔ \(j6Host)")
    }

    func send(_ pcm: Data) {
        guard pcm.count == AudioWirePacket.payloadBytes else { return }

        sendQueue.async { [weak self] in
            guard let self else { return }
            let fd = self.socketFD
            guard fd >= 0 else { return }

            let sequence = self.sendSequence
            let timestamp = self.sendTimestamp
            let packet = AudioWirePacket(
                sessionID: self.sendSessionID,
                sequence: sequence,
                timestamp: timestamp,
                pcm: pcm,
                arrivalUptimeNS: 0
            ).encoded()

            self.sendSequence &+= 1
            self.sendTimestamp &+= AudioWirePacket.samplesPerPacket

            var remote = self.destination
            let written: Int = packet.withUnsafeBytes { packetBytes in
                guard let base = packetBytes.baseAddress else { return -1 }
                return withUnsafePointer(to: &remote) { remotePointer in
                    remotePointer.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) { socketAddress in
                        Darwin.sendto(
                            fd,
                            base,
                            packetBytes.count,
                            0,
                            socketAddress,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }

            if written == packet.count {
                self.incrementSentFrames()
            } else {
                let errorNumber = errno
                self.incrementSendErrors()
                self.debugSendErrorsObserved += 1
                if self.debugSendErrorsObserved <= 5 || self.debugSendErrorsObserved % 100 == 0 {
                    DiagnosticLog.active?.log(
                        "UDP-TX",
                        "BSD sendto FAILED n=\(self.debugSendErrorsObserved) errno=\(errorNumber) error=\(self.errorText(errorNumber)) remote=\(self.destinationDescription) wrote=\(written)/\(packet.count)"
                    )
                }
            }
        }
    }

    func stop() {
        let before = snapshot()
        DiagnosticLog.active?.log(
            "UDP",
            "BSD stop tx=\(before.sentFrames) rx=\(before.receivedFrames) txErr=\(before.sendErrors) rxErr=\(before.receiveErrors) bad=\(before.badWirePackets) fd=\(socketFD)"
        )

        let cancelReceive = {
            self.readSource?.cancel()
            self.readSource = nil
        }
        if DispatchQueue.getSpecific(key: receiveQueueKey) != nil {
            cancelReceive()
        } else {
            receiveQueue.sync(execute: cancelReceive)
        }

        var fdToClose: Int32 = -1
        let stopSend = {
            fdToClose = self.socketFD
            self.socketFD = -1
            self.destinationDescription = "not configured"
        }
        if DispatchQueue.getSpecific(key: sendQueueKey) != nil {
            stopSend()
        } else {
            sendQueue.sync(execute: stopSend)
        }

        if fdToClose >= 0 {
            Darwin.close(fdToClose)
        }
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

    private func configureSocket(_ fd: Int32) throws {
        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_REUSEADDR,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        // Leave enough kernel buffering for several seconds of 976-byte,
        // 100-packet/s audio traffic even if iOS briefly delays this queue.
        var receiveBuffer: Int32 = 1_048_576
        _ = withUnsafePointer(to: &receiveBuffer) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVBUF,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var sendBuffer: Int32 = 262_144
        _ = withUnsafePointer(to: &sendBuffer) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDBUF,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        // This socket carries only live, interactive call audio. Describe it
        // to Darwin as voice traffic so iOS and compatible Wi-Fi access points
        // can use the appropriate low-delay/lower-jitter queue. This changes
        // only network scheduling: the fixed 80 ms FIFO, AVAudioPlayerNode,
        // packet format, and PCM playback behavior remain untouched.
        var serviceType = Int32(NET_SERVICE_TYPE_VO)
        let serviceTypeResult = withUnsafePointer(to: &serviceType) { pointer in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NET_SERVICE_TYPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        if serviceTypeResult != 0 {
            let errorNumber = errno
            DiagnosticLog.active?.log(
                "UDP",
                "voice_service_type unavailable errno=\(errorNumber) error=\(errorText(errorNumber)); continuing best-effort"
            )
        }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            throw TransportError.configure(errno)
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TransportError.configure(errno)
        }
    }

    private func bindSocket(_ fd: Int32, port: UInt16) throws {
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = in_port_t(port).bigEndian
        local.sin_addr = in_addr(s_addr: INADDR_ANY)

        let result = withUnsafePointer(to: &local) { localPointer in
            localPointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { socketAddress in
                Darwin.bind(
                    fd,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }

        guard result == 0 else {
            throw TransportError.bind(errno)
        }
    }

    private func drainReceiveSocket(_ fd: Int32) {
        guard fd >= 0 else { return }

        while true {
            var remoteStorage = sockaddr_storage()
            var remoteLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

            let received: Int = receiveScratch.withUnsafeMutableBytes { bufferBytes in
                guard let base = bufferBytes.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &remoteStorage) { remotePointer in
                    remotePointer.withMemoryRebound(
                        to: sockaddr.self,
                        capacity: 1
                    ) { socketAddress in
                        Darwin.recvfrom(
                            fd,
                            base,
                            bufferBytes.count,
                            0,
                            socketAddress,
                            &remoteLength
                        )
                    }
                }
            }

            if received > 0 {
                let data = Data(receiveScratch.prefix(received))
                processReceivedDatagram(
                    data,
                    from: endpointDescription(remoteStorage)
                )
                continue
            }

            if received == 0 {
                // A zero-length UDP datagram is legal but irrelevant here.
                continue
            }

            let errorNumber = errno
            if errorNumber == EAGAIN || errorNumber == EWOULDBLOCK {
                break
            }
            if errorNumber == EINTR {
                continue
            }

            incrementReceiveErrors()
            debugReceiveErrorsObserved += 1
            if debugReceiveErrorsObserved <= 5 || debugReceiveErrorsObserved % 100 == 0 {
                DiagnosticLog.active?.log(
                    "UDP-RX",
                    "BSD recvfrom FAILED n=\(debugReceiveErrorsObserved) errno=\(errorNumber) error=\(errorText(errorNumber))"
                )
            }
            break
        }
    }

    private func processReceivedDatagram(_ data: Data, from endpoint: String) {
        guard let packet = AudioWirePacket.decode(data) else {
            incrementBadWirePackets()
            DiagnosticLog.active?.log(
                "UDP-RX",
                "BSD BAD_WIRE from=\(endpoint) bytes=\(data.count) prefix=\(data.prefix(16).map { String(format: "%02x", $0) }.joined())"
            )
            return
        }

        incrementReceivedFrames()
        onPacket?(packet)
    }

    private func endpointDescription(_ storage: sockaddr_storage) -> String {
        guard Int32(storage.ss_family) == AF_INET else {
            return "family=\(storage.ss_family)"
        }

        var copy = storage
        return withUnsafePointer(to: &copy) { storagePointer in
            let ipv4Pointer = UnsafeRawPointer(storagePointer)
                .assumingMemoryBound(to: sockaddr_in.self)
            var address = ipv4Pointer.pointee.sin_addr
            let port = UInt16(bigEndian: ipv4Pointer.pointee.sin_port)
            var text = [CChar](
                repeating: 0,
                count: Int(INET_ADDRSTRLEN)
            )
            let converted = inet_ntop(
                AF_INET,
                &address,
                &text,
                socklen_t(INET_ADDRSTRLEN)
            )
            guard converted != nil else {
                return "?:\(port)"
            }
            return "\(String(cString: text)):\(port)"
        }
    }

    private func errorText(_ errorNumber: Int32) -> String {
        String(cString: strerror(errorNumber))
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

    enum TransportError: LocalizedError {
        case invalidPort
        case invalidHost(String)
        case socketCreate(Int32)
        case configure(Int32)
        case bind(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                return "Invalid UDP port"
            case .invalidHost(let host):
                return "Invalid J6 IPv4 address: \(host)"
            case .socketCreate(let code):
                return "UDP socket() failed: errno \(code) \(String(cString: strerror(code)))"
            case .configure(let code):
                return "UDP socket configuration failed: errno \(code) \(String(cString: strerror(code)))"
            case .bind(let code):
                return "UDP bind() failed: errno \(code) \(String(cString: strerror(code)))"
            }
        }
    }
}
