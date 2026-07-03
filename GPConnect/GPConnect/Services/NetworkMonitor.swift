import Darwin
import Foundation

func activeUtunInterfacesWithIPv4() -> Set<String> {
    var result: Set<String> = []
    var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return result }
    defer { freeifaddrs(ifaddrPtr) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let p = ptr {
        let name = String(cString: p.pointee.ifa_name)
        if name.hasPrefix("utun"),
           let addr = p.pointee.ifa_addr,
           addr.pointee.sa_family == sa_family_t(AF_INET),
           (Int32(p.pointee.ifa_flags) & IFF_UP) != 0 {
            result.insert(name)
        }
        ptr = p.pointee.ifa_next
    }
    return result
}
