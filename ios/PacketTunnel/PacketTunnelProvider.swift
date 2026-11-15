import ClashCore
import NetworkExtension
import os

private let log = Logger(subsystem: "FlClash", category: "PacketTunnel")

/// Go's collector gets this ceiling below the extension's 50 MB jetsam limit;
/// measured on device, a config of 1000 nodes and 30k rules peaks under it.
private let goMemoryLimit: Int64 = 30 << 20

private final class ResultHandler: NSObject, MobileResultHandlerProtocol {
  private let block: (Data) -> Void

  init(_ block: @escaping (Data) -> Void) {
    self.block = block
  }

  func onResult(_ data: Data?) throws {
    block(data ?? Data())
  }
}

/// A packet tunnel's own sockets never enter its tunnel, and iOS names no
/// process behind a flow, so there is nothing to protect or resolve.
private final class TunHandler: NSObject, MobileTunHandlerProtocol {
  func protect(_ fd: Int32, ret0_: UnsafeMutablePointer<ObjCBool>?) throws {
    ret0_?.pointee = true
  }

  func resolvePackage(_ uid: Int32, error _: NSErrorPointer) -> String {
    ""
  }

  func resolveUid(_ protocol: Int32, source: String?, target: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
    ret0_?.pointee = -1
  }
}

/// Holds the Core's event batches until the app pulls them. The Core listens
/// only while the app keeps pulling, so a suspended app costs no encoding. Go
/// calls `append` under its listener lock, so the listener is only ever
/// swapped outside this one.
private final class EventBuffer {
  private let lock = NSLock()
  private var batches: [Data] = []
  private var size = 0
  private var listening = false
  private var lastPull = Date.distantPast
  private let byteLimit = 1 << 20

  func pull() -> Data {
    lock.lock()
    lastPull = Date()
    let attach = !listening
    listening = true
    let drained = batches
    batches.removeAll()
    size = 0
    lock.unlock()
    if attach {
      MobileSetEventListener(ResultHandler { [weak self] in self?.append($0) })
    }
    return EventFrames.encode(drained)
  }

  func stopIfIdle() {
    lock.lock()
    let idle = listening && Date().timeIntervalSince(lastPull) > 3
    lock.unlock()
    if idle {
      stop()
    }
  }

  func stop() {
    lock.lock()
    listening = false
    batches.removeAll()
    size = 0
    lock.unlock()
    MobileSetEventListener(nil)
  }

  private func append(_ batch: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard listening else { return }
    batches.append(batch)
    size += batch.count
    while size > byteLimit, let oldest = batches.first {
      size -= oldest.count
      batches.removeFirst()
    }
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let events = EventBuffer()
  private var idleTimer: DispatchSourceTimer?
  private var memoryPressure: DispatchSourceMemoryPressure?

  override func startTunnel(options _: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    MobileSetMemoryLimit(goMemoryLimit)
    MobileMarkPacketTunnel()
    MobileSetCacheFile(AppGroup.processCacheFile)
    watchMemoryPressure()
    guard let options = TunnelSettings.loadVpnOptions() else {
      completionHandler(TunnelError.missingState("vpn options"))
      return
    }
    guard let setupParams = try? String(contentsOf: AppGroup.setupParamsFile, encoding: .utf8) else {
      completionHandler(TunnelError.missingState("setup params"))
      return
    }
    // Read before the tunnel's own DNS replaces them, as Android's NetworkObserver hands them over.
    MobileUpdateDns(Self.networkDns())
    setTunnelNetworkSettings(TunnelSettings.network(options)) { error in
      if let error {
        completionHandler(error)
        return
      }
      let fd = flclash_utun_fd()
      guard fd >= 0 else {
        completionHandler(TunnelError.noTunDescriptor)
        return
      }
      let initParams = Self.json(["home-dir": AppGroup.container.path, "version": 0])
      MobileQuickSetup(initParams, setupParams, ResultHandler { data in
        let message = String(data: data, encoding: .utf8) ?? ""
        guard message.isEmpty else {
          log.error("quickSetup failed: \(message, privacy: .public)")
          completionHandler(TunnelError.core(message))
          return
        }
        // The Core closes the descriptor it takes; this one is NEPacketTunnelFlow's.
        let started = MobileStartTun(
          dup(fd), TunHandler(), options.stack,
          TunnelSettings.tunAddress(options), TunnelSettings.tunDns(options),
          TunnelSettings.tunOptions(options)
        )
        if started {
          self.startIdleTimer()
        }
        completionHandler(started ? nil : TunnelError.core("the Core rejected the tun descriptor"))
      })
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    log.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
    idleTimer?.cancel()
    events.stop()
    MobileStopTun()
    completionHandler()
  }

  override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
    guard let completionHandler, let (kind, payload) = TunnelMessage.decode(messageData) else {
      completionHandler?(nil)
      return
    }
    switch kind {
    case .invoke:
      MobileInvokeMethod(String(data: payload, encoding: .utf8), ResultHandler(completionHandler))
    case .pullEvents:
      completionHandler(events.pull())
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    MobileForceGC()
    completionHandler()
  }

  private func startIdleTimer() {
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + 3, repeating: 3)
    timer.setEventHandler { [events] in events.stopIfIdle() }
    timer.resume()
    idleTimer = timer
  }

  private func watchMemoryPressure() {
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
    source.setEventHandler { MobileForceGC() }
    source.resume()
    memoryPressure = source
  }

  private static func networkDns() -> String {
    var buffer = [CChar](repeating: 0, count: 512)
    guard flclash_system_dns(&buffer, buffer.count) > 0 else { return "" }
    return String(cString: buffer).split(separator: ",").map(String.init)
      .filter { !TunnelSettings.isTunnelDns($0) }
      .joined(separator: ",")
  }

  private static func json(_ object: [String: Any]) -> String {
    let data = try? JSONSerialization.data(withJSONObject: object)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }
}

enum TunnelError: LocalizedError {
  case missingState(String)
  case noTunDescriptor
  case core(String)

  var errorDescription: String? {
    switch self {
    case let .missingState(what): "The app has not handed over its \(what) yet"
    case .noTunDescriptor: "No utun descriptor was found"
    case let .core(message): message
    }
  }
}
