import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerLayout

public enum InteractionEffect: Equatable {
  case redraw(CGRect)
  case redrawStatusBar
  case redrawAll
  case scroll(to: CGFloat)
  case layoutChanged
  case regionScrolled(BlockID, offset: CGFloat)
  case requestLayout(LayoutRequest)
  case writeClipboard(String, markdown: Bool)
  case pointerShape(PointerShape)
  case loadDocument(URL)
  case reload
  case quit
}

public struct ViewGeometry: Equatable, Sendable {
  public var width: CGFloat
  public var contentHeight: CGFloat
  public var rowHeight: CGFloat

  public init(width: CGFloat, contentHeight: CGFloat, rowHeight: CGFloat) {
    self.width = width
    self.contentHeight = contentHeight
    self.rowHeight = rowHeight
  }
}

public struct InteractionEnvironment {
  public var fileExists: (URL) -> Bool
  public var isSafeToOpenLocally: (URL) -> Bool
  public var openURL: (URL) -> Bool
  public var copyOnSelect: () -> Bool

  public init(
    fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
    isSafeToOpenLocally: @escaping (URL) -> Bool = MDViewerCore.isSafeToOpenLocally,
    openURL: @escaping (URL) -> Bool,
    copyOnSelect: @escaping () -> Bool = { RexPreferences().copyOnSelect }
  ) {
    self.fileExists = fileExists
    self.isSafeToOpenLocally = isSafeToOpenLocally
    self.openURL = openURL
    self.copyOnSelect = copyOnSelect
  }
}

public enum Focusable: Hashable, Sendable {
  case link(Range<Int>, href: String)
  case details(BlockID)
  case codeBlock(BlockID)
  case table(BlockID)
  case video(Int, href: String)
}

public struct InteractionTiming: Sendable {
  public var multiClickNanoseconds: UInt64 = 400_000_000
  public var autoScrollNanoseconds: UInt64 = 30_000_000
  public var wheelStreakNanoseconds: UInt64 = 60_000_000
  public var copiedNanoseconds: UInt64 = 1_500_000_000
  public var infoNanoseconds: UInt64 = 2_500_000_000
  public var successNanoseconds: UInt64 = 2_000_000_000
  public var errorNanoseconds: UInt64 = 4_000_000_000

  public init() {}
}

public struct WheelAccelerator: Sendable {
  public static let maximumMultiplier = 4

  public var streakWindow: UInt64
  private var lastEvent: UInt64?
  private var lastDirection = 0
  private var streak = 0

  public init(streakWindow: UInt64 = InteractionTiming().wheelStreakNanoseconds) {
    self.streakWindow = streakWindow
  }

  public mutating func multiplier(direction: Int, at now: UInt64) -> Int {
    if let lastEvent, now >= lastEvent, now - lastEvent <= streakWindow, direction == lastDirection {
      streak += 1
    } else {
      streak = 0
    }
    lastEvent = now
    lastDirection = direction
    return min(1 + streak / 3, Self.maximumMultiplier)
  }
}

public enum ZoomSteps {
  public static let levels: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

  public static func next(after zoom: CGFloat) -> CGFloat {
    levels.first { $0 > zoom + 0.001 } ?? levels[levels.count - 1]
  }

  public static func previous(before zoom: CGFloat) -> CGFloat {
    levels.last { $0 < zoom - 0.001 } ?? levels[0]
  }
}
