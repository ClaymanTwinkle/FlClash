import Foundation
import NetworkExtension

/// Owns the packet tunnel's VPN configuration. Start and stop are optimistic
/// like Android's service commands: each records the latest intent, and work
/// still in flight for an older one gives way.
@MainActor
final class TunnelController {
  /// The run ended without a stop request: a failed start, a revoke from
  /// Settings, another VPN taking over, or the extension dying.
  var onStopped: (() -> Void)?
  var onNotice: ((_ code: String, _ message: String) -> Void)?
  var onStatusChange: ((NEVPNStatus) -> Void)?

  private(set) var isRunRequested = false
  private var excludedNetworks: [String] = []
  private var runObserved = false
  private var manager: NETunnelProviderManager?
  private var generation = 0
  private var loading: Task<Void, Never>?
  private let connectedFlag = ConnectedFlag()

  init() {
    NotificationCenter.default.addObserver(
      forName: .NEVPNStatusDidChange, object: nil, queue: .main
    ) { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self, let connection = notification.object as? NEVPNConnection,
              connection === self.manager?.connection
        else { return }
        self.statusChanged(connection.status)
      }
    }
    loading = Task { await self.loadManager() }
  }

  /// Read from the Core channel's background queue.
  nonisolated var isConnected: Bool { connectedFlag.value }

  var session: NETunnelProviderSession? { manager?.connection as? NETunnelProviderSession }

  func connectedSince() async -> Date? {
    await loading?.value
    guard let connection = manager?.connection, connection.status == .connected else { return nil }
    return connection.connectedDate
  }

  func requestStart() {
    isRunRequested = true
    runObserved = false
    generation += 1
    let current = generation
    Task { await start(current) }
  }

  func requestStop() {
    isRunRequested = false
    generation += 1
    let current = generation
    guard let manager else { return }
    Task {
      // An on-demand connect rule would bring the tunnel straight back.
      if manager.isOnDemandEnabled {
        manager.isOnDemandEnabled = false
        try? await manager.saveToPreferences()
      }
      guard current == generation else { return }
      manager.connection.stopVPNTunnel()
    }
  }

  func setExcludedNetworks(_ networks: [String]) {
    guard networks != excludedNetworks else { return }
    excludedNetworks = networks
    guard isRunRequested, let manager, applyOnDemandRules(manager) else { return }
    Task { try? await manager.saveToPreferences() }
  }

  private func start(_ current: Int) async {
    do {
      await loading?.value
      let manager = try await configuredManager()
      var waits = 0
      while manager.connection.status == .disconnecting, waits < 50 {
        try await Task.sleep(nanoseconds: 100_000_000)
        waits += 1
      }
      guard current == generation, isRunRequested else { return }
      switch manager.connection.status {
      case .connecting, .connected, .reasserting:
        runObserved = true
      default:
        try manager.connection.startVPNTunnel()
      }
    } catch {
      guard current == generation, isRunRequested else { return }
      NSLog("FlClash: tunnel start failed: \(error.localizedDescription)")
      giveBackRun()
    }
  }

  private func loadManager() async {
    let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
    manager = managers.first {
      ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
        == AppGroup.tunnelBundleIdentifier
    }
    if let status = manager?.connection.status {
      connectedFlag.value = status == .connected || status == .reasserting
    }
  }

  private func configuredManager() async throws -> NETunnelProviderManager {
    let manager = manager ?? NETunnelProviderManager()
    let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
    var needsSave = manager.protocolConfiguration == nil || !manager.isEnabled
      || proto.providerBundleIdentifier != AppGroup.tunnelBundleIdentifier
    if needsSave {
      proto.providerBundleIdentifier = AppGroup.tunnelBundleIdentifier
      proto.serverAddress = "FlClash"
      manager.protocolConfiguration = proto
      manager.localizedDescription = "FlClash"
      manager.isEnabled = true
    }
    needsSave = applyOnDemandRules(manager) || needsSave
    if needsSave {
      try await manager.saveToPreferences()
      try await manager.loadFromPreferences()
    }
    self.manager = manager
    return manager
  }

  private func statusChanged(_ status: NEVPNStatus) {
    connectedFlag.value = status == .connected || status == .reasserting
    onStatusChange?(status)
    switch status {
    case .connecting, .connected, .reasserting:
      runObserved = runObserved || isRunRequested
    case .disconnected where isRunRequested && runObserved:
      Task { await runEnded() }
    default:
      break
    }
  }

  /// Under on-demand rules a disconnect is the system's pause; only a failure that would repeat ends the run.
  private func runEnded() async {
    let reason = Self.stopReason()
    if let manager {
      try? await manager.loadFromPreferences()
      if manager.isOnDemandEnabled {
        guard reason != nil else { return }
        manager.isOnDemandEnabled = false
        try? await manager.saveToPreferences()
      }
    }
    guard isRunRequested else { return }
    giveBackRun()
    if let (code, message) = reason {
      onNotice?(code, message)
    }
  }

  private func applyOnDemandRules(_ manager: NETunnelProviderManager) -> Bool {
    let enabled = !excludedNetworks.isEmpty
    let current = manager.onDemandRules?.compactMap { ($0 as? NEOnDemandRuleDisconnect)?.ssidMatch }.first ?? []
    guard manager.isOnDemandEnabled != enabled || current != excludedNetworks else { return false }
    if enabled {
      let pause = NEOnDemandRuleDisconnect()
      pause.interfaceTypeMatch = .wiFi
      pause.ssidMatch = excludedNetworks
      let connect = NEOnDemandRuleConnect()
      connect.interfaceTypeMatch = .any
      manager.onDemandRules = [pause, connect]
    } else {
      manager.onDemandRules = nil
    }
    manager.isOnDemandEnabled = enabled
    return true
  }

  private func giveBackRun() {
    isRunRequested = false
    onStopped?()
  }

  private static func stopReason() -> (String, String)? {
    if let message = try? String(contentsOf: AppGroup.tunnelErrorFile, encoding: .utf8) {
      try? FileManager.default.removeItem(at: AppGroup.tunnelErrorFile)
      return ("tunnel_start_failed", message)
    }
    guard let data = try? Data(contentsOf: AppGroup.tunnelMemoryFile),
          let sample = try? JSONSerialization.jsonObject(with: data) as? [String: NSNumber],
          let footprint = sample["footprint"]?.uint64Value, let available = sample["available"]?.uint64Value,
          let at = sample["at"]?.doubleValue, Date().timeIntervalSince1970 - at < 10
    else { return nil }
    // Less than a tenth of the limit left a second before it went: iOS ended it for memory.
    return available * 10 < footprint + available ? ("tunnel_memory", "") : nil
  }
}

private final class ConnectedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var connected = false

  var value: Bool {
    get { lock.withLock { connected } }
    set { lock.withLock { connected = newValue } }
  }
}
