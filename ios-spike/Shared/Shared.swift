import Foundation

/// No App Group: an App Store Connect API key cannot create one.
enum Spike {
    static let tunnelBundleId = "com.flclashspike.app.tunnel"
    static let optionsKey = "spike-options"
    static let statsRequest = Data("stats".utf8)
    static let logsRequest = Data("logs".utf8)
    static let diagnoseRequest = Data("diagnose".utf8)
}

struct SpikeOptions: Codable {
    var stack = "system"
    var memoryLimitMB = 0
    var mtu = 1500
    var config = "small"
}

struct PhaseSample: Codable, Identifiable {
    var phase: String
    var footprintMB: Double
    var at: Date
    var id: String { "\(phase)-\(at.timeIntervalSince1970)" }
}

struct TunnelStats: Codable {
    var options: SpikeOptions
    var footprintMB: Double
    var peakMB: Double
    var availableMB: Double
    var phases: [PhaseSample]
    var error: String?
    var updatedAt: Date

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// phys_footprint is the figure jetsam compares against the extension's limit.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

let megabyte = 1024.0 * 1024.0
