import ClashCore
import NetworkExtension
import os

private let tunAddress = "198.18.0.1"
private let tunDns = "198.18.0.2"

private final class ResultHandler: NSObject, MobileResultHandlerProtocol {
    private let block: (String) -> Void

    init(_ block: @escaping (String) -> Void) {
        self.block = block
    }

    func onResult(_ data: Data?) throws {
        block(data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }
}

/// The extension's own sockets never enter its tunnel, and iOS names no
/// process behind a flow, so every callback here is a no-op.
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

private final class MemoryMonitor {
    private let queue = DispatchQueue(label: "memory-monitor")
    private var timer: DispatchSourceTimer?
    private var stats: TunnelStats

    init(options: SpikeOptions) {
        stats = TunnelStats(
            options: options, footprintMB: 0, peakMB: 0, availableMB: 0,
            phases: [], error: nil, updatedAt: Date()
        )
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
    }

    func mark(_ phase: String) {
        queue.async {
            self.sample()
            self.stats.phases.append(PhaseSample(phase: phase, footprintMB: self.stats.footprintMB, at: Date()))
        }
    }

    func fail(_ message: String) {
        queue.async { self.stats.error = message }
    }

    func snapshot() -> Data? {
        queue.sync {
            sample()
            return try? TunnelStats.encoder.encode(stats)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func sample() {
        let footprint = Double(TunnelStats.footprint()) / megabyte
        stats.footprintMB = footprint
        stats.peakMB = max(stats.peakMB, footprint)
        stats.availableMB = Double(os_proc_available_memory()) / megabyte
        stats.updatedAt = Date()
    }
}

private final class LogBuffer {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(String(line.prefix(4000)))
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }

    func encoded() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try? JSONSerialization.data(withJSONObject: lines, options: [.prettyPrinted])
    }
}

private func invokeCore(_ method: String, _ arguments: String = "{}", reply: @escaping (String) -> Void) {
    MobileInvokeMethod(#"{"id":"spike","method":"\#(method)","arguments":\#(arguments)}"#, ResultHandler(reply))
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var monitor: MemoryMonitor?
    private let logs = LogBuffer()
    private var home: URL?

    override func startTunnel(options startOptions: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let options = (startOptions?[Spike.optionsKey] as? Data)
            .flatMap { try? JSONDecoder().decode(SpikeOptions.self, from: $0) } ?? SpikeOptions()
        let monitor = MemoryMonitor(options: options)
        self.monitor = monitor
        monitor.start()
        monitor.mark("loaded")
        if options.memoryLimitMB > 0 {
            MobileSetMemoryLimit(Int64(options.memoryLimitMB) << 20)
        }

        let finish: (String?) -> Void = { message in
            if let message {
                monitor.fail(message)
                completionHandler(NSError(domain: "FlClashSpike", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
            } else {
                monitor.mark("tun started")
                self.startLogCapture()
                completionHandler(nil)
            }
        }

        setTunnelNetworkSettings(networkSettings(mtu: options.mtu)) { error in
            if let error {
                finish("network settings: \(error.localizedDescription)")
                return
            }
            monitor.mark("settings applied")
            let home: URL
            do {
                home = try Self.prepareHome(config: options.config)
                self.home = home
            } catch {
                finish("home: \(error.localizedDescription)")
                return
            }
            let fd = flclash_utun_fd()
            guard fd >= 0 else {
                finish("no utun descriptor found")
                return
            }
            let initParams = #"{"home-dir":"\#(home.path)","version":0}"#
            let setupParams = #"{"selected-map":{},"options":{"test-url":"","skip-cert-verify":false,"delay-test-timeout":0,"mitm-capture":false}}"#
            MobileQuickSetup(initParams, setupParams, ResultHandler { message in
                guard message.isEmpty else {
                    finish("quickSetup: \(message)")
                    return
                }
                monitor.mark("config applied")
                // StartTun closes the descriptor it is handed; the original
                // belongs to NEPacketTunnelFlow.
                let started = MobileStartTun(
                    dup(fd), TunHandler(), options.stack,
                    "\(tunAddress)/30", tunDns,
                    #"{"mtu":\#(options.mtu),"congestion-controller":""}"#
                )
                finish(started ? nil : "core rejected the tun descriptor")
            })
        }
    }

    override func stopTunnel(with _: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        MobileStopTun()
        monitor?.stop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        switch messageData {
        case Spike.statsRequest: completionHandler?(monitor?.snapshot())
        case Spike.logsRequest: completionHandler?(logs.encoded())
        case Spike.diagnoseRequest: diagnose { completionHandler?($0) }
        default: completionHandler?(nil)
        }
    }

    private func startLogCapture() {
        MobileSetEventListener(ResultHandler { [logs] in logs.append($0) })
        invokeCore("config.update", #"{"log-level":"info"}"#) { [logs] in logs.append("config.update -> \($0)") }
        invokeCore("log.start") { [logs] in logs.append("log.start -> \($0)") }
    }

    /// The extension's own sockets bypass its tunnel, so a fetch through the
    /// core's mixed port tests the outbound side alone, apart from the tun.
    private func diagnose(_ reply: @escaping (Data?) -> Void) {
        let config = home.flatMap { try? String(contentsOf: $0.appendingPathComponent("config.yaml"), encoding: .utf8) } ?? ""
        let port = config.split(separator: "\n")
            .first { $0.hasPrefix("mixed-port:") }
            .flatMap { Int($0.dropFirst("mixed-port:".count).trimmingCharacters(in: .whitespaces)) } ?? 7890
        let direct = URLSessionConfiguration.ephemeral
        direct.timeoutIntervalForRequest = 8
        let proxied = URLSessionConfiguration.ephemeral
        proxied.timeoutIntervalForRequest = 8
        proxied.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        let probes: [(String, URLSessionConfiguration, String)] = [
            ("direct apple", direct, "https://www.apple.com/library/test/success.html"),
            ("mixed-port \(port) apple", proxied, "https://www.apple.com/library/test/success.html"),
            ("mixed-port \(port) gstatic", proxied, "https://www.gstatic.com/generate_204"),
            ("mixed-port \(port) google", proxied, "https://www.google.com/"),
        ]
        Task {
            var results: [String: String] = [:]
            for (name, configuration, url) in probes {
                let session = URLSession(configuration: configuration)
                let start = Date()
                do {
                    let (_, response) = try await session.data(from: URL(string: url)!)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    results[name] = "HTTP \(code) in \(Int(Date().timeIntervalSince(start) * 1000)) ms"
                } catch {
                    results[name] = "\(error.localizedDescription) (\((error as NSError).code))"
                }
                session.invalidateAndCancel()
            }
            invokeCore("connection.count") { count in
                results["connection.count"] = count
                reply(try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]))
            }
        }
    }

    /// The extension lives in the app's PlugIns directory and may read the
    /// app's bundle, so the payload is copied from there into its own sandbox.
    private static func prepareHome(config: String) throws -> URL {
        let files = FileManager.default
        let appBundle = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let payload = appBundle.appendingPathComponent("SpikeData")
        let home = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("home", isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        for name in try files.contentsOfDirectory(atPath: payload.path) {
            let target = home.appendingPathComponent(name)
            try? files.removeItem(at: target)
            try files.copyItem(at: payload.appendingPathComponent(name), to: target)
        }
        let running = home.appendingPathComponent("config.yaml")
        try? files.removeItem(at: running)
        try files.copyItem(at: home.appendingPathComponent("config-\(config).yaml"), to: running)
        return home
    }

    private func networkSettings(mtu: Int) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "254.1.1.1")
        let ipv4 = NEIPv4Settings(addresses: [tunAddress], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let dns = NEDNSSettings(servers: [tunDns])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: mtu)
        return settings
    }
}
