import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout
import XCTest

@testable import MDViewerInteraction

final class FakeSystem {
  var files: [String: String] = [:]
  var opened: [URL] = []
  var openSucceeds = true
  var safeLocal = true
  var copyOnSelect = false
}

let second: UInt64 = 1_000_000_000

struct Harness {
  var model: ViewerInteraction
  let system: FakeSystem
  var clipboard: [String] = []
  var loads: [URL] = []
  var layoutRequests: [LayoutRequest] = []
  var effects: [InteractionEffect] = []
  var now: UInt64 = 10 * second

  init(
    _ markdown: String, path: String = "/docs/guide.md", width: CGFloat = 1200, height: CGFloat = 600,
    row: CGFloat = 30, files: [String: String] = [:], copyOnSelect: Bool = false
  ) {
    let system = FakeSystem()
    system.files = files
    system.files[path] = markdown
    system.copyOnSelect = copyOnSelect
    self.system = system
    let environment = InteractionEnvironment(
      fileExists: {
        system.files[$0.standardizedFileURL.path] != nil || FileManager.default.fileExists(atPath: $0.path)
      },
      isSafeToOpenLocally: { _ in system.safeLocal },
      openURL: { url in
        system.opened.append(url)
        return system.openSucceeds
      },
      copyOnSelect: { system.copyOnSelect })
    model = ViewerInteraction(
      geometry: ViewGeometry(width: width, contentHeight: height, rowHeight: row),
      typography: Typography(bodySize: 15, zoom: 1, backingScale: 2), environment: environment)
    run(model.open(file: URL(fileURLWithPath: path), source: markdown, at: now))
  }

  var layout: PageLayout { model.layout! }

  mutating func run(_ produced: [InteractionEffect]) {
    effects += produced
    for effect in produced {
      switch effect {
      case .requestLayout(let request):
        layoutRequests.append(request)
        run(model.apply(request.perform(), for: request, at: now))
      case .writeClipboard(let sequence):
        clipboard.append(sequence)
      case .loadDocument(let url):
        loads.append(url)
        if let source = system.files[url.standardizedFileURL.path] {
          run(model.open(file: url, source: source, at: now))
        } else {
          run(model.loadFailed(url, reason: "cannot read \(url.lastPathComponent)", at: now))
        }
      default:
        break
      }
    }
  }

  @discardableResult
  mutating func send(_ event: InputEvent, advance: UInt64 = 1_000_000) -> [InteractionEffect] {
    now += advance
    effects = []
    run(model.handle(event, at: now))
    return effects
  }

  @discardableResult
  mutating func key(_ key: Key) -> [InteractionEffect] { send(.key(key)) }

  @discardableResult
  mutating func keys(_ text: String) -> [InteractionEffect] {
    var all: [InteractionEffect] = []
    for character in text { all += key(.char(character)) }
    return all
  }

  @discardableResult
  mutating func bytes(_ text: String) -> [InteractionEffect] {
    var parser = InputParser()
    var all: [InteractionEffect] = []
    for event in parser.feed(Array(text.utf8)) { all += send(event) }
    return all
  }

  func pane(_ page: CGPoint) -> (Int, Int) {
    (Int(page.x.rounded(.down)), Int((page.y - model.offset).rounded(.down)))
  }

  @discardableResult
  mutating func mouse(
    _ kind: MouseEvent.Kind, at page: CGPoint, button: Int = 0, modifiers: MouseEvent.Modifiers = [],
    advance: UInt64 = 1_000_000
  ) -> [InteractionEffect] {
    let (x, y) = pane(page)
    return send(.mouse(MouseEvent(kind: kind, x: x, y: y, button: button, modifiers: modifiers)), advance: advance)
  }

  @discardableResult
  mutating func paneMouse(_ kind: MouseEvent.Kind, x: Int, y: Int, button: Int = 0) -> [InteractionEffect] {
    send(.mouse(MouseEvent(kind: kind, x: x, y: y, button: button)))
  }

  @discardableResult
  mutating func click(_ page: CGPoint, modifiers: MouseEvent.Modifiers = [], advance: UInt64 = 500_000_000)
    -> [InteractionEffect]
  {
    var all = mouse(.press, at: page, modifiers: modifiers, advance: advance)
    all += mouse(.release, at: page)
    return all
  }

  @discardableResult
  mutating func tick(by delta: UInt64) -> [InteractionEffect] {
    now += delta
    effects = []
    run(model.tick(at: now))
    return effects
  }

  mutating func reload(_ markdown: String) {
    system.files[model.file!.standardizedFileURL.path] = markdown
    effects = []
    run(model.fileChanged(source: markdown))
  }

  func range(of needle: String, occurrence: Int = 0) -> Range<Int>? {
    let text = layout.prepared.text
    var search = NSRange(location: 0, length: text.length)
    var count = 0
    while true {
      let found = text.range(of: needle, options: [], range: search)
      guard found.location != NSNotFound else { return nil }
      if count == occurrence { return found.location..<(found.location + found.length) }
      count += 1
      search = NSRange(location: found.location + found.length, length: text.length - found.location - found.length)
    }
  }

  func point(of needle: String, occurrence: Int = 0, at fraction: CGFloat = 0.5) -> CGPoint {
    let range = range(of: needle, occurrence: occurrence)!
    let rect = layout.rects(for: range).first!.rect
    return CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
  }

  func decodedClipboard(_ index: Int = -1) -> String? {
    guard !clipboard.isEmpty else { return nil }
    let sequence = clipboard[index < 0 ? clipboard.count + index : index]
    let payload = sequence.dropFirst("\u{1b}]52;c;".count).dropLast(2)
    return Data(base64Encoded: String(payload)).flatMap { String(data: $0, encoding: .utf8) }
  }
}

extension Array where Element == InteractionEffect {
  var redrawRects: [CGRect] {
    compactMap {
      if case .redraw(let rect) = $0 { return rect }
      return nil
    }
  }

  var layoutRequests: [LayoutRequest] {
    compactMap {
      if case .requestLayout(let request) = $0 { return request }
      return nil
    }
  }

  var hasFullRedraw: Bool { contains(.redrawAll) }
}

func longDocument(paragraphs: Int = 80) -> String {
  (1...paragraphs).map { "Paragraph \($0) has some words to fill the line for testing." }.joined(separator: "\n\n")
}

let wideCode = "```swift\nlet value = \"" + String(repeating: "abcdefghij", count: 40) + "\" + needle\n```"
