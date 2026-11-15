import NetworkExtension
import SwiftUI

@main
struct FlClashSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@MainActor
final class TunnelModel: ObservableObject {
    @Published var status: NEVPNStatus = .invalid
    @Published var stats: TunnelStats?
    @Published var options = SpikeOptions()
    @Published var message = ""
    @Published var stressRunning = false
    @Published var stressSummary = ""

    private var manager: NETunnelProviderManager?
    private var poll: Timer?

    init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.status = self?.manager?.connection.status ?? .invalid }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestStats() }
        }
        Task { await loadManager() }
    }

    func start() async {
        do {
            let manager = try await configuredManager()
            let encoded = try JSONEncoder().encode(options) as NSData
            try manager.connection.startVPNTunnel(options: [Spike.optionsKey: encoded])
            message = ""
        } catch {
            message = error.localizedDescription
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    func stress() async {
        stressRunning = true
        defer { stressRunning = false }
        let result = await runLoad(seconds: 30)
        stressSummary = result.summary
    }

    /// Every stack × config pair under a 30 MB Go limit, one run each, so
    /// the whole comparison needs a single tap.
    func runMatrix() async {
        stressRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            stressRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        var rows: [MatrixRow] = []
        let configs = ["small", "small-mrs", "large", "large-mrs", "xlarge", "xlarge-mrs"]
        for config in configs {
            for stack in ["system", "mips"] {
                stressSummary = "自动测试 \(rows.count + 1)/\(configs.count * 2)：\(config) / \(stack)"
                stop()
                await waitForStatus(timeout: 15) { $0 == .disconnected || $0 == .invalid }
                stats = nil
                options = SpikeOptions(stack: stack, memoryLimitMB: 30, mtu: 1500, config: config)
                await start()
                let connected = await waitForStatus(timeout: 90) { $0 == .connected }
                var row = MatrixRow(config: config, stack: stack, connected: connected)
                if connected {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    row.startupPeakMB = stats?.peakMB
                    row.phases = stats?.phases.map { "\($0.phase)=\(String(format: "%.1f", $0.footprintMB))" }
                    let load = await runLoad(seconds: 20)
                    row.ok = load.ok
                    row.failed = load.failed
                    row.errors = load.topErrors
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    row.survived = status == .connected
                }
                row.peakMB = stats?.peakMB
                row.steadyMB = stats?.footprintMB
                row.error = stats?.error
                rows.append(row)
                Self.writeDocument("matrix.json", try? TunnelStats.encoder.encode(rows))
            }
        }
        stop()
        stressSummary = rows.map(\.line).joined(separator: "\n")
    }

    @discardableResult
    private func waitForStatus(timeout: TimeInterval, _ done: (NEVPNStatus) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var moving = false
        while Date() < deadline {
            if done(status) { return true }
            if status == .connecting || status == .disconnecting {
                moving = true
            } else if moving, status == .disconnected {
                return false
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return done(status)
    }

    /// Opens many flows through the tunnel at once, the load that grows the
    /// core's connection tracking and buffers.
    private func runLoad(seconds: TimeInterval) async -> LoadResult {
        let urls = [
            "https://www.gstatic.com/generate_204",
            "https://cp.cloudflare.com/generate_204",
            "https://www.apple.com/",
            "https://www.google.com/",
            "https://github.com/",
            "https://speed.cloudflare.com/__down?bytes=5000000",
        ].compactMap(URL.init(string:))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 64
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let deadline = Date().addingTimeInterval(seconds)
        var result = LoadResult()
        while Date() < deadline {
            await withTaskGroup(of: String?.self) { group in
                for index in 0 ..< 64 {
                    let url = urls[index % urls.count]
                    group.addTask {
                        do {
                            _ = try await session.data(from: url)
                            return nil
                        } catch {
                            return "\((error as NSError).code) \(error.localizedDescription)"
                        }
                    }
                }
                for await failure in group {
                    result.record(failure)
                }
            }
            stressSummary = result.summary
        }
        session.invalidateAndCancel()
        return result
    }

    private func loadManager() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first
        status = manager?.connection.status ?? .invalid
    }

    private func configuredManager() async throws -> NETunnelProviderManager {
        let manager = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Spike.tunnelBundleId
        proto.serverAddress = "FlClash Spike"
        manager.protocolConfiguration = proto
        manager.localizedDescription = "FlClash Spike"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        return manager
    }

    func diagnose() {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        stressSummary = "诊断中…"
        try? session.sendProviderMessage(Spike.diagnoseRequest) { [weak self] data in
            Self.writeDocument("diagnose.json", data)
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "没有结果"
            Task { @MainActor in self?.stressSummary = text }
            try? session.sendProviderMessage(Spike.logsRequest) { Self.writeDocument("logs.json", $0) }
        }
    }

    private nonisolated static func writeDocument(_ name: String, _ data: Data?) {
        guard let data else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? data.write(to: documents.appendingPathComponent(name), options: .atomic)
    }

    /// The latest figures also go to Documents, where devicectl can fetch
    /// them; a jetsam kill leaves the last ones before it there.
    private func requestStats() {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected || session.status == .connecting
        else { return }
        try? session.sendProviderMessage(Spike.statsRequest) { [weak self] data in
            guard let data, let stats = try? TunnelStats.decoder.decode(TunnelStats.self, from: data) else { return }
            Task { @MainActor in self?.stats = stats }
            Self.writeDocument("stats.json", data)
        }
    }
}

struct LoadResult {
    var ok = 0
    var failed = 0
    var errors: [String: Int] = [:]

    mutating func record(_ failure: String?) {
        guard let failure else {
            ok += 1
            return
        }
        failed += 1
        errors[failure, default: 0] += 1
    }

    var topErrors: [String] {
        errors.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value)× \($0.key)" }
    }

    var summary: String {
        (["成功 \(ok) / 失败 \(failed)"] + topErrors).joined(separator: "\n")
    }
}

struct MatrixRow: Codable {
    var config: String
    var stack: String
    var connected: Bool
    var survived: Bool?
    var startupPeakMB: Double?
    var peakMB: Double?
    var steadyMB: Double?
    var ok: Int?
    var failed: Int?
    var errors: [String]?
    var phases: [String]?
    var error: String?

    var line: String {
        let peak = peakMB.map { String(format: "%.1f", $0) } ?? "-"
        guard connected else { return "\(config)/\(stack)：没连上 \(error ?? "") 峰值 \(peak)" }
        let state = survived == true ? "存活" : "被杀"
        return "\(config)/\(stack)：\(state) 峰值 \(peak) MB 成功 \(ok ?? 0) 失败 \(failed ?? 0)"
    }
}

struct ContentView: View {
    @StateObject private var model = TunnelModel()

    var body: some View {
        NavigationView {
            Form {
                Section("设置（下次启动生效）") {
                    Picker("协议栈", selection: $model.options.stack) {
                        ForEach(["system", "gvisor", "mixed", "mips"], id: \.self) { Text($0) }
                    }
                    Picker("Go 内存上限", selection: $model.options.memoryLimitMB) {
                        Text("不设").tag(0)
                        Text("40 MB").tag(40)
                        Text("30 MB").tag(30)
                    }
                    Picker("配置", selection: $model.options.config) {
                        Text("小").tag("small")
                        Text("大 1000 节点 3 万规则").tag("large")
                        Text("超大 3000 节点 10 万规则").tag("xlarge")
                        Text("小 mrs").tag("small-mrs")
                        Text("大 mrs").tag("large-mrs")
                        Text("超大 mrs").tag("xlarge-mrs")
                    }
                    Picker("MTU", selection: $model.options.mtu) {
                        Text("1500").tag(1500)
                        Text("9000").tag(9000)
                    }
                }
                Section("VPN") {
                    LabeledRow("状态", statusText)
                    Button("启动") { Task { await model.start() } }
                    Button("停止", role: .destructive) { model.stop() }
                    Button(model.stressRunning ? "压测中…" : "压测 30 秒") { Task { await model.stress() } }
                        .disabled(model.stressRunning || model.status != .connected)
                    Button("自动测试（约 10 分钟）") { Task { await model.runMatrix() } }
                        .disabled(model.stressRunning)
                    Button("诊断") { model.diagnose() }
                        .disabled(model.status != .connected)
                    if !model.stressSummary.isEmpty { Text(model.stressSummary).font(.footnote) }
                    if !model.message.isEmpty { Text(model.message).foregroundColor(.red) }
                }
                if let stats = model.stats {
                    Section("扩展内存") {
                        LabeledRow("当前", mb(stats.footprintMB))
                        LabeledRow("峰值", mb(stats.peakMB))
                        LabeledRow("剩余可用", mb(stats.availableMB))
                        LabeledRow("推算上限", mb(stats.footprintMB + stats.availableMB))
                        LabeledRow("参数", "\(stats.options.stack) / limit \(stats.options.memoryLimitMB) / mtu \(stats.options.mtu)")
                        if let error = stats.error { Text(error).foregroundColor(.red) }
                    }
                    Section("阶段") {
                        ForEach(stats.phases) { LabeledRow($0.phase, mb($0.footprintMB)) }
                    }
                }
            }
            .navigationTitle("FlClash iOS 验证")
        }
    }

    private var statusText: String {
        switch model.status {
        case .connected: "已连接"
        case .connecting: "连接中"
        case .disconnecting: "断开中"
        case .disconnected: "未连接"
        case .reasserting: "重连中"
        default: "未配置"
        }
    }

    private func mb(_ value: Double) -> String { String(format: "%.1f MB", value) }
}

private struct LabeledRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}
