import XCTest

@testable import MDViewerCore

final class KittyTests: XCTestCase {
  func testDeleteSequences() {
    XCTAssertEqual(Kitty.deleteAll(), "\u{1b}_Ga=d,d=A,q=2\u{1b}\\")
    XCTAssertEqual(Kitty.deleteImage(id: 7), "\u{1b}_Ga=d,d=I,i=7,q=2\u{1b}\\")
  }

  func testTransmitRGBAFromTemporaryFile() {
    let path = "/tmp/tty-graphics-protocol-x/1.rgba"
    XCTAssertEqual(
      Kitty.transmitRGBA(id: 65537, width: 1600, height: 1400, medium: .temporaryFile(path), quiet: .errorsOnly),
      "\u{1b}_Ga=t,f=32,s=1600,v=1400,t=t,i=65537,q=1;\(Data(path.utf8).base64EncodedString())\u{1b}\\")
  }

  func testTransmitRGBAFromSharedMemory() {
    XCTAssertEqual(
      Kitty.transmitRGBA(id: 9, width: 2, height: 3, medium: .sharedMemory("/mdv1-4"), quiet: .none),
      "\u{1b}_Ga=t,f=32,s=2,v=3,t=s,i=9,q=2;L21kdjEtNA==\u{1b}\\")
  }

  func testPlaceCoveringCells() {
    XCTAssertEqual(
      Kitty.place(id: 9, placement: 1, columns: 80, rows: 24, quiet: .errorsOnly),
      "\u{1b}_Ga=p,i=9,p=1,c=80,r=24,C=1,q=1\u{1b}\\")
  }

  func testEditRootFrame() {
    XCTAssertEqual(
      Kitty.editRootFrame(
        id: 9, x: 10, y: 1340, width: 1600, height: 60, medium: .sharedMemory("/mdv1-4"), quiet: .errorsOnly),
      "\u{1b}_Ga=f,r=1,i=9,x=10,y=1340,s=1600,v=60,f=32,t=s,X=1,q=1;L21kdjEtNA==\u{1b}\\")
  }

  func testFenceAndSynchronizedUpdate() {
    XCTAssertEqual(Kitty.fence(id: 2_147_483_648), "\u{1b}_Ga=q,i=2147483648,s=1,v=1,f=32,t=d;AAAAAA==\u{1b}\\")
    XCTAssertEqual(Kitty.beginSynchronizedUpdate, "\u{1b}[?2026h")
    XCTAssertEqual(Kitty.endSynchronizedUpdate, "\u{1b}[?2026l")
  }

  func testGraphicsResponsePayloads() {
    XCTAssertEqual(GraphicsResponse(payload: "Gi=7;OK"), GraphicsResponse(id: 7, message: "OK"))
    XCTAssertEqual(
      GraphicsResponse(payload: "Gi=100,r=1;ENOENT: image not found"),
      GraphicsResponse(id: 100, message: "ENOENT: image not found"))
    XCTAssertTrue(GraphicsResponse(id: 1, message: "OK").isOK)
    XCTAssertFalse(GraphicsResponse(id: 1, message: "EINVAL: bad").isOK)
    XCTAssertNil(GraphicsResponse(payload: "Gr=1;OK"))
    XCTAssertNil(GraphicsResponse(payload: "Gi=1"))
    XCTAssertNil(GraphicsResponse(payload: "Xi=1;OK"))
  }

  func testScratchFrameAndCompose() {
    XCTAssertEqual(
      Kitty.createScratchFrame(id: 9, quiet: .errorsOnly),
      "\u{1b}_Ga=f,i=9,c=1,z=-1,s=1,v=1,f=32,t=d,X=1,q=1;AAAAAA==\u{1b}\\")
    XCTAssertEqual(
      Kitty.composeFrame(
        id: 9, from: 2, to: 1, sourceOrigin: (0, 99), destinationOrigin: (0, 0), width: 1498, height: 825,
        quiet: .errorsOnly),
      "\u{1b}_Ga=c,i=9,r=2,c=1,x=0,y=0,X=0,Y=99,w=1498,h=825,C=1,q=1\u{1b}\\")
  }
}
