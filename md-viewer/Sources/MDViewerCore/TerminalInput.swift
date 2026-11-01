public enum Key: Equatable {
  case char(Character)
  case up, down, pageUp, pageDown, home, end
  case enter, tab, backTab, backspace, escape
  case ctrl(Character)
}

public struct MouseEvent: Equatable {
  public enum Kind: Equatable { case press, release, wheelUp, wheelDown }

  public struct Modifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: 4)
    public static let alt = Modifiers(rawValue: 8)
    public static let control = Modifiers(rawValue: 16)
  }

  public var kind: Kind
  public var x: Int
  public var y: Int
  public var button: Int
  public var modifiers: Modifiers

  public init(kind: Kind, x: Int, y: Int, button: Int = 0, modifiers: Modifiers = []) {
    self.kind = kind
    self.x = x
    self.y = y
    self.button = button
    self.modifiers = modifiers
  }

  public var isPrimaryClick: Bool {
    kind == .press && button == 0 && modifiers.isEmpty
  }
}

public enum ColorScheme: Equatable, Sendable {
  case dark, light

  public init?(reportParams params: String, final: UInt8) {
    guard final == 0x6e else { return nil }
    switch params {
    case "?997;1": self = .dark
    case "?997;2": self = .light
    default: return nil
    }
  }
}

public enum InputEvent: Equatable {
  case key(Key)
  case mouse(MouseEvent)
  case colorScheme(ColorScheme)

  public var requestsThemeResolve: Bool {
    switch self {
    case .colorScheme, .key(.char("r")): true
    default: false
    }
  }
}

public struct InputParser {
  private static let maximumStringSequence = 4096

  private var pending: [UInt8] = []

  public init() {}

  public mutating func feed(_ bytes: [UInt8]) -> [InputEvent] {
    pending.append(contentsOf: bytes)
    var events: [InputEvent] = []
    while !pending.isEmpty {
      switch parseOne() {
      case .event(let event, let consumed):
        pending.removeFirst(consumed)
        if let event { events.append(event) }
      case .incomplete:
        return events
      }
    }
    return events
  }

  private enum Parsed {
    case event(InputEvent?, Int)
    case incomplete
  }

  private func parseOne() -> Parsed {
    let first = pending[0]
    if first == 0x1b {
      if pending.count == 1 { return .event(.key(.escape), 1) }
      if pending[1] == 0x5b { return parseCSI() }
      if pending[1] == 0x4f { return parseSS3() }
      if pending[1] == 0x5d { return skipOSC() }
      return .event(.key(.escape), 1)
    }
    return parseSimple(first)
  }

  private func parseSS3() -> Parsed {
    guard pending.count >= 3 else { return .incomplete }
    let key: Key? =
      switch pending[2] {
      case 0x41: .up
      case 0x42: .down
      case 0x48: .home
      case 0x46: .end
      default: nil
      }
    return .event(key.map { .key($0) }, 3)
  }

  private func parseSimple(_ first: UInt8) -> Parsed {
    switch first {
    case 0x0d, 0x0a: return .event(.key(.enter), 1)
    case 0x09: return .event(.key(.tab), 1)
    case 0x7f, 0x08: return .event(.key(.backspace), 1)
    case 0x01...0x1a:
      let letter = Character(UnicodeScalar(first + 0x60))
      return .event(.key(.ctrl(letter)), 1)
    case 0x20...0x7e:
      return .event(.key(.char(Character(UnicodeScalar(first)))), 1)
    case 0xc0...0xff:
      let length = first >= 0xf0 ? 4 : first >= 0xe0 ? 3 : 2
      guard pending.count >= length else { return .incomplete }
      let text = String(decoding: pending[0..<length], as: UTF8.self)
      if let character = text.first, text.count == 1 {
        return .event(.key(.char(character)), length)
      }
      return .event(nil, length)
    default:
      return .event(nil, 1)
    }
  }

  private func skipOSC() -> Parsed {
    var index = 2
    while index < pending.count {
      switch pending[index] {
      case 0x07:
        return .event(nil, index + 1)
      case 0x1b:
        guard index + 1 < pending.count else { return .incomplete }
        return .event(nil, pending[index + 1] == 0x5c ? index + 2 : index)
      default:
        index += 1
      }
    }
    return pending.count > Self.maximumStringSequence ? .event(nil, pending.count) : .incomplete
  }

  private func parseCSI() -> Parsed {
    var index = 2
    while index < pending.count {
      let byte = pending[index]
      if (0x40...0x7e).contains(byte) {
        let params = String(decoding: pending[2..<index], as: UTF8.self)
        return .event(decodeCSI(params: params, final: byte), index + 1)
      }
      index += 1
    }
    return .incomplete
  }

  private func decodeCSI(params: String, final: UInt8) -> InputEvent? {
    if params.hasPrefix("<") {
      return decodeMouse(String(params.dropFirst()), final: final)
    }
    if let scheme = ColorScheme(reportParams: params, final: final) {
      return .colorScheme(scheme)
    }
    switch final {
    case 0x41: return .key(.up)
    case 0x42: return .key(.down)
    case 0x48: return .key(.home)
    case 0x46: return .key(.end)
    case 0x5a: return .key(.backTab)
    case 0x7e:
      switch params.split(separator: ";").first.flatMap({ Int($0) }) {
      case 1, 7: return .key(.home)
      case 4, 8: return .key(.end)
      case 5: return .key(.pageUp)
      case 6: return .key(.pageDown)
      default: return nil
      }
    default: return nil
    }
  }

  private func decodeMouse(_ params: String, final: UInt8) -> InputEvent? {
    let fields = params.split(separator: ";").compactMap { Int($0) }
    guard fields.count == 3, final == 0x4d || final == 0x6d else { return nil }
    let button = fields[0]
    let x = fields[1] - 1
    let y = fields[2] - 1
    let modifiers = MouseEvent.Modifiers(rawValue: button & 0x1c)
    let kind: MouseEvent.Kind
    var pressed = 0
    switch button & ~0x1c {
    case 64: kind = .wheelUp
    case 65: kind = .wheelDown
    case 0...2:
      kind = final == 0x4d ? .press : .release
      pressed = button & 0x3
    default: return nil
    }
    return .mouse(MouseEvent(kind: kind, x: x, y: y, button: pressed, modifiers: modifiers))
  }
}
