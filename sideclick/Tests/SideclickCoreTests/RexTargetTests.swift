import Foundation
import SideclickCore
import Testing

struct RexTargetTests {
  @Test func readsTheFocusPreference() {
    let data = Data(#"{"sessionID":"session:focused"}"#.utf8)
    #expect(lastFocusedSession(preferencesData: data) == "session:focused")
    #expect(lastFocusedSession(preferencesData: nil) == nil)
    #expect(lastFocusedSession(preferencesData: Data("garbage".utf8)) == nil)
  }

  @Test func prefersTheLastFocusedSessionWhenTheAppHasIt() throws {
    let clients = try fixture("client-ls")
    #expect(selectSession(lastFocused: "session:focused", clientListJSON: clients) == "session:focused")
  }

  @Test func fallsBackToTheAppsFirstSessionWhenTheFocusIsStale() throws {
    let clients = try fixture("client-ls")
    #expect(selectSession(lastFocused: "session:gone", clientListJSON: clients) == "session:first")
    #expect(selectSession(lastFocused: nil, clientListJSON: clients) == "session:first")
  }

  @Test func findsNoSessionWithoutAnAppClient() {
    let clients = Data(#"{"clients":[{"info":{"kind":"cli"}}]}"#.utf8)
    #expect(selectSession(lastFocused: "session:focused", clientListJSON: clients) == nil)
  }

  @Test func resolvesTheActiveWindowsFocusedPane() throws {
    let target = focusedPane(sessionInspectJSON: try fixture("session-inspect"), session: "session:focused")
    #expect(target == PaneTarget(session: "session:focused", window: "window:active", block: "block:shell"))
  }

  @Test func resolvesNothingWithoutAnActiveWindowOrFocusedBlock() {
    let noActive = Data(#"{"windows":[{"window_id":"window:a","focused_block_id":"block:a"}]}"#.utf8)
    let noFocus = Data(#"{"active_window_id":"window:a","windows":[{"window_id":"window:a"}]}"#.utf8)
    #expect(focusedPane(sessionInspectJSON: noActive, session: "s") == nil)
    #expect(focusedPane(sessionInspectJSON: noFocus, session: "s") == nil)
  }

  @Test func listsTheWindowsBlocksWithTheFocusedOneFirst() throws {
    let target = PaneTarget(session: "session:focused", window: "window:active", block: "block:browser")
    #expect(
      windowBlocks(blockListJSON: try fixture("block-ls"), target: target) == [
        "block:browser", "block:shell", "block:preview",
      ])
  }

  @Test func readsThePanesChildPID() throws {
    #expect(childPID(processJSON: try fixture("block-process")) == 53648)
    #expect(childPID(processJSON: Data(#"{"child":null}"#.utf8)) == nil)
  }
}
