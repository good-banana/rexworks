import Foundation
import MDViewerCore
import XCTest

@testable import MDViewerHost

@MainActor
final class ViewerControlTests: XCTestCase {
  private func socketPath() throws -> (directory: URL, socket: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(String(UUID().uuidString.prefix(8)))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("v.sock"))
  }

  func testTheSocketAnswersWhileTheFirstLayoutIsStillRunning() throws {
    let (directory, socket) = try socketPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = URL(fileURLWithPath: "/docs/requested.md")
    let control = ViewerControl()
    let server = try control.listen(
      on: socket, status: ViewerStatus(file: file, opener: "block:caller", openedAt: 3))
    defer { server.close() }
    let answered = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var probe = PreviewProbe.unreachable
    DispatchQueue.global().async {
      probe = ViewerSocketClient.query(socket)
      answered.signal()
    }
    XCTAssertEqual(answered.wait(timeout: .now() + 3), .success, "the main thread stays busy, as during layout")
    XCTAssertEqual(probe, .answered(ViewerState(file: file.path, openedAt: 3, opener: "block:caller")))
  }

  func testOpensAndThemeChangesDuringStartupAreAppliedOnceTheHostExists() throws {
    let (directory, socket) = try socketPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = try HostFixture("# Main", files: ["other.md": "# Other"], start: false)
    let other = fixture.directory.url.appendingPathComponent("other.md")
    let status = ViewerStatus(file: fixture.file, opener: nil)
    let control = ViewerControl()
    let server = try control.listen(on: socket, status: status)
    defer { server.close() }
    XCTAssertTrue(ViewerSocketClient.send(path: other.path, to: socket))
    XCTAssertTrue(ViewerSocketClient.sendTheme(to: socket))
    spin(until: { !control.pendingOpens.isEmpty && control.pendingTheme })
    XCTAssertEqual(control.pendingOpens, [other])

    var shown: [String] = []
    fixture.host.onDocumentShown = {
      status.show($0)
      shown.append($0.lastPathComponent)
    }
    fixture.host.start(file: fixture.file, windowSize: testPaneSize)
    _ = fixture.output.take()
    control.attach(fixture.host)
    XCTAssertEqual(shown, ["main.md", "other.md"])
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "other.md")
    XCTAssertEqual(status.state.file, other.path)
    XCTAssertTrue(control.pendingOpens.isEmpty)
    XCTAssertFalse(control.pendingTheme)
    spin(until: { fixture.output.joined.contains(TerminalColorQuery.primaryDeviceAttributes) }, timeout: 1)
    XCTAssertTrue(
      fixture.output.joined.contains(TerminalColorQuery.primaryDeviceAttributes),
      "the queued theme change was requested")

    let third = try fixture.directory.write("third.md", "# Third")
    XCTAssertTrue(ViewerSocketClient.send(path: third.path, to: socket))
    spin(until: { fixture.host.interaction.file?.lastPathComponent == "third.md" })
    XCTAssertEqual(fixture.host.interaction.file?.lastPathComponent, "third.md")
  }
}
