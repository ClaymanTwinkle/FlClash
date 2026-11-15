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
  var onStatusChange: ((NEVPNStatus) -> Void)?

  private(set) var isRunRequested = false
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
    manager?.connection.stopVPNTunnel()
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
    let needsSave = manager.protocolConfiguration == nil || !manager.isEnabled
      || proto.providerBundleIdentifier != AppGroup.tunnelBundleIdentifier
    if needsSave {
      proto.providerBundleIdentifier = AppGroup.tunnelBundleIdentifier
      proto.serverAddress = "FlClash"
      manager.protocolConfiguration = proto
      manager.localizedDescription = "FlClash"
      manager.isEnabled = true
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
      giveBackRun()
    default:
      break
    }
  }

  private func giveBackRun() {
    isRunRequested = false
    onStopped?()
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
