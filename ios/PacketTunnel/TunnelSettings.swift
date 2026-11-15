import Foundation
import NetworkExtension

/// The Dart `VpnOptions` fields a packet tunnel honours; it has no per-app routing.
struct VpnOptions: Decodable {
  var port: Int
  var ipv6: Bool
  var dnsHijacking: Bool
  var systemProxy: Bool
  var bypassDomain: [String]
  var stack: String
  var routeAddress: [String]
  var mtu: Int
  var congestionController: String

  /// sing-box measured throughput falling off above 4096 inside an extension.
  var effectiveMtu: Int { mtu > 0 ? mtu : 4064 }
}

private struct SharedState: Decodable {
  var vpnOptions: VpnOptions?
}

enum TunnelSettings {
  private static let ipv4Address = "198.18.0.1"
  private static let ipv4Dns = "198.18.0.2"
  private static let ipv6Address = "fdfe:dcba:9876::1"
  private static let ipv6Dns = "fdfe:dcba:9876::2"

  static func isTunnelDns(_ address: String) -> Bool {
    address == ipv4Dns || address == ipv6Dns
  }

  static func loadVpnOptions() -> VpnOptions? {
    guard let data = try? Data(contentsOf: AppGroup.sharedStateFile) else { return nil }
    return (try? JSONDecoder().decode(SharedState.self, from: data))?.vpnOptions
  }

  static func network(_ options: VpnOptions) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.mtu = NSNumber(value: options.effectiveMtu)

    let ipv4 = NEIPv4Settings(addresses: [ipv4Address], subnetMasks: ["255.255.255.252"])
    let ipv4Routes = options.routeAddress.compactMap(ipv4Route)
    ipv4.includedRoutes = ipv4Routes.isEmpty ? [.default()] : ipv4Routes
    settings.ipv4Settings = ipv4

    if options.ipv6 {
      let ipv6 = NEIPv6Settings(addresses: [ipv6Address], networkPrefixLengths: [126])
      let ipv6Routes = options.routeAddress.compactMap(ipv6Route)
      ipv6.includedRoutes = ipv6Routes.isEmpty ? [.default()] : ipv6Routes
      settings.ipv6Settings = ipv6
    }

    // Without a match domain iOS keeps resolving through the network's own
    // servers, past the Core's fake-ip and DNS rules; dnsHijacking only widens
    // the hijack to queries an app aims at another server.
    let dns = NEDNSSettings(servers: options.ipv6 ? [ipv4Dns, ipv6Dns] : [ipv4Dns])
    dns.matchDomains = [""]
    settings.dnsSettings = dns

    if options.systemProxy {
      let proxy = NEProxySettings()
      proxy.httpEnabled = true
      proxy.httpServer = NEProxyServer(address: "127.0.0.1", port: options.port)
      proxy.httpsEnabled = true
      proxy.httpsServer = NEProxyServer(address: "127.0.0.1", port: options.port)
      proxy.exceptionList = options.bypassDomain
      settings.proxySettings = proxy
    }
    return settings
  }

  static func tunAddress(_ options: VpnOptions) -> String {
    options.ipv6 ? "\(ipv4Address)/30,\(ipv6Address)/126" : "\(ipv4Address)/30"
  }

  static func tunDns(_ options: VpnOptions) -> String {
    if options.dnsHijacking {
      return "0.0.0.0"
    }
    return options.ipv6 ? "\(ipv4Dns),\(ipv6Dns)" : ipv4Dns
  }

  static func tunOptions(_ options: VpnOptions) -> String {
    let object: [String: Any] = [
      "mtu": options.effectiveMtu,
      "congestion-controller": options.congestionController,
    ]
    let data = try? JSONSerialization.data(withJSONObject: object)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }

  private static func ipv4Route(_ cidr: String) -> NEIPv4Route? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, parts[0].contains("."), let prefix = UInt32(parts[1]), prefix <= 32 else {
      return nil
    }
    let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    let subnet = [24, 16, 8, 0].map { String((mask >> UInt32($0)) & 0xff) }.joined(separator: ".")
    return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: subnet)
  }

  private static func ipv6Route(_ cidr: String) -> NEIPv6Route? {
    let parts = cidr.split(separator: "/")
    guard parts.count == 2, parts[0].contains(":"), let prefix = Int(parts[1]), prefix <= 128 else {
      return nil
    }
    return NEIPv6Route(destinationAddress: String(parts[0]), networkPrefixLength: NSNumber(value: prefix))
  }
}
