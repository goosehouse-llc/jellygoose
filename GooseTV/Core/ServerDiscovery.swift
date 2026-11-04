import Foundation
import Darwin

/// Finds Jellyfin and Emby servers on the local network, so nobody has to type
/// an address with a remote.
///
/// Jellyfin answers "who is JellyfinServer?" sent to UDP port 7359 with a line
/// of JSON naming itself, and Emby answers "who is EmbyServer?" the same way.
/// Which of the two it is gets settled when the address is probed. What it gives as its address is whatever its network
/// settings say, which can be stale or a container's own (one real server
/// answers from 10.0.0.20 and calls itself 192.168.0.5), so the address the
/// answer came from is kept too, and the caller tries both.
enum ServerDiscovery {
    struct Reply: Hashable {
        /// The server's id, the same one /System/Info/Public gives.
        let id: String
        let name: String
        /// Where the server says it is: an address, maybe with a scheme or port.
        let advertised: String?
        /// Where the answer actually came from.
        let host: String

        /// Addresses worth trying, most likely first: the one the answer came
        /// from, on the advertised port or Jellyfin's default, then the one it
        /// advertised.
        var candidates: [URL] {
            let advertisedURL = advertised.flatMap { text -> URL? in
                let full = text.contains("://") ? text : "http://\(text)"
                guard var parts = URLComponents(string: full), parts.host != nil else { return nil }
                if parts.port == nil, parts.scheme == "http" { parts.port = 8096 }
                return parts.url
            }
            let port = advertisedURL?.port ?? 8096
            let fromHost = URL(string: "http://\(host):\(port)")
            return [fromHost, advertisedURL].compactMap { $0 }.reduce(into: []) { list, url in
                if !list.contains(url) { list.append(url) }
            }
        }
    }

    private static let port: UInt16 = 7359
    private static let questions = ["who is JellyfinServer?", "who is EmbyServer?"].map { Array($0.utf8) }

    /// Asks the network, and gathers every server that answers within `seconds`.
    static func search(seconds: Double = 3) async -> [Reply] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: broadcast(waiting: seconds))
            }
        }
    }

    /// Blocking, so run off the main thread. Sent twice, since UDP is allowed
    /// to lose the first.
    private static func broadcast(waiting seconds: Double) -> [Reply] {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socket >= 0 else { return [] }
        defer { close(socket) }

        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        // Short reads, so the loop notices the deadline.
        var wait = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr.s_addr = INADDR_BROADCAST
        func ask() {
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    for question in questions {
                        sendto(socket, question, question.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        #if os(iOS)
        // On iPhone and iPad a broadcast needs Apple's multicast entitlement,
        // and without it never leaves the device. Asking every address on the
        // local network one by one needs only the local network permission,
        // and servers answer that just the same.
        var hosts = localHosts()
        #if DEBUG
        let broadcastAllowed = ProcessInfo.processInfo.environment["GOOSETV_NO_BROADCAST"] == nil
        #else
        let broadcastAllowed = true
        #endif
        func askEach() {
            for host in hosts {
                var each = target
                each.sin_addr.s_addr = host
                withUnsafePointer(to: &each) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                        for question in questions {
                            sendto(socket, question, question.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
        if broadcastAllowed { ask() }
        askEach()
        #else
        ask()
        #endif
        var askedAgain = false
        var replies: [String: Reply] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if !askedAgain, Date().timeIntervalSince(start) > 0.5 {
                #if os(iOS)
                if broadcastAllowed { ask() }
                askEach()
                hosts = []
                #else
                ask()
                #endif
                askedAgain = true
            }
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(socket, &buffer, buffer.count, 0, address, &length)
                }
            }
            guard count > 0,
                  let answer = try? JSONDecoder().decode(Answer.self, from: Data(buffer[0..<count])),
                  let host = String(validatingCString: inet_ntoa(from.sin_addr)) else { continue }
            replies[answer.Id] = Reply(id: answer.Id, name: answer.Name ?? host,
                                       advertised: answer.Address, host: host)
        }
        return Array(replies.values).sorted { $0.name < $1.name }
    }

    #if os(iOS)
    /// Every address on the device's own IPv4 networks (Wi-Fi or Ethernet),
    /// as network-order integers, but for its own. A network bigger than a
    /// thousand addresses is narrowed to the 254 around the device.
    private static func localHosts() -> [in_addr_t] {
        var result: [in_addr_t] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = interface.ifa_netmask else { continue }
            let name = String(cString: interface.ifa_name)
            // Wi-Fi and wired; not the mobile network or a VPN's tunnel.
            guard name.hasPrefix("en") else { continue }
            let own = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            var netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ~netmask > 1024 { netmask = 0xFFFF_FF00 }
            let network = own & netmask
            let broadcastAddress = network | ~netmask
            var host = network &+ 1
            while host < broadcastAddress {
                if host != own { result.append(host.bigEndian) }
                host &+= 1
            }
        }
        return result
    }
    #endif

    /// The answer as Jellyfin spells it.
    private struct Answer: Decodable {
        let Id: String
        let Name: String?
        let Address: String?
    }
}
