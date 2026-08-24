import Darwin
import Foundation

enum LocalIPAddress {
    static func currentIPv4() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let addressPointer = current.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  String(cString: current.pointee.ifa_name) == "en0"
            else {
                continue
            }

            return addressPointer.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1
            ) { sinPointer in
                var inAddress = sinPointer.pointee.sin_addr
                var buffer = [CChar](
                    repeating: 0,
                    count: Int(INET_ADDRSTRLEN)
                )

                guard inet_ntop(
                    AF_INET,
                    &inAddress,
                    &buffer,
                    socklen_t(INET_ADDRSTRLEN)
                ) != nil else {
                    return nil
                }

                return String(cString: buffer)
            }
        }

        // Cellular/VPN addresses are deliberately not valid AUDIO_PEER
        // endpoints. When Wi-Fi is absent, wait until en0 returns (home WLAN
        // or the J6 hotspot) and BLE will re-advertise that address.
        return nil
    }
}
