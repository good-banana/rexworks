import AVFoundation
import UniformTypeIdentifiers

public enum VideoPoster {
  private static let frameTime = CMTime(seconds: 0.5, preferredTimescale: 600)
  private static let maximumSize = CGSize(width: 1280, height: 720)

  public static func dataURL(for url: URL, timeout: Duration = .seconds(3)) async throws -> String {
    nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = maximumSize
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    let image = try await withThrowingTaskGroup(of: CGImage.self) { group in
      group.addTask { try await generator.image(at: frameTime).image }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw WebRendererError.posterTimedOut
      }
      defer {
        group.cancelAll()
        generator.cancelAllCGImageGeneration()
      }
      guard let first = try await group.next() else { throw WebRendererError.posterTimedOut }
      return first
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw WebRendererError.posterEncodingFailed }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw WebRendererError.posterEncodingFailed }
    return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
  }
}
