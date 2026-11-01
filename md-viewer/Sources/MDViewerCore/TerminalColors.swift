import Foundation

public func parseColorReply(_ s: String) -> (r: Double, g: Double, b: Double)? {
  guard let marker = s.range(of: "rgb:") else { return nil }
  let body = s[marker.upperBound...].prefix { $0 != "\u{1b}" && $0 != "\u{07}" }
  let parts = body.split(separator: "/", omittingEmptySubsequences: false)
  guard parts.count == 3 else { return nil }
  var values: [Double] = []
  for part in parts {
    guard (1...4).contains(part.count), let raw = UInt32(part, radix: 16) else { return nil }
    let maximum = Double((1 << (4 * part.count)) - 1)
    values.append(Double(raw) / maximum)
  }
  return (values[0], values[1], values[2])
}

public func isDark(_ rgb: (r: Double, g: Double, b: Double)) -> Bool {
  0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b < 0.5
}
