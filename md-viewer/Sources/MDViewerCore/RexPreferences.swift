import Foundation

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
