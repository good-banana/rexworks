import XCTest

@testable import MDViewerCore

final class VersionTests: XCTestCase {
  func testVersionIsSemantic() {
    XCTAssertNotNil(mdViewerVersion.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
  }
}
