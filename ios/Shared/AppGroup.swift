import Foundation

/// The App Group container is the Core's home in both processes, and where
/// the app leaves the state the packet tunnel starts from.
enum AppGroup {
  static let identifier = Bundle.main.object(forInfoDictionaryKey: "FlClashAppGroup") as! String

  static var container: URL {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)!
  }

  static var sharedStateFile: URL { stateDirectory.appendingPathComponent("shared-state.json") }

  static var setupParamsFile: URL { stateDirectory.appendingPathComponent("setup-params.json") }

  /// The Core's cache.db stays in this process's own container: bbolt keeps it
  /// locked, and a suspended app holding a lock in the App Group gets killed.
  static var processCacheFile: String {
    let directory = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    return (directory ?? FileManager.default.temporaryDirectory).appendingPathComponent("cache.db").path
  }

  static var tunnelBundleIdentifier: String { "\(Bundle.main.bundleIdentifier!).PacketTunnel" }

  private static var stateDirectory: URL {
    let directory = container.appendingPathComponent("ios", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

enum TunnelMessage: UInt8 {
  case invoke = 1
  case pullEvents = 2

  func encode(_ payload: Data = Data()) -> Data {
    var data = Data([rawValue])
    data.append(payload)
    return data
  }

  static func decode(_ data: Data) -> (TunnelMessage, Data)? {
    guard let first = data.first, let kind = TunnelMessage(rawValue: first) else { return nil }
    return (kind, data.dropFirst())
  }
}

enum EventFrames {
  static func encode(_ batches: [Data]) -> Data {
    var data = Data()
    for batch in batches {
      var length = UInt32(batch.count).bigEndian
      data.append(Data(bytes: &length, count: 4))
      data.append(batch)
    }
    return data
  }

  static func decode(_ data: Data) -> [Data] {
    var batches: [Data] = []
    var offset = data.startIndex
    while data.endIndex - offset >= 4 {
      let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
      offset += 4
      guard data.endIndex - offset >= length else { break }
      batches.append(data[offset..<offset + length])
      offset += length
    }
    return batches
  }
}
