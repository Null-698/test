import Foundation

/// Small RTP-like jitter buffer. Packet arrival fills it; AVAudioPlayerNode is
/// the actual playback clock. It reorders by sequence, uses short PLC for loss,
/// estimates network/callback jitter from sample timestamps, and recommends a
/// tiny output-frame correction for independent-clock drift.
final class AudioJitterBuffer {
    struct Output {
        let pcm: Data
        let outputFrameAdjustment: Int
        let concealed: Bool
    }

    struct Snapshot {
        let bufferedFrames: Int
        let targetFrames: Int
        let jitterMS: Double
        let plcFrames: Int
        let lateFrames: Int
        let duplicateFrames: Int
        let latencyDrops: Int
        let clockShortens: Int
        let clockStretches: Int
        let streamResets: Int
    }

    private var sessionID: UInt32?
    private var expectedSequence: UInt32?
    private var packets: [UInt32: Data] = [:]
    private var started = false

    private var lastGoodFrame: Data?
    private var consecutiveLosses = 0

    private var lastArrivalNS: UInt64?
    private var lastTimestamp: UInt32?
    private var jitterSamples = 0.0
    private var targetFrames = 5

    private var plcFrames = 0
    private var lateFrames = 0
    private var duplicateFrames = 0
    private var latencyDrops = 0
    private var clockShortens = 0
    private var clockStretches = 0
    private var streamResets = 0

    private let minTarget = 4
    private let maxTarget = 8
    private let maxBufferedFrames = 16
    private let maxConsecutivePLC = 2

    func push(_ packet: AudioWirePacket) {
        if sessionID != packet.sessionID {
            resetForStream(
                sessionID: packet.sessionID,
                firstSequence: packet.sequence
            )
        }

        if expectedSequence == nil {
            expectedSequence = packet.sequence
        }

        guard let expectedSequence else { return }
        let distance = AudioWirePacket.signedDistance(
            packet.sequence,
            expectedSequence
        )

        if distance < 0 {
            lateFrames += 1
            return
        }

        if distance > 2_000 {
            resetForStream(
                sessionID: packet.sessionID,
                firstSequence: packet.sequence
            )
        }

        if packets[packet.sequence] != nil {
            duplicateFrames += 1
            return
        }

        updateJitter(packet)
        packets[packet.sequence] = packet.pcm

        while packets.count > maxBufferedFrames,
              let expected = self.expectedSequence {
            if packets.removeValue(forKey: expected) != nil {
                latencyDrops += 1
            }
            self.expectedSequence = expected &+ 1
        }
    }

    func pop(
        playoutQueuedFrames: Int = 0,
        allowConcealment: Bool = true
    ) -> Output? {
        if !started {
            guard packets.count >= targetFrames else { return nil }
            started = true
        }

        guard let expected = expectedSequence else { return nil }

        let pcm: Data
        let concealed: Bool

        if let frame = packets.removeValue(forKey: expected) {
            pcm = frame
            lastGoodFrame = frame
            consecutiveLosses = 0
            concealed = false
        } else {
            // Missing from the network queue does not mean lost yet. The
            // hardware player may still have tens of milliseconds queued.
            guard allowConcealment else {
                return nil
            }

            if consecutiveLosses >= maxConsecutivePLC {
                // Avoid long repeated 10 ms PLC runs, which sound buzzy.
                if !packets.isEmpty {
                    let nearest = packets.keys.min { lhs, rhs in
                        AudioWirePacket.signedDistance(lhs, expected) <
                            AudioWirePacket.signedDistance(rhs, expected)
                    }
                    if let nearest {
                        expectedSequence = nearest
                    }
                }

                started = false
                consecutiveLosses = 0
                return nil
            }

            consecutiveLosses += 1
            plcFrames += 1
            pcm = conceal(lastGoodFrame, lossRun: consecutiveLosses)
            concealed = true
        }

        expectedSequence = expected &+ 1

        // At 48 kHz playback, +/-1 output frame on a nominal 480-frame
        // buffer is only ~0.2% for this packet. It smoothly nudges independent
        // hardware clocks without dropping/repeating a whole 10 ms packet.
        let adjustment: Int
        let totalQueuedFrames = packets.count + max(0, playoutQueuedFrames)

        // Clock recovery must include frames already scheduled in the audio
        // player. Looking only at the packet dictionary made the old code
        // think it was constantly starving after pre-scheduling.
        if totalQueuedFrames > targetFrames + 1 {
            adjustment = -1
            clockShortens += 1
        } else if totalQueuedFrames < max(1, targetFrames - 1) {
            adjustment = 1
            clockStretches += 1
        } else {
            adjustment = 0
        }

        return Output(
            pcm: pcm,
            outputFrameAdjustment: adjustment,
            concealed: concealed
        )
    }

    func reset() {
        packets.removeAll(keepingCapacity: true)
        sessionID = nil
        expectedSequence = nil
        started = false
        lastGoodFrame = nil
        consecutiveLosses = 0
        lastArrivalNS = nil
        lastTimestamp = nil
        jitterSamples = 0
        targetFrames = 5

        plcFrames = 0
        lateFrames = 0
        duplicateFrames = 0
        latencyDrops = 0
        clockShortens = 0
        clockStretches = 0
        streamResets = 0
    }

    func snapshot() -> Snapshot {
        Snapshot(
            bufferedFrames: packets.count,
            targetFrames: targetFrames,
            jitterMS: jitterSamples * 1000.0 / AudioWirePacket.sampleRate,
            plcFrames: plcFrames,
            lateFrames: lateFrames,
            duplicateFrames: duplicateFrames,
            latencyDrops: latencyDrops,
            clockShortens: clockShortens,
            clockStretches: clockStretches,
            streamResets: streamResets
        )
    }

    private func resetForStream(
        sessionID: UInt32,
        firstSequence: UInt32
    ) {
        if self.sessionID != nil {
            streamResets += 1
        }

        packets.removeAll(keepingCapacity: true)
        self.sessionID = sessionID
        expectedSequence = firstSequence
        started = false
        lastGoodFrame = nil
        consecutiveLosses = 0
        lastArrivalNS = nil
        lastTimestamp = nil
        jitterSamples = 0
        targetFrames = 5
    }

    private func updateJitter(_ packet: AudioWirePacket) {
        if let lastArrivalNS,
           let lastTimestamp {
            let arrivalDeltaSamples =
                Double(packet.arrivalUptimeNS - lastArrivalNS)
                * AudioWirePacket.sampleRate
                / 1_000_000_000.0
            let timestampDelta = Double(packet.timestamp &- lastTimestamp)

            if timestampDelta >= 1, timestampDelta <= 8_000 {
                let deviation = abs(arrivalDeltaSamples - timestampDelta)
                jitterSamples += (deviation - jitterSamples) / 16.0

                targetFrames = min(
                    maxTarget,
                    max(
                        minTarget,
                        4 + Int(
                            ceil(
                                jitterSamples
                                / Double(AudioWirePacket.samplesPerPacket)
                            )
                        )
                    )
                )
            }
        }

        lastArrivalNS = packet.arrivalUptimeNS
        lastTimestamp = packet.timestamp
    }

    private func conceal(_ previous: Data?, lossRun: Int) -> Data {
        guard let previous,
              previous.count == AudioWirePacket.payloadBytes
        else {
            return Data(repeating: 0, count: AudioWirePacket.payloadBytes)
        }

        let gain = pow(0.86, Double(lossRun))
        let bytes = [UInt8](previous)
        var out = Data(count: previous.count)

        out.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index + 1 < bytes.count {
                let rawSample = UInt16(bytes[index])
                    | (UInt16(bytes[index + 1]) << 8)
                let sample = Int16(bitPattern: rawSample)
                let scaled = Int(
                    (Double(sample) * gain).rounded()
                ).clamped(to: -32768...32767)

                destination[index] = UInt8(scaled & 0xff)
                destination[index + 1] = UInt8((scaled >> 8) & 0xff)
                index += 2
            }
        }

        return out
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
