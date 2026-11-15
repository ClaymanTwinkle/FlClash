import ClashCore
import Foundation

/// Sends each Core call to the app's own Core or, while the tunnel runs, to the
/// packet tunnel's. The app's Core answers whatever needs no running state, and
/// keeps the config and selections it would need again once the tunnel stops.
final class CoreRouter {
  private enum Target {
    case app
    case tunnel
    case both
  }

  private static let appOnly: Set<String> = [
    "core.init", "core.initialized", "config.validate", "config.decrypt", "config.read",
    "profile.base", "profile.outbounds", "profile.build", "profile.clearEffect",
    "proxy.validate", "proxy.convert", "shareLink.encode", "shareLink.decode",
    "filter.validate", "ruleSet.dump", "ruleSet.compile", "geo.update",
    "mitm.certificate", "mitm.generateCertificate", "mitm.validate", "mitm.issueCertificate",
    "mitm.runScript",
  ]

  private static let both: Set<String> = ["config.setup", "config.update", "proxy.select"]

  private let tunnel: TunnelController

  init(tunnel: TunnelController) {
    self.tunnel = tunnel
  }

  func invoke(_ call: String, reply: @escaping (Data) -> Void) {
    switch target(of: call) {
    case .app:
      invokeApp(call, reply: reply)
    case .tunnel:
      invokeTunnel(call, reply: reply)
    case .both:
      invokeApp(call) { [weak self] appResponse in
        guard let self, Self.succeeded(appResponse) else {
          reply(appResponse)
          return
        }
        self.invokeTunnel(call, reply: reply)
      }
    }
  }

  private func target(of call: String) -> Target {
    guard tunnel.isConnected else { return .app }
    let method = Self.method(of: call) ?? ""
    if Self.appOnly.contains(method) {
      return .app
    }
    return Self.both.contains(method) ? .both : .tunnel
  }

  private func invokeApp(_ call: String, reply: @escaping (Data) -> Void) {
    MobileInvokeMethod(call, ResultHandler(reply))
  }

  private func invokeTunnel(_ call: String, reply: @escaping (Data) -> Void) {
    Task { @MainActor in
      guard let session = tunnel.session else {
        reply(Self.unavailable(call))
        return
      }
      do {
        try session.sendProviderMessage(TunnelMessage.invoke.encode(Data(call.utf8))) { response in
          reply(response ?? Self.unavailable(call))
        }
      } catch {
        reply(Self.unavailable(call))
      }
    }
  }

  private static func method(of call: String) -> String? {
    let object = try? JSONSerialization.jsonObject(with: Data(call.utf8)) as? [String: Any]
    return object?["method"] as? String
  }

  private static func succeeded(_ response: Data) -> Bool {
    let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
    return object?["error"] == nil || object?["error"] is NSNull
  }

  /// The shape the Go Core answers with, so Dart reads it as an unanswered call.
  private static func unavailable(_ call: String) -> Data {
    let id = (try? JSONSerialization.jsonObject(with: Data(call.utf8)) as? [String: Any])?["id"]
    let response: [String: Any] = [
      "id": id ?? NSNull(),
      "result": NSNull(),
      "error": ["code": "core_unavailable", "message": "The packet tunnel did not answer", "details": NSNull()],
    ]
    return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
  }
}

final class ResultHandler: NSObject, MobileResultHandlerProtocol {
  private let block: (Data) -> Void

  init(_ block: @escaping (Data) -> Void) {
    self.block = block
  }

  func onResult(_ data: Data?) throws {
    block(data ?? Data())
  }
}
