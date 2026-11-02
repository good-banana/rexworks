import CoreGraphics
import Foundation

public enum Kitty {
  private static let start = "\u{1b}_G"
  private static let end = "\u{1b}\\"

  public enum Medium: Equatable, Sendable {
    case temporaryFile(String)
    case sharedMemory(String)

    var key: String {
      switch self {
      case .temporaryFile: "t"
      case .sharedMemory: "s"
      }
    }

    var payload: String {
      switch self {
      case .temporaryFile(let path), .sharedMemory(let path): Data(path.utf8).base64EncodedString()
      }
    }
  }

  public enum Quiet: Int, Sendable {
    case all = 0
    case errorsOnly = 1
    case none = 2
  }

  public static let beginSynchronizedUpdate = "\u{1b}[?2026h"
  public static let endSynchronizedUpdate = "\u{1b}[?2026l"

  public static func transmitFile(id: UInt32, path: String) -> String {
    let payload = Data(path.utf8).base64EncodedString()
    return "\(start)a=t,f=100,t=t,i=\(id),q=2;\(payload)\(end)"
  }

  public static func transmitRGBA(id: UInt32, width: Int, height: Int, medium: Medium, quiet: Quiet) -> String {
    "\(start)a=t,f=32,s=\(width),v=\(height),t=\(medium.key),i=\(id),q=\(quiet.rawValue);\(medium.payload)\(end)"
  }

  public static func place(
    id: UInt32, placement: UInt32, source: CGRect, columns: Int, rows: Int, z: Int
  ) -> String {
    let x = Int(source.origin.x.rounded())
    let y = Int(source.origin.y.rounded())
    let w = Int(source.size.width.rounded())
    let h = Int(source.size.height.rounded())
    return
      "\(start)a=p,i=\(id),p=\(placement),x=\(x),y=\(y),w=\(w),h=\(h),c=\(columns),r=\(rows),z=\(z),C=1,q=2\(end)"
  }

  public static func place(id: UInt32, placement: UInt32, columns: Int, rows: Int, quiet: Quiet) -> String {
    "\(start)a=p,i=\(id),p=\(placement),c=\(columns),r=\(rows),C=1,q=\(quiet.rawValue)\(end)"
  }

  public static func editRootFrame(
    id: UInt32, x: Int, y: Int, width: Int, height: Int, medium: Medium, quiet: Quiet
  ) -> String {
    "\(start)a=f,r=1,i=\(id),x=\(x),y=\(y),s=\(width),v=\(height),f=32,t=\(medium.key),X=1,q=\(quiet.rawValue);"
      + "\(medium.payload)\(end)"
  }

  public static func createScratchFrame(id: UInt32, quiet: Quiet) -> String {
    "\(start)a=f,i=\(id),c=1,z=-1,s=1,v=1,f=32,t=d,X=1,q=\(quiet.rawValue);AAAAAA==\(end)"
  }

  public static func composeFrame(
    id: UInt32, from source: Int, to destination: Int, sourceOrigin: (x: Int, y: Int),
    destinationOrigin: (x: Int, y: Int), width: Int, height: Int, quiet: Quiet
  ) -> String {
    "\(start)a=c,i=\(id),r=\(source),c=\(destination),x=\(destinationOrigin.x),y=\(destinationOrigin.y),"
      + "X=\(sourceOrigin.x),Y=\(sourceOrigin.y),w=\(width),h=\(height),C=1,q=\(quiet.rawValue)\(end)"
  }

  public static func fence(id: UInt32) -> String {
    "\(start)a=q,i=\(id),s=1,v=1,f=32,t=d;AAAAAA==\(end)"
  }

  public static func deletePlacements(id: UInt32) -> String {
    "\(start)a=d,d=i,i=\(id),q=2\(end)"
  }

  public static func deleteImage(id: UInt32) -> String {
    "\(start)a=d,d=I,i=\(id),q=2\(end)"
  }

  public static func deleteAll() -> String {
    "\(start)a=d,d=A,q=2\(end)"
  }
}

public struct GraphicsResponse: Equatable, Sendable {
  public var id: UInt32
  public var message: String

  public init(id: UInt32, message: String) {
    self.id = id
    self.message = message
  }

  public var isOK: Bool { message == "OK" }

  init?(payload: String) {
    guard payload.hasPrefix("G"), let separator = payload.firstIndex(of: ";") else { return nil }
    let keys = payload[payload.index(after: payload.startIndex)..<separator]
    var id: UInt32?
    for pair in keys.split(separator: ",") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      if parts.count == 2, parts[0] == "i" { id = UInt32(parts[1]) }
    }
    guard let id else { return nil }
    self.init(id: id, message: String(payload[payload.index(after: separator)...]))
  }
}
