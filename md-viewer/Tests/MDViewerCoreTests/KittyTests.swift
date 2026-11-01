import CoreGraphics
import XCTest

@testable import MDViewerCore

final class KittyTests: XCTestCase {
  func testTransmitFileEncodesPathBase64() {
    let s = Kitty.transmitFile(id: 7, path: "/tmp/t/1.png")
    XCTAssertEqual(
      s,
      "\u{1b}_Ga=t,f=100,t=t,i=7,q=2;\(Data("/tmp/t/1.png".utf8).base64EncodedString())\u{1b}\\")
  }

  func testPlaceWithCrop() {
    let s = Kitty.place(
      id: 7, placement: 1, source: CGRect(x: 0, y: 120, width: 800, height: 400), columns: 80,
      rows: 20, z: 0)
    XCTAssertEqual(
      s, "\u{1b}_Ga=p,i=7,p=1,x=0,y=120,w=800,h=400,c=80,r=20,z=0,C=1,q=2\u{1b}\\")
  }

  func testDeleteSequences() {
    XCTAssertEqual(Kitty.deletePlacements(id: 7), "\u{1b}_Ga=d,d=i,i=7,q=2\u{1b}\\")
    XCTAssertEqual(Kitty.deleteAll(), "\u{1b}_Ga=d,d=A,q=2\u{1b}\\")
  }
}
