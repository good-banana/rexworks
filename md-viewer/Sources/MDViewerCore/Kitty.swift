import CoreGraphics
import Foundation

public enum Kitty {
  private static let start = "\u{1b}_G"
  private static let end = "\u{1b}\\"

  public static func transmitFile(id: UInt32, path: String) -> String {
    let payload = Data(path.utf8).base64EncodedString()
    return "\(start)a=t,f=100,t=t,i=\(id),q=2;\(payload)\(end)"
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

  public static func deletePlacements(id: UInt32) -> String {
    "\(start)a=d,d=i,i=\(id),q=2\(end)"
  }

  public static func deleteAll() -> String {
    "\(start)a=d,d=A,q=2\(end)"
  }
}
