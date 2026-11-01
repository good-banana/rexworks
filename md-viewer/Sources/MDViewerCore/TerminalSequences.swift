public enum TerminalSequences {
  public static let enableColorSchemeReports = "\u{1b}[?2031h"

  public static let enter =
    "\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1016h"

  public static let restore =
    "\u{1b}[?2031l\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1000l\u{1b}[?25h\u{1b}[?1049l" + Kitty.deleteAll()
}
