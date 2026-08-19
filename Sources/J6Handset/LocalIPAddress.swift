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
        var fallback: String?

        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }

            guard let addressPointer = current.pointee.ifa_addr else {
                continue
            }

            guard addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let name = String(cString: current.pointee.ifa_name)
            if name == "lo0" {
                continue
            }

            let address: String? = addressPointer.withMemoryRebound(
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

            guard let address else {
                continue
            }

            // Wi-Fi on iOS is normally en0. Prefer it, but keep a
            // non-loopback IPv4 fallback for unusual interface layouts.
            if name == "en0" {
                return address
            }

            if fallback == nil {
                fallback = address
            }
        }

        return fallback
    }
}
