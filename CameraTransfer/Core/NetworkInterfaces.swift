import Foundation
import Network

/// An IPv4 address of one of the phone's network interfaces.
struct LocalAddress: Identifiable, Hashable, Sendable {
    let interface: String
    let address: String

    var id: String { interface + "|" + address }

    var friendlyName: String {
        if interface == "en0" { return "Wi-Fi" }
        if interface.hasPrefix("bridge") { return "Personal Hotspot" }
        if interface.hasPrefix("en") { return "Ethernet / Wi-Fi (\(interface))" }
        return interface
    }
}

enum NetworkInterfaces {

    /// Lists the phone's current IPv4 addresses, preferring en0 (Wi-Fi) then bridge100 (Personal Hotspot).
    /// Loopback, cellular and VPN/tunnel interfaces are skipped because a camera cannot reach them.
    static func ipv4Addresses() -> [LocalAddress] {
        var result: [LocalAddress] = []
        var listHead: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&listHead) == 0, let first = listHead else {
            return []
        }
        defer { freeifaddrs(listHead) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            cursor = entry.ifa_next

            guard let socketAddress = entry.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let flags = entry.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_LOOPBACK)) == 0 else {
                continue
            }
            let name = String(cString: entry.ifa_name)
            if isIgnoredInterface(name) { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(socketAddress,
                                     socklen_t(socketAddress.pointee.sa_len),
                                     &hostBuffer,
                                     socklen_t(hostBuffer.count),
                                     nil,
                                     0,
                                     NI_NUMERICHOST)
            guard status == 0 else { continue }
            let address = hostBuffer.withUnsafeBufferPointer { buffer -> String in
                guard let base = buffer.baseAddress else { return "" }
                return String(cString: base)
            }
            guard !address.isEmpty, !address.hasPrefix("169.254.") else { continue }
            let item = LocalAddress(interface: name, address: address)
            if !result.contains(item) {
                result.append(item)
            }
        }
        return result.sorted { lhs, rhs in
            let l = rank(lhs.interface)
            let r = rank(rhs.interface)
            if l != r { return l < r }
            return lhs.interface < rhs.interface
        }
    }

    static func preferredIPv4() -> String? {
        ipv4Addresses().first?.address
    }

    /// Converts an endpoint host (as seen on an accepted connection) to dotted IPv4, if it is one.
    static func ipv4String(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 4 else { return nil }
            return bytes.map { String($0) }.joined(separator: ".")
        case .ipv6(let address):
            // IPv4-mapped IPv6 (::ffff:a.b.c.d)
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16,
                  bytes[0..<10].allSatisfy({ $0 == 0 }),
                  bytes[10] == 0xFF, bytes[11] == 0xFF else {
                return nil
            }
            return bytes[12..<16].map { String($0) }.joined(separator: ".")
        case .name(let name, _):
            let bare = name.split(separator: "%").first.map(String.init) ?? name
            return IPv4Address(bare) != nil ? bare : nil
        @unknown default:
            return nil
        }
    }

    /// A comparable string form of an endpoint host, without any "%interface" scope suffix.
    static func hostKey(_ host: NWEndpoint.Host) -> String {
        if let v4 = ipv4String(from: host) { return v4 }
        let text = "\(host)"
        return text.split(separator: "%").first.map(String.init) ?? text
    }

    private static func isIgnoredInterface(_ name: String) -> Bool {
        let ignoredPrefixes = ["pdp_ip", "utun", "ipsec", "awdl", "llw", "lo", "gif", "stf", "XHC", "ap"]
        return ignoredPrefixes.contains { name.hasPrefix($0) }
    }

    private static func rank(_ interface: String) -> Int {
        if interface == "en0" { return 0 }
        if interface == "bridge100" { return 1 }
        if interface.hasPrefix("bridge") { return 2 }
        if interface.hasPrefix("en") { return 3 }
        return 4
    }
}
