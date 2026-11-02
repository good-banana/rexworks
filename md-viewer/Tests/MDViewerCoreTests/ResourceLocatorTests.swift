import Foundation
import XCTest

@testable import MDViewerCore

final class ResourceLocatorTests: XCTestCase {
  func testDevelopmentLayoutSearchesNextToTheExecutable() {
    let executable = URL(fileURLWithPath: "/work/md-viewer/.build/debug/md-viewer")
    let anchor = URL(fileURLWithPath: "/anchor")
    XCTAssertEqual(
      ResourceLocator.directories(executable: executable, anchors: [anchor]).map(\.path),
      ["/anchor", "/work/md-viewer/.build/debug", "/work/md-viewer/.build/libexec"])
  }

  func testHomebrewLayoutFollowsTheBinSymlinkToLibexec() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let keg = root.appendingPathComponent("Cellar/md-viewer/0.2.0")
    try FileManager.default.createDirectory(at: keg.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let binary = keg.appendingPathComponent("bin/md-viewer")
    try Data().write(to: binary)
    let link = root.appendingPathComponent("bin/md-viewer")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
    let directories = ResourceLocator.directories(executable: link, anchors: []).map(\.path)
    XCTAssertEqual(directories, [keg.appendingPathComponent("bin").path, keg.appendingPathComponent("libexec").path])
  }
}
