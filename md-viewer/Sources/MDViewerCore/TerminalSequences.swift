public enum PointerShape: String, Sendable {
  case `default`
  case pointer
  case text
}

public enum TerminalSequences {
  public static func pointerShape(_ shape: PointerShape) -> String { "\u{1b}]22;\(shape.rawValue)\u{1b}\\" }

  public static let enableColorSchemeReports = "\u{1b}[?2031h"
  public static let enableInBandResizeReports = "\u{1b}[?2048h"
  public static let queryInBandResizeReports = "\u{1b}[?2048$p"
  public static let enableMouseMotion = "\u{1b}[?1003h"
  public static let enableKeyboardDisambiguation = "\u{1b}[>1u"
  public static let enableShiftCapture = "\u{1b}[>1s"

  public static let enableViewerModes =
    enableInBandResizeReports + enableMouseMotion + enableShiftCapture + enableKeyboardDisambiguation
    + enableColorSchemeReports

  public static let enter =
    "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1016h"

  public static let queryCellSize = "\u{1b}[16t"

  public static let restoreModes =
    "\u{1b}[?2031l\u{1b}[<u\u{1b}[>0s\u{1b}[?1003l\u{1b}[?2048l\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?25h"
    + pointerShape(.default) + Kitty.deleteAll()

  public static let restoreScreen = "\u{1b}[?1049l"

  public static let restore = restoreModes + restoreScreen
}
