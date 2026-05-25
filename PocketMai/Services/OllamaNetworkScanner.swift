import Darwin
import Foundation

struct OllamaScanResult: Identifiable, Hashable, Sendable {
  let host: String
  let port: Int

  var id: String { url }
  var url: String { "http://\(host):\(port)/v1" }
}

enum OllamaNetworkScanError: LocalizedError {
  case invalidRange(String)
  case emptyRange

  var errorDescription: String? {
    switch self {
    case .invalidRange(let value):
      return "Invalid range: \(value). Use a range like 192.168.1.x."
    case .emptyRange:
      return "Enter a local network range to scan."
    }
  }
}

enum OllamaNetworkScanner {
  static let defaultPort = 11434

  static func defaultRange() -> String {
    let interfaces = localIPv4Interfaces()
    let wifiAddress = interfaces.first { $0.name == "en0" && isPrivateIPv4($0.address) }?
      .address
    if let address = wifiAddress {
      return wildcardRange(for: address) ?? "192.168.1.x"
    }
    if let address = interfaces.first(where: { isPrivateIPv4($0.address) })?.address {
      return wildcardRange(for: address) ?? "192.168.1.x"
    }
    if let address = interfaces.first?.address {
      return wildcardRange(for: address) ?? "192.168.1.x"
    }
    return "192.168.1.x"
  }

  static func hosts(in rangeText: String) throws -> [String] {
    let trimmed = rangeText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw OllamaNetworkScanError.emptyRange }

    let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4 else { throw OllamaNetworkScanError.invalidRange(trimmed) }
    let prefixParts = try parts.prefix(3).map { part in
      guard let value = Int(part), (0...255).contains(value) else {
        throw OllamaNetworkScanError.invalidRange(trimmed)
      }
      return String(value)
    }
    let prefix = prefixParts.joined(separator: ".")
    let hostPart = parts[3].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let hostNumbers: [Int]
    if hostPart == "x" || hostPart == "*" {
      hostNumbers = Array(1...254)
    } else if hostPart.contains("-") {
      let bounds = hostPart.split(separator: "-", omittingEmptySubsequences: false)
      guard bounds.count == 2,
        let lower = Int(bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)),
        let upper = Int(bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)),
        (0...255).contains(lower),
        (0...255).contains(upper),
        lower <= upper
      else {
        throw OllamaNetworkScanError.invalidRange(trimmed)
      }
      hostNumbers = Array(lower...upper)
    } else if let host = Int(hostPart), (0...255).contains(host) {
      hostNumbers = [host]
    } else {
      throw OllamaNetworkScanError.invalidRange(trimmed)
    }

    return hostNumbers.map { "\(prefix).\($0)" }
  }

  static func isLikelyLocalOllamaBaseURL(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "http",
      components.path == "/v1",
      components.port == defaultPort,
      let host = components.host?.lowercased()
    else {
      return false
    }
    return host == "localhost" || host == "127.0.0.1" || isPrivateIPv4(host)
  }

  static func scan(
    rangeText: String,
    port: Int,
    onFound: (@MainActor @Sendable (OllamaScanResult) -> Void)? = nil
  ) async throws -> [OllamaScanResult] {
    let hosts = try hosts(in: rangeText)
    return await scan(hosts: hosts, port: port, onFound: onFound)
  }

  private static func scan(
    hosts: [String],
    port: Int,
    onFound: (@MainActor @Sendable (OllamaScanResult) -> Void)?
  ) async -> [OllamaScanResult] {
    let maxConcurrentProbes = 32
    var found: [OllamaScanResult] = []
    var nextIndex = 0

    await withTaskGroup(of: OllamaScanResult?.self) { group in
      let initialCount = min(maxConcurrentProbes, hosts.count)
      for _ in 0..<initialCount {
        let host = hosts[nextIndex]
        nextIndex += 1
        group.addTask {
          await probe(host: host, port: port)
        }
      }

      while let result = await group.next() {
        if Task.isCancelled {
          group.cancelAll()
          break
        }
        if let result {
          found.append(result)
          if let onFound {
            await onFound(result)
          }
        }
        if nextIndex < hosts.count {
          let host = hosts[nextIndex]
          nextIndex += 1
          group.addTask {
            await probe(host: host, port: port)
          }
        }
      }
    }

    return sortedResults(found)
  }

  private static func probe(host: String, port: Int) async -> OllamaScanResult? {
    guard let url = URL(string: "http://\(host):\(port)/v1/models") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 0.8
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        return nil
      }
      return OllamaScanResult(host: host, port: port)
    } catch {
      return nil
    }
  }

  private struct LocalIPv4Interface {
    var name: String
    var address: String
  }

  private static func localIPv4Interfaces() -> [LocalIPv4Interface] {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }

    var results: [LocalIPv4Interface] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = cursor {
      defer { cursor = interface.pointee.ifa_next }
      let flags = Int32(interface.pointee.ifa_flags)
      guard (flags & IFF_UP) != 0,
        (flags & IFF_LOOPBACK) == 0,
        let address = interface.pointee.ifa_addr,
        address.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }

      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let status = getnameinfo(
        address,
        socklen_t(address.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard status == 0 else { continue }
      results.append(
        LocalIPv4Interface(
          name: String(cString: interface.pointee.ifa_name),
          address: string(fromNullTerminated: hostname)
        )
      )
    }
    return results
  }

  private static func string(fromNullTerminated buffer: [CChar]) -> String {
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private static func wildcardRange(for address: String) -> String? {
    let parts = address.split(separator: ".").map(String.init)
    guard parts.count == 4 else { return nil }
    return parts.prefix(3).joined(separator: ".") + ".x"
  }

  private static func isPrivateIPv4(_ address: String) -> Bool {
    let octets = address.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4 else { return false }
    switch (octets[0], octets[1]) {
    case (10, _):
      return true
    case (172, 16...31):
      return true
    case (192, 168):
      return true
    default:
      return false
    }
  }

  private static func sortedResults(_ results: [OllamaScanResult]) -> [OllamaScanResult] {
    results.sorted { lhs, rhs in
      ipv4SortKey(lhs.host) < ipv4SortKey(rhs.host)
    }
  }

  private static func ipv4SortKey(_ address: String) -> UInt32 {
    let octets = address.split(separator: ".").compactMap { UInt32($0) }
    guard octets.count == 4 else { return 0 }
    return (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
  }
}
