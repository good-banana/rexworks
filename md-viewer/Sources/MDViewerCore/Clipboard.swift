import Foundation

public enum Clipboard {
  public static let maximumSequenceBytes = 8 * 1024 * 1024
  public static let writeChunkBytes = 64 * 1024
  static let prefix = "\u{1b}]52;c;"
  static let terminator = "\u{1b}\\"

  public static var maximumTextBytes: Int {
    (maximumSequenceBytes - prefix.utf8.count - terminator.utf8.count) / 4 * 3
  }

  public static func sequence(for text: String) -> String? {
    let data = Data(text.utf8)
    guard data.count <= maximumTextBytes else { return nil }
    return prefix + data.base64EncodedString() + terminator
  }

  public static func writeChunks(_ sequence: String, size: Int = writeChunkBytes) -> [String] {
    let bytes = Array(sequence.utf8)
    let step = max(size, 1)
    return stride(from: 0, to: bytes.count, by: step).map {
      String(decoding: bytes[$0..<min($0 + step, bytes.count)], as: UTF8.self)
    }
  }
}

public struct RexPreferences {
  public static let copyOnSelectKey = "Workspace.terminalCopyOnSelect"

  public var reader: PreferenceReading

  public init(reader: PreferenceReading = SystemPreferenceReader()) {
    self.reader = reader
  }

  public var copyOnSelect: Bool {
    switch reader.value(forKey: Self.copyOnSelectKey, domain: ThemeResolver.preferencesDomain) {
    case let value as Bool: value
    case let value as NSNumber: value.boolValue
    case let value as String: ["1", "true", "yes"].contains(value.lowercased())
    default: false
    }
  }
}
