import AVFoundation
import UniformTypeIdentifiers

public enum VideoPoster {
  private static let frameTime = CMTime(seconds: 0.5, preferredTimescale: 600)
  private static let maximumSize = CGSize(width: 1280, height: 720)

  public static func dataURL(for url: URL) async throws -> String {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximumSize
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    let image = try await generator.image(at: frameTime).image
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw WebRendererError.posterEncodingFailed }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw WebRendererError.posterEncodingFailed }
    return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
  }
}
