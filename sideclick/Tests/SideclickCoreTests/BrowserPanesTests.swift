import Foundation
import SideclickCore
import Testing

struct BrowserPanesTests {
  @Test func decodesBrowsersWithATTY() throws {
    #expect(
      browsers(listJSON: try fixture("terminal-browser-ls")) == [
        BrowserInstance(key: "50273-1", tty: "ttys005"),
        BrowserInstance(key: "50273-6", tty: "ttys009"),
      ])
    #expect(browsers(listJSON: Data("not json".utf8)).isEmpty)
  }

  @Test func normalizesTTYNames() {
    #expect(normalizedTTY("/dev/ttys009") == "ttys009")
    #expect(normalizedTTY("ttys009 ") == "ttys009")
  }

  @Test func parsesPSOutputAndSkipsProcessesWithoutATerminal() {
    let output = Data("53648 ttys009 \n  901 ??\n 77 ttys005\nbad line here\n".utf8)
    #expect(processTTYs(psOutput: output) == [53648: "ttys009", 77: "ttys005"])
  }

  let running = [BrowserInstance(key: "b-1", tty: "ttys005"), BrowserInstance(key: "b-2", tty: "ttys009")]

  @Test func matchesTheFocusedPaneWhenItIsABrowser() {
    let ttys = ["block:focused": "ttys009", "block:other": "ttys005"]
    #expect(
      matchingBrowser(blocks: ["block:focused", "block:other"], blockTTYs: ttys, browsers: running)
        == BrowserPane(block: "block:focused", key: "b-2"))
  }

  @Test func matchesANeighborBrowser() {
    let ttys = ["block:focused": "ttys001", "block:other": "ttys005"]
    #expect(
      matchingBrowser(blocks: ["block:focused", "block:other"], blockTTYs: ttys, browsers: running)
        == BrowserPane(block: "block:other", key: "b-1"))
  }

  @Test func matchesTheFirstOfSeveralBrowsersInBlockOrder() {
    let ttys = ["block:a": "ttys009", "block:b": "ttys005"]
    #expect(
      matchingBrowser(blocks: ["block:focused", "block:a", "block:b"], blockTTYs: ttys, browsers: running)
        == BrowserPane(block: "block:a", key: "b-2"))
  }

  @Test func matchesNothingWhenNoPaneHostsABrowser() {
    let ttys = ["block:focused": "ttys001"]
    #expect(matchingBrowser(blocks: ["block:focused"], blockTTYs: ttys, browsers: running) == nil)
  }
}
