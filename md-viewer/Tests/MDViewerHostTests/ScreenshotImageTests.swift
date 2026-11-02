import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerDisplay
import MDViewerInteraction
import XCTest

@testable import MDViewerHost

final class ScreenshotImageTests: XCTestCase {
  static let docs = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../docs").standardizedFileURL
  private let readme = docs.deletingLastPathComponent().appendingPathComponent("README.md")

  private func load(_ store: ImageStore, _ source: String) -> Bool {
    let done = expectation(description: source)
    let result = Flag()
    guard
      store.load(
        source, relativeTo: readme, queue: .global(),
        completion: { available in
          result.set(available)
          done.fulfill()
        })
    else {
      done.fulfill()
      wait(for: [done], timeout: 1)
      return false
    }
    wait(for: [done], timeout: 10)
    return result.value
  }

  func testAnUnknownPaneWidthNeverShrinksTheReadmeScreenshots() throws {
    let store = ImageStore()
    store.setDisplayWidth(0)
    store.setDisplayWidth(1)
    for name in ["preview-dark.png", "preview-light.png"] {
      XCTAssertTrue(load(store, "docs/\(name)"))
      let image = try XCTUnwrap(store.image(for: "docs/\(name)", relativeTo: readme))
      XCTAssertEqual(image.image.width, Int(image.size.width), "\(name) keeps its full width, not a 1 px smear")
    }
  }

  func testAScreenshotDecodedForANarrowPaneIsDecodedAgainWhenThePaneGrows() throws {
    let store = ImageStore()
    store.setDisplayWidth(400)
    XCTAssertTrue(load(store, "docs/preview-dark.png"))
    XCTAssertEqual(store.image(for: "docs/preview-dark.png", relativeTo: readme)?.image.width, 400)
    store.setDisplayWidth(300)
    XCTAssertFalse(load(store, "docs/preview-dark.png"), "a narrower pane keeps the sharper copy")
    store.setDisplayWidth(1200)
    XCTAssertTrue(load(store, "docs/preview-dark.png"))
    XCTAssertEqual(store.image(for: "docs/preview-dark.png", relativeTo: readme)?.image.width, 1200)
    store.setDisplayWidth(4000)
    XCTAssertTrue(load(store, "docs/preview-dark.png"))
    let full = try XCTUnwrap(store.image(for: "docs/preview-dark.png", relativeTo: readme))
    XCTAssertEqual(full.image.width, Int(full.size.width))
    XCTAssertFalse(load(store, "docs/preview-dark.png"), "a full-size copy is never decoded again")
  }
}

@MainActor
final class StartupImageWidthTests: XCTestCase {
  func testAViewerThatStartsBeforeThePaneHasPixelsStillShowsSharpImages() throws {
    let directory = try TestDirectory()
    let picture = ScreenshotImageTests.docs.appendingPathComponent("preview-dark.png").path
    let file = try directory.write("main.md", "<img src=\"\(picture)\" width=\"49%\">\n")
    let output = RecordingOutput()
    let images = ImageStore()
    let services = HostServices(
      output: output, pasteboard: FakePasteboard(), stagers: (MemoryStager(), nil),
      environment: InteractionEnvironment(openURL: { _ in true }, copyOnSelect: { false }), images: images,
      watchesFiles: false)
    let unsized = PaneSize(columns: 80, rows: 24, pixelWidth: 0, pixelHeight: 0)
    let host = ViewerHost(
      size: unsized, theme: ResolvedTheme(colors: TerminalColorSet(), source: .terminalQuery), services: services)
    host.start(file: file, windowSize: unsized)
    host.receive(Array("\u{1b}[48;50;100;1700;1600t".utf8))
    spin(until: { host.interaction.layout?.images.first?.hasIntrinsicSize == true })
    let image = try XCTUnwrap(images.image(for: picture, relativeTo: file))
    XCTAssertGreaterThanOrEqual(image.image.width, 1500, "decoded for the real pane, not a 0 px one")
    host.shutdown()
  }
}
