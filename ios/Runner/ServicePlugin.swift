import ClashCore
import Flutter
import NetworkExtension

/// The iOS side of `lib/plugins/service.dart`, the same channel contract as
/// Android's ServicePlugin. The app's own Core is loaded in process; the packet
/// tunnel's Core is reached through the router while the tunnel runs.
final class ServicePlugin: NSObject, FlutterPlugin {
  private static let serviceChannelName = "com.follow.clash/service"
  private static let coreChannelName = "com.follow.clash/core"

  private let channel: FlutterMethodChannel
  private let tunnel: TunnelController
  private let router: CoreRouter
  private var commandRevision = 0
  private var attached = false
  private var pullTimer: Timer?
  private var pulling = false

  @MainActor
  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    tunnel = TunnelController()
    router = CoreRouter(tunnel: tunnel)
    super.init()
    tunnel.onStopped = { [weak self] in self?.notifyStopped() }
    tunnel.onNotice = { [channel] code, message in
      channel.invokeMethod("notice", arguments: ["code": code, "message": message])
    }
    tunnel.onStatusChange = { [weak self] _ in self?.updatePulling() }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    MobileSetCacheFile(AppGroup.processCacheFile)
    let messenger = registrar.messenger()
    let channel = FlutterMethodChannel(name: serviceChannelName, binaryMessenger: messenger)
    let plugin = MainActor.assumeIsolated { ServicePlugin(channel: channel) }
    registrar.addMethodCallDelegate(plugin, channel: channel)
    let coreChannel = FlutterMethodChannel(
      name: coreChannelName,
      binaryMessenger: messenger,
      codec: FlutterStandardMethodCodec.sharedInstance(),
      taskQueue: messenger.makeBackgroundTaskQueue?()
    )
    coreChannel.setMethodCallHandler { [weak plugin] call, result in
      plugin?.handleCore(call, result: result)
    }
    registrar.publish(plugin)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    MainActor.assumeIsolated {
      switch call.method {
      case "init":
        attached = true
        MobileSetEventListener(ResultHandler { [weak self] in self?.sendEvent($0) })
        updatePulling()
        result("")
      case "shutdown":
        attached = false
        MobileSetEventListener(nil)
        updatePulling()
        result(true)
      case "syncState":
        result(syncState(call.arguments as? String))
      case "start":
        commandRevision = call.arguments as? Int ?? commandRevision
        tunnel.requestStart()
        result(true)
      case "stop":
        commandRevision = call.arguments as? Int ?? commandRevision
        tunnel.requestStop()
        result(true)
      case "getRunTime":
        Task {
          let since = await tunnel.connectedSince()
          result(since.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func handleCore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "invokeMethod" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let data = call.arguments as? String else {
      result(FlutterError(code: "INVALID_ARGUMENT", message: "Method call payload must be a string", details: nil))
      return
    }
    router.invoke(data) { response in
      result(FlutterStandardTypedData(bytes: response))
    }
  }

  /// Setup params carry the profile overlay and arrive only with a config push;
  /// the routine syncs leave them out and must not erase the last ones.
  @MainActor
  private func syncState(_ json: String?) -> String {
    guard let json, let data = json.data(using: .utf8),
          var state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return "Invalid shared state"
    }
    do {
      tunnel.setExcludedNetworks(state["excludeSSIDs"] as? [String] ?? [])
      if let setupParams = state.removeValue(forKey: "setupParams") {
        try JSONSerialization.data(withJSONObject: setupParams).write(to: AppGroup.setupParamsFile, options: .atomic)
      }
      try JSONSerialization.data(withJSONObject: state).write(to: AppGroup.sharedStateFile, options: .atomic)
      return ""
    } catch {
      return error.localizedDescription
    }
  }

  @MainActor
  private func notifyStopped() {
    channel.invokeMethod("stopped", arguments: commandRevision)
  }

  private func sendEvent(_ batch: Data) {
    DispatchQueue.main.async { [channel] in
      channel.invokeMethod("event", arguments: FlutterStandardTypedData(bytes: batch))
    }
  }

  /// The tunnel's events are pulled while Flutter listens and the tunnel runs.
  @MainActor
  private func updatePulling() {
    let wanted = attached && tunnel.isConnected
    if wanted, pullTimer == nil {
      pullTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.pullEvents() }
      }
    } else if !wanted {
      pullTimer?.invalidate()
      pullTimer = nil
    }
  }

  @MainActor
  private func pullEvents() {
    guard !pulling, let session = tunnel.session else { return }
    pulling = true
    do {
      try session.sendProviderMessage(TunnelMessage.pullEvents.encode()) { [weak self] data in
        DispatchQueue.main.async { self?.pulling = false }
        for batch in EventFrames.decode(data ?? Data()) {
          self?.sendEvent(batch)
        }
      }
    } catch {
      pulling = false
    }
  }
}
