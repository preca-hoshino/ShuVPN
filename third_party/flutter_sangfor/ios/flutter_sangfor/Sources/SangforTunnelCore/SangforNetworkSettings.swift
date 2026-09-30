import Foundation
import NetworkExtension

/// Pure parsing helpers for IPv4 network settings. Kept free of any
/// NetworkExtension state so they stay trivially unit-testable.
public enum SangforIPv4 {
  /// A parsed CIDR route.
  public struct Route: Equatable {
    public let destinationAddress: String
    public let prefixLength: Int

    public init(destinationAddress: String, prefixLength: Int) {
      self.destinationAddress = destinationAddress
      self.prefixLength = prefixLength
    }
  }

  /// Converts a CIDR prefix length (0...32) into a dotted-decimal subnet
  /// mask. Returns `nil` for out-of-range prefixes.
  public static func mask(forPrefixLength prefix: Int) -> String? {
    guard (0...32).contains(prefix) else { return nil }
    if prefix == 0 { return "0.0.0.0" }
    let mask = prefix >= 32
      ? 0xffffffff
      : (0xffffffff << UInt32(32 - prefix)) & 0xffffffff
    return [
      (mask >> 24) & 0xff,
      (mask >> 16) & 0xff,
      (mask >> 8) & 0xff,
      mask & 0xff,
    ].map(String.init).joined(separator: ".")
  }

  /// Parses a CIDR string (`10.0.0.0/8`). A bare IP address is treated as
  /// a `/32`. Returns `nil` for anything malformed — callers must skip the
  /// route (fail closed), never fall back to a default route.
  public static func parseRoute(_ route: String) -> Route? {
    let trimmed = route.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    let address: String
    let prefix: Int
    switch parts.count {
    case 1:
      address = String(parts[0])
      prefix = 32
    case 2:
      address = String(parts[0])
      guard
        let parsed = Int(parts[1]),
        (0...32).contains(parsed)
      else {
        return nil
      }
      prefix = parsed
    default:
      return nil
    }
    guard isValidIPv4Address(address) else { return nil }
    return Route(destinationAddress: address, prefixLength: prefix)
  }

  /// Parses and validates a list of CIDR routes, returning the valid ones.
  /// Invalid entries are reported through [invalid] for logging.
  public static func parseRoutes(
    _ routes: [String],
    invalid: ((String) -> Void)? = nil
  ) -> [Route] {
    routes.compactMap { route in
      guard let parsed = parseRoute(route) else {
        invalid?(route)
        return nil
      }
      return parsed
    }
  }

  /// Minimal dotted-quad IPv4 validation (each octet 0...255, no leading
  /// `+`/`-`, no empty octets).
  public static func isValidIPv4Address(_ address: String) -> Bool {
    let octets = address.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4 else { return false }
    for octet in octets {
      guard !octet.isEmpty, octet.count <= 3 else { return false }
      guard octet.allSatisfy(\.isNumber) else { return false }
      guard let value = Int(octet), (0...255).contains(value) else { return false }
    }
    return true
  }

  /// Returns the IP version nibble of a raw packet (4 or 6), or `nil` when
  /// the packet is too short to tell.
  public static func packetFamily(_ packet: Data) -> Int? {
    guard let first = packet.first else { return nil }
    return Int(first >> 4)
  }
}
