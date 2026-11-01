import XCTest

@testable import MDViewerWeb

final class ResourceTests: XCTestCase {
  func testWebResourceDirectoryIsBundled() {
    XCTAssertNotNil(WebRenderer.resourceBundle.url(forResource: "web", withExtension: nil))
  }
}
