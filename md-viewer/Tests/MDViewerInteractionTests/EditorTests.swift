import CoreGraphics
import Foundation
import MDViewerLayout
import MDViewerRender
import XCTest

@testable import MDViewerCore
@testable import MDViewerInteraction

private let candidates = [
  EditorCandidate(name: "nvim", executable: "/opt/homebrew/bin/nvim", kind: .neovim),
  EditorCandidate(name: "hx", executable: "/opt/homebrew/bin/hx", kind: .helix),
  EditorCandidate(name: "code", executable: "/usr/local/bin/code", kind: .vscode),
]

private let neovim = EditorLink(name: "Neovim", syncsLive: true, followsShownFile: true)

private let blocks = """
  # Title

  First paragraph line one
  continues on line four
  and line five.

  ```swift
  let a = 1
  let b = 2
  let c = 3
  ```

      indented one
      indented two

  | A | B |
  | --- | --- |
  | 1 | 2 |

  - item one
  - item two

  Last paragraph.
  """

final class EditKeyTests: XCTestCase {
  func testEAndShiftEEmitEditIntentsAndCommaOpensThePicker() {
    var h = Harness(blocks)
    XCTAssertEqual(h.key(.char("e")), [.edit(EditRequest(mode: .configured, line: 1))])
    XCTAssertEqual(h.key(.char("E")), [.edit(EditRequest(mode: .alternate, line: 1))])
    XCTAssertEqual(h.key(.char(",")), [.openEditorPicker])
  }

  func testTheJumpLineIsTheSelectionsSourceLine() {
    var h = Harness(blocks)
    h.click(h.point(of: "continues"))
    h.mouse(.press, at: h.point(of: "continues"), advance: 100_000_000)
    h.mouse(.release, at: h.point(of: "continues"))
    XCTAssertEqual(h.model.selection, h.range(of: "continues"))
    XCTAssertEqual(h.key(.char("e")), [.edit(EditRequest(mode: .configured, line: 4))])
  }

  func testASelectionInsideACodeBlockUsesTheCodeLine() {
    var h = Harness(blocks)
    h.click(h.point(of: "b = 2"))
    h.mouse(.press, at: h.point(of: "b = 2"), advance: 100_000_000)
    h.mouse(.release, at: h.point(of: "b = 2"))
    XCTAssertNotNil(h.model.selection)
    XCTAssertEqual(h.model.editLine, 9)
  }

  func testWithoutASelectionTheTopUnitOfTheViewIsUsed() {
    var h = Harness(longDocument(), height: 300)
    XCTAssertEqual(h.model.editLine, 1)
    let top = h.layout.rects(for: h.range(of: "Paragraph 20 ")!).first!.rect.minY
    h.run(h.model.setOffset((top / 30).rounded(.up) * 30))
    XCTAssertEqual(h.model.editLine, 39, "paragraph 20 starts on line 39")
  }

  func testAnEmptyDocumentEditsAtLineOne() {
    var h = Harness("")
    XCTAssertEqual(h.key(.char("e")), [.edit(EditRequest(mode: .configured, line: 1))])
  }

  func testFindAndHelpKeepPrecedence() {
    var h = Harness(blocks)
    h.key(.char("/"))
    let typed = h.keys("eE,")
    XCTAssertFalse(typed.contains { if case .edit = $0 { true } else { $0 == .openEditorPicker } })
    XCTAssertEqual(h.model.findField, "eE,")
    h.key(.escape)
    h.key(.char("?"))
    XCTAssertEqual(h.key(.char("e")), [.redrawAll], "the key only closes help")
    XCTAssertFalse(h.model.helpVisible)
  }
}

final class EditorPickerInputTests: XCTestCase {
  private func harness(pending: EditRequest? = EditRequest(mode: .alternate, line: 7)) -> Harness {
    var h = Harness(blocks)
    h.run(h.model.showEditorPicker(candidates: candidates, mode: .split, pending: pending))
    return h
  }

  func testShowingThePickerClosesHelp() {
    var h = Harness(blocks)
    h.key(.char("?"))
    XCTAssertEqual(
      h.model.showEditorPicker(candidates: candidates, mode: .here, pending: nil), [.redrawAll])
    XCTAssertFalse(h.model.helpVisible)
    XCTAssertEqual(h.model.editorPicker, EditorPickerContent(candidates: candidates, mode: .here))
  }

  func testArrowsAndJKMoveTheSelectionAndWrap() {
    var h = harness()
    XCTAssertEqual(h.key(.char("j")), [.redrawAll])
    XCTAssertEqual(h.model.editorPicker?.selected, 1)
    h.key(.down)
    XCTAssertEqual(h.model.editorPicker?.selected, 2)
    h.key(.down)
    XCTAssertEqual(h.model.editorPicker?.selected, 0)
    h.key(.up)
    XCTAssertEqual(h.model.editorPicker?.selected, 2)
    h.key(.char("k"))
    XCTAssertEqual(h.model.editorPicker?.selected, 1)
  }

  func testEnterChoosesTheSelectedRowWithTheModeAndThePendingIntent() {
    var h = harness()
    h.key(.down)
    XCTAssertEqual(h.key(.tab), [.redrawAll])
    XCTAssertEqual(h.model.editorPicker?.mode, .here)
    XCTAssertEqual(
      h.key(.enter),
      [.redrawAll, .chooseEditor(candidates[1], mode: .here, pending: EditRequest(mode: .alternate, line: 7))])
    XCTAssertNil(h.model.editorPicker)
  }

  func testDigitsChooseDirectly() {
    var h = harness(pending: nil)
    XCTAssertEqual(h.key(.char("9")), [], "no ninth row")
    XCTAssertNotNil(h.model.editorPicker)
    XCTAssertEqual(h.key(.char("3")), [.redrawAll, .chooseEditor(candidates[2], mode: .split, pending: nil)])
  }

  func testEscapeAndQCancelWithoutChoosing() {
    var h = harness()
    XCTAssertEqual(h.key(.escape), [.redrawAll])
    XCTAssertNil(h.model.editorPicker)
    h.run(h.model.showEditorPicker(candidates: candidates, mode: .split, pending: nil))
    XCTAssertEqual(h.key(.char("q")), [.redrawAll], "q closes the picker instead of quitting")
    XCTAssertNil(h.model.editorPicker)
    XCTAssertEqual(h.key(.char("q")), [.quit])
  }

  func testTheCancelledPendingIntentIsNotCarriedIntoALaterPicker() {
    var h = harness()
    h.key(.escape)
    h.run(h.model.showEditorPicker(candidates: candidates, mode: .split, pending: nil))
    XCTAssertEqual(h.key(.enter), [.redrawAll, .chooseEditor(candidates[0], mode: .split, pending: nil)])
  }

  func testOtherKeysDoNothingWhileThePickerIsOpen() {
    var h = harness()
    let offset = h.model.offset
    XCTAssertEqual(h.key(.char("e")), [])
    XCTAssertEqual(h.key(.char("G")), [])
    XCTAssertEqual(h.key(.char("?")), [])
    XCTAssertFalse(h.model.helpVisible)
    XCTAssertEqual(h.model.offset, offset)
    XCTAssertEqual(h.key(.ctrl("c")), [.quit])
  }

  func testAnyKeyClosesAnEmptyPicker() {
    var h = Harness(blocks)
    h.run(h.model.showEditorPicker(candidates: [], mode: .split, pending: nil))
    XCTAssertEqual(h.key(.enter), [.redrawAll])
    XCTAssertNil(h.model.editorPicker)
  }

  func testClickingARowChoosesItAndClickingOutsideCancels() {
    var h = harness()
    let picker = EditorPicker(content: h.model.editorPicker!, backingScale: 2)
    let area = CGRect(x: 0, y: 0, width: 1200, height: 600)
    let row = picker.rowRect(1, in: area)
    XCTAssertEqual(h.paneMouse(.motion, x: Int(row.midX), y: Int(row.midY)), [])
    XCTAssertEqual(
      h.paneMouse(.press, x: Int(row.midX), y: Int(row.midY)),
      [.redrawAll, .chooseEditor(candidates[1], mode: .split, pending: EditRequest(mode: .alternate, line: 7))])
    h.paneMouse(.release, x: Int(row.midX), y: Int(row.midY))
    XCTAssertTrue(h.system.opened.isEmpty)

    h.run(h.model.showEditorPicker(candidates: candidates, mode: .split, pending: nil))
    let panel = picker.panel(in: area)
    XCTAssertEqual(h.paneMouse(.press, x: Int(panel.midX), y: Int(panel.minY) + 4), [], "inside the panel")
    XCTAssertNotNil(h.model.editorPicker)
    XCTAssertEqual(h.paneMouse(.press, x: 4, y: 4), [.redrawAll])
    XCTAssertNil(h.model.editorPicker)
  }
}

final class ClickToJumpTests: XCTestCase {
  private func jumps(_ effects: [InteractionEffect]) -> [Int] {
    effects.compactMap {
      if case .jumpEditor(let line) = $0 { return line }
      return nil
    }
  }

  func testAClickOnTextJumpsALinkedNeovimThatShowsThisFile() {
    var h = Harness(blocks, height: 2000)
    h.run(h.model.setEditorLink(neovim))
    XCTAssertEqual(jumps(h.click(h.point(of: "continues"))), [4])
    XCTAssertEqual(jumps(h.click(h.point(of: "Title"))), [1])
    XCTAssertEqual(jumps(h.click(h.point(of: "c = 3"))), [10], "code blocks jump to the code line")
    XCTAssertEqual(jumps(h.click(h.point(of: "indented two"))), [14])
    XCTAssertEqual(jumps(h.click(h.point(of: "item two"))), [21])
  }

  func testATaskCheckboxClickDoesNotJump() throws {
    var h = Harness("- [ ] first task\n- [x] second task\n")
    h.run(h.model.setEditorLink(neovim))
    let boxes = h.layout.decorations.filter { if case .taskBox = $0.kind { true } else { false } }
    XCTAssertEqual(boxes.count, 2)
    for box in boxes {
      XCTAssertEqual(jumps(h.click(CGPoint(x: box.rect.midX, y: box.rect.midY))), [])
    }
    XCTAssertEqual(jumps(h.click(h.point(of: "second"))), [2], "the task text still jumps")
  }

  func testNoJumpWithoutALiveEditorOnThisFile() {
    var h = Harness(blocks)
    XCTAssertEqual(jumps(h.click(h.point(of: "continues"))), [], "no editor")
    h.run(h.model.setEditorLink(EditorLink(name: "Helix", syncsLive: false, followsShownFile: true)))
    XCTAssertEqual(jumps(h.click(h.point(of: "continues"))), [], "not live")
    h.run(h.model.setEditorLink(EditorLink(name: "Neovim", syncsLive: true, followsShownFile: false)))
    XCTAssertEqual(jumps(h.click(h.point(of: "continues"))), [], "Neovim shows another file")
  }

  func testDragsMultiClicksLinksAndBlankSpaceDoNotJump() {
    var h = Harness("Some text with [a link](other.md) inside.\n\nMore text here.", files: ["/docs/other.md": "x"])
    h.run(h.model.setEditorLink(neovim))
    let start = h.point(of: "Some")
    h.mouse(.press, at: start, advance: 500_000_000)
    h.mouse(.motion, at: h.point(of: "text with"))
    XCTAssertEqual(jumps(h.mouse(.release, at: h.point(of: "text with"))), [], "a drag")
    let word = h.point(of: "More")
    h.click(word)
    var effects = h.mouse(.press, at: word, advance: 100_000_000)
    effects += h.mouse(.release, at: word)
    XCTAssertEqual(jumps(effects), [], "the second click of a double-click")
    XCTAssertEqual(jumps(h.click(CGPoint(x: 1100, y: h.point(of: "More").y))), [], "blank space")
    XCTAssertEqual(jumps(h.click(h.point(of: "a link"))), [], "a link")
    XCTAssertEqual(h.loads.last?.lastPathComponent, "other.md")
  }
}

final class EditorCursorTests: XCTestCase {
  func testYForSourceLineAcrossBlockKinds() throws {
    let h = Harness(blocks, width: 1200)
    func y(_ line: Int) throws -> CGFloat { try XCTUnwrap(h.model.y(forSourceLine: line)) }
    func fragmentTop(_ needle: String) -> CGFloat {
      let offset = h.range(of: needle)!.lowerBound
      return h.layout.fragments.first { $0.range.contains(offset) }!.lineTop
    }
    XCTAssertEqual(try y(1), fragmentTop("Title"))
    XCTAssertEqual(try y(3), fragmentTop("First"))
    XCTAssertEqual(try y(9), fragmentTop("let b"))
    XCTAssertEqual(try y(10), fragmentTop("let c"))
    XCTAssertEqual(try y(8), fragmentTop("let a"))
    XCTAssertEqual(try y(7), fragmentTop("let a"), "the opening fence maps to the first code line")
    XCTAssertEqual(try y(11), fragmentTop("let c"), "the closing fence maps to the last code line")
    XCTAssertEqual(try y(13), fragmentTop("indented one"))
    XCTAssertEqual(try y(14), fragmentTop("indented two"))
    XCTAssertEqual(try y(16), fragmentTop("A"))
    XCTAssertGreaterThan(try y(18), fragmentTop("A"), "the body row lies below the header")
    XCTAssertEqual(try y(21), fragmentTop("item two"))
    XCTAssertEqual(try y(23), fragmentTop("Last"))
    XCTAssertEqual(try y(2), fragmentTop("First"), "a blank line maps to the next block")
    XCTAssertNotNil(h.model.y(forSourceLine: 500), "past the end still has a position")
    XCTAssertLessThan(try y(1), try y(3))
    XCTAssertLessThan(try y(3), try y(8))
  }

  func testLinesInsideAWrappedParagraphAreInterpolated() throws {
    let lines = (1...6).map { "Line \($0) " + String(repeating: "word ", count: 30) }.joined(separator: "\n")
    let h = Harness(lines, width: 600)
    let fragments = h.layout.fragments.sorted { $0.lineTop < $1.lineTop }
    XCTAssertGreaterThan(Set(fragments.map(\.lineTop)).count, 6, "the paragraph wraps")
    var previous: CGFloat = -1
    for line in 1...6 {
      let y = try XCTUnwrap(h.model.y(forSourceLine: line))
      XCTAssertGreaterThan(y, previous, "line \(line) is below line \(line - 1)")
      XCTAssertTrue(fragments.contains { $0.lineTop == y }, "line \(line) snaps to a rendered line")
      previous = y
    }
  }

  func testACursorScrollsToNeovimsFractionAndDrawsTheBar() throws {
    var h = Harness(longDocument(), height: 600, row: 30)
    let line = 61
    let y = try XCTUnwrap(h.model.y(forSourceLine: line))
    h.effects = []
    h.run(h.model.applyEditorCursor(EditorCursor(line: line, top: 51, height: 40)))
    XCTAssertEqual(h.model.editorCursor, EditorCursor(line: line, top: 51, height: 40))
    XCTAssertEqual(h.model.offset, h.model.snapped(y - 0.25 * 600))
    let bar = try XCTUnwrap(h.model.overlay.sourceCursor)
    XCTAssertEqual(bar.minY, y)
    XCTAssertGreaterThan(bar.height, 0)
    XCTAssertLessThan(bar.maxX, h.layout.fragments.map(\.minX).min()!, "the bar sits in the margin")
    XCTAssertTrue(h.effects.contains(.scroll(to: h.model.offset)))
    XCTAssertTrue(h.effects.redrawRects.contains { $0.contains(CGPoint(x: bar.midX, y: bar.midY)) })

    h.effects = []
    h.run(h.model.applyEditorCursor(EditorCursor(line: line, top: line, height: 40)))
    XCTAssertEqual(h.model.offset, h.model.snapped(y), "the line at the top of Neovim's window is at the top")
    XCTAssertEqual(h.model.overlay.sourceCursor, bar)
    XCTAssertTrue(h.effects.redrawRects.isEmpty, "the unchanged bar is not redrawn")
  }

  func testTheCursorIsAppliedAgainAfterABufferLayout() throws {
    var h = Harness(longDocument(), height: 600, row: 30)
    h.run(h.model.applyEditorCursor(EditorCursor(line: 41, top: 31, height: 40)))
    let before = try XCTUnwrap(h.model.overlay.sourceCursor)
    let inserted = "A\nB\nC\n\n" + longDocument()
    h.run(h.model.fileChanged(source: inserted) + h.model.setLiveBuffer(true))
    XCTAssertTrue(h.model.liveBuffer)
    let y = try XCTUnwrap(h.model.y(forSourceLine: 41))
    XCTAssertEqual(h.model.overlay.sourceCursor?.minY, y)
    XCTAssertNotEqual(y, before.minY)
    XCTAssertEqual(h.model.offset, h.model.snapped(y - 0.25 * 600))
  }

  func testACursorArrivingBeforeAPendingLayoutIsAppliedWhenItLands() throws {
    var h = Harness("Short.", height: 600, row: 30, files: ["/docs/next.md": longDocument()])
    let next = URL(fileURLWithPath: "/docs/next.md")
    let opened = h.model.open(file: next, source: "Stale text.")
    XCTAssertFalse(opened.layoutRequests.isEmpty, "follow requests a layout that is held back")
    let changed = h.model.fileChanged(source: longDocument())
    let request = try XCTUnwrap(changed.layoutRequests.last)
    XCTAssertEqual(h.model.applyEditorCursor(EditorCursor(line: 61, top: 51, height: 40)), [])
    XCTAssertEqual(h.model.offset, 0)
    XCTAssertNil(h.model.overlay.sourceCursor, "no bar against the previous document's layout")
    h.run(h.model.apply(request.perform(), for: request, at: h.now))
    let y = try XCTUnwrap(h.model.y(forSourceLine: 61))
    XCTAssertEqual(h.model.offset, h.model.snapped(y - 0.25 * 600))
    XCTAssertEqual(h.model.overlay.sourceCursor?.minY, y)
    XCTAssertEqual(h.model.editorCursor, EditorCursor(line: 61, top: 51, height: 40))
  }

  func testTheBarFollowsAWidthChangeWithoutScrolling() throws {
    var h = Harness(longDocument(), height: 600, row: 30)
    h.run(h.model.applyEditorCursor(EditorCursor(line: 41, top: 31, height: 40)))
    h.run(h.model.resize(ViewGeometry(width: 500, contentHeight: 600, rowHeight: 30)))
    XCTAssertEqual(h.model.overlay.sourceCursor?.minY, h.model.y(forSourceLine: 41))
  }

  func testACursorWithoutALayoutIsKeptForLater() {
    var model = ViewerInteraction(
      geometry: ViewGeometry(width: 800, contentHeight: 600, rowHeight: 30),
      typography: Typography(bodySize: 15, zoom: 1, backingScale: 2),
      environment: InteractionEnvironment(openURL: { _ in true }, copyOnSelect: { false }))
    XCTAssertEqual(model.applyEditorCursor(EditorCursor(line: 3, top: 1, height: 20)), [])
    XCTAssertEqual(model.editorCursor, EditorCursor(line: 3, top: 1, height: 20))
    XCTAssertNil(model.y(forSourceLine: 3))
  }

  func testClearingTheCursorRemovesTheBar() throws {
    var h = Harness(longDocument())
    h.run(h.model.applyEditorCursor(EditorCursor(line: 5, top: 1, height: 40)))
    let bar = try XCTUnwrap(h.model.overlay.sourceCursor)
    XCTAssertEqual(h.model.clearEditorCursor(), [.redraw(bar.insetBy(dx: -2, dy: -2))])
    XCTAssertNil(h.model.editorCursor)
    XCTAssertNil(h.model.overlay.sourceCursor)
    h.reload(longDocument() + "\n\nMore.")
    XCTAssertNil(h.model.overlay.sourceCursor, "a later layout does not bring it back")
  }

  func testADocumentChangeLeavesLiveBufferModeAndClearsTheCursor() {
    var h = Harness("See [other](other.md).\n\n" + longDocument(), files: ["/docs/other.md": "Other"])
    h.run(h.model.setLiveBuffer(true))
    h.run(h.model.applyEditorCursor(EditorCursor(line: 5, top: 1, height: 40)))
    XCTAssertNotNil(h.model.overlay.sourceCursor)
    h.run(h.model.setOffset(0))
    h.click(h.point(of: "other"))
    XCTAssertEqual(h.model.file?.lastPathComponent, "other.md")
    XCTAssertFalse(h.model.liveBuffer)
    XCTAssertNil(h.model.editorCursor)
    XCTAssertNil(h.model.overlay.sourceCursor)
    h.reload("Other, changed")
    XCTAssertNil(h.model.overlay.sourceCursor)
  }
}

final class EditorBadgeTests: XCTestCase {
  func testBadgeText() {
    var h = Harness(blocks)
    XCTAssertNil(h.model.status.editor)
    XCTAssertEqual(h.model.setEditorLink(neovim), [.redrawStatusBar])
    XCTAssertEqual(h.model.setEditorLink(neovim), [])
    XCTAssertEqual(h.model.status.editor, "Neovim: live")
    XCTAssertEqual(h.model.setLiveBuffer(true), [.redrawStatusBar])
    XCTAssertEqual(h.model.setLiveBuffer(true), [])
    XCTAssertEqual(h.model.status.editor, "Neovim: unsaved")
    h.run(h.model.setEditorLink(EditorLink(name: "Helix", syncsLive: false, followsShownFile: true)))
    XCTAssertEqual(h.model.status.editor, "Helix: on save")
    h.run(h.model.setEditorLink(nil))
    XCTAssertNil(h.model.status.editor)
  }

  func testTheEditModeIsHeldForHelp() {
    var h = Harness(blocks)
    XCTAssertEqual(h.model.editMode, .split)
    h.model.editMode = .here
    XCTAssertEqual(h.model.editMode, .here)
  }
}
