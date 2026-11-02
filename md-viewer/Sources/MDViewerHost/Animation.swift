import Foundation

public struct AnimationPlayer: Sendable {
  public static let minimumTickInterval: UInt64 = 33_333_334

  public struct Clip: Equatable, Sendable {
    public var delays: [TimeInterval]
    public var loopCount: Int

    public init(delays: [TimeInterval], loopCount: Int) {
      self.delays = delays
      self.loopCount = loopCount
    }
  }

  struct Track: Sendable {
    var clip: Clip
    var frame = 0
    var due: UInt64?
    var loopsDone = 0
    var finished = false
  }

  private var tracks: [String: Track] = [:]

  public init() {}

  public func frame(for source: String) -> Int { tracks[source]?.frame ?? 0 }

  public var nextDeadline: UInt64? { tracks.values.compactMap(\.due).min() }

  public var playing: Set<String> { Set(tracks.filter { $0.value.due != nil }.keys) }

  public mutating func show(_ visible: [String: Clip], at now: UInt64) {
    for (source, var track) in tracks where visible[source] == nil {
      track.due = nil
      tracks[source] = track
    }
    for (source, clip) in visible where clip.delays.count > 1 {
      var track = tracks[source] ?? Track(clip: clip)
      if track.clip != clip { track = Track(clip: clip) }
      if track.due == nil, !track.finished { track.due = now + Self.nanoseconds(clip.delays[track.frame]) }
      tracks[source] = track
    }
  }

  public mutating func advance(at now: UInt64) -> [String] {
    var changed: [String] = []
    for (source, var track) in tracks {
      guard let due = track.due, due <= now else { continue }
      let count = track.clip.delays.count
      var next = track.frame + 1
      if next == count {
        track.loopsDone += 1
        if track.clip.loopCount > 0, track.loopsDone >= track.clip.loopCount {
          track.finished = true
          track.due = nil
          tracks[source] = track
          continue
        }
        next = 0
      }
      track.frame = next
      track.due = now + Self.nanoseconds(track.clip.delays[next])
      tracks[source] = track
      changed.append(source)
    }
    return changed.sorted()
  }

  static func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(max(seconds, 0) * 1e9) }
}

public final class AnimationFrames: @unchecked Sendable {
  private let lock = NSLock()
  private var frames: [String: Int] = [:]

  public init() {}

  public func index(for source: String) -> Int { lock.withLock { frames[source] ?? 0 } }

  public func set(_ index: Int, for source: String) { lock.withLock { frames[source] = index } }
}
