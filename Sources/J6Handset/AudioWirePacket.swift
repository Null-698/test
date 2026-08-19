import Foundation

struct AudioWirePacket: Sendable {
    static let headerBytes = 16
    static let payloadBytes = 160
    static let packetBytes = headerBytes + payloadBytes
    static let samplesPerPacket: UInt32 = 80
    static let sampleRate = 8_000.0

    let sessionID: UInt32
    let sequence: UInt32
    let timestamp: UInt32
    let pcm: Data
    let arrivalUptimeNS: UInt64

    func encoded() -> Data {
        precondition(pcm.count == Self.payloadBytes)

        var out = Data(capacity: Self.packetBytes)
        out.append(0x4A) // J
        out.append(0x36) // 6
        out.append(0x01) // version
        out.append(0x01) // PCM16LE mono 8 kHz
        Self.appendU32(sessionID, to: &out)
        Self.appendU32(sequence, to: &out)
        Self.appendU32(timestamp, to: &out)
        out.append(pcm)
        return out
    }

    static func decode(_ data: Data) -> AudioWirePacket? {
        guard data.count == packetBytes else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x4A,
              bytes[1] == 0x36,
              bytes[2] == 0x01,
              bytes[3] == 0x01
        else {
            return nil
        }

        return AudioWirePacket(
            sessionID: readU32(bytes, 4),
            sequence: readU32(bytes, 8),
            timestamp: readU32(bytes, 12),
            pcm: data.subdata(
                in: headerBytes..<(headerBytes + payloadBytes)
            ),
            arrivalUptimeNS: DispatchTime.now().uptimeNanoseconds
        )
    }

    static func signedDistance(_ a: UInt32, _ b: UInt32) -> Int64 {
        Int64(Int32(bitPattern: a &- b))
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
