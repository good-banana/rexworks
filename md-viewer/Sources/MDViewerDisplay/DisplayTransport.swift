import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerRender

public protocol TerminalOutput: AnyObject {
  func write(_ text: String)
}

public protocol FrameSource: AnyObject {
  func drawFrame(_ viewport: DisplayViewport, into bitmap: RasterBitmap)
  func drawPatch(_ rect: PixelRect, viewport: DisplayViewport, into bitmap: RasterBitmap)
}

public struct FrameRecord: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case full
    case patch([PixelRect])
    case scroll(Int, [PixelRect])
  }

  public var kind: Kind
  public var imageID: UInt32
  public var fence: UInt32
  public var width: Int
  public var height: Int
  public var bytes: Int
  public var renderNanoseconds: UInt64
  public var stageNanoseconds: UInt64
  public var writeNanoseconds: UInt64
  public var sentAt: UInt64
}

public enum DisplayEvent: Equatable, Sendable {
  case sent(FrameRecord)
  case acknowledged(FrameRecord, latency: UInt64)
  case timedOut(FrameRecord)
  case holding(PaneSize)
  case settled(PaneSize)
  case retired([UInt32])
  case failed(String)
}

public final class DisplayTransport {
  public static let staleStagingNanoseconds: UInt64 = 10_000_000_000
  public static let placement: UInt32 = 1
  public static let maximumUnsettledFrames = 2
  public static let retryBaseNanoseconds: UInt64 = 50_000_000
  public static let retryCapNanoseconds: UInt64 = 2_000_000_000
  public static let maximumConsecutiveFailures = 6

  public private(set) var viewport: DisplayViewport
  public private(set) var ledger: ImageLedger
  public private(set) var damage = FrameDamage()
  public private(set) var pacer: FramePacer
  public private(set) var debouncer: ResizeDebouncer
  public private(set) var stager: FrameStager
  public private(set) var patchesEnabled = true
  public private(set) var consecutiveFailures = 0
  public private(set) var retryAfter: UInt64?
  public private(set) var isStopped = false
  public var relayout: (PaneSize, DisplayViewport) -> DisplayViewport
  public var onEvent: (DisplayEvent) -> Void = { _ in }
  public var shiftScrolling = true

  private struct Outstanding {
    var record: FrameRecord
    var stagedThrough: UInt64?
    var stager: FrameStager
  }

  private let output: TerminalOutput
  private let source: FrameSource
  private var fallback: FrameStager?
  private var fences = FenceIDs()
  private var outstanding: [Outstanding] = []
  private var failures: [UInt32: String] = [:]
  private var lastTimedOutSentAt: UInt64?
  private var frameBitmap: RasterBitmap?
  private var patchBitmaps: [PixelRect: RasterBitmap] = [:]
  private var patchBitmapOrder: [PixelRect] = []
  private var isShutDown = false
  private var scratchFrameImage: UInt32?

  public init(
    viewport: DisplayViewport, output: TerminalOutput, source: FrameSource, stager: FrameStager,
    fallback: FrameStager? = nil, firstImageID: UInt32 = ImageLedger.firstID(processID: getpid()),
    pacer: FramePacer = FramePacer(),
    settleNanoseconds: UInt64 = ResizeDebouncer.defaultSettleNanoseconds,
    relayout: @escaping (PaneSize, DisplayViewport) -> DisplayViewport
  ) {
    self.viewport = viewport
    self.output = output
    self.source = source
    self.stager = stager
    self.fallback = fallback
    self.pacer = pacer
    self.relayout = relayout
    ledger = ImageLedger(firstID: firstImageID)
    debouncer = ResizeDebouncer(displayed: viewport.size, settleNanoseconds: settleNanoseconds)
    damage.invalidateAll()
  }

  public var isHolding: Bool { debouncer.isHolding }
  public var outstandingFrames: Int { outstanding.count }

  public func invalidateAll() {
    damage.invalidateAll()
  }

  public func invalidate(page rect: CGRect) {
    guard let pane = viewport.paneRect(fromPage: rect) else { return }
    damage.invalidate(pane)
  }

  public func invalidate(pane rect: PixelRect) {
    guard let clipped = rect.intersection(viewport.frameRect) else { return }
    damage.invalidate(clipped)
  }

  public func invalidateStatusBar() {
    invalidate(pane: viewport.statusBarRect)
  }

  @discardableResult
  public func scroll(to offset: CGFloat) -> Bool {
    let previous = viewport.offset
    guard viewport.scroll(to: offset) else { return false }
    if shiftScrolling, patchesEnabled, ledger.newest != nil {
      damage.scroll(
        by: Int((viewport.offset - previous).rounded()), content: viewport.contentRect,
        statusBar: viewport.statusBarRect)
    } else {
      damage.invalidateAll()
    }
    return true
  }

  @discardableResult
  public func scroll(by delta: CGFloat) -> Bool {
    scroll(to: viewport.offset + delta)
  }

  @discardableResult
  public func scroll(rows: Int) -> Bool {
    scroll(by: CGFloat(rows * viewport.cellHeight))
  }

  public func replaceViewport(_ viewport: DisplayViewport) {
    self.viewport = viewport
    damage.invalidateAll()
  }

  public func resume() {
    isStopped = false
    consecutiveFailures = 0
    retryAfter = nil
    damage.invalidateAll()
  }

  public func observe(_ size: PaneSize, at now: UInt64) {
    guard !isShutDown, size.hasPixels else { return }
    guard !ledger.live.isEmpty else {
      guard size != viewport.size || debouncer.isHolding else { return }
      debouncer.reset(displayed: size)
      viewport = relayout(size, viewport)
      damage.invalidateAll()
      onEvent(.settled(size))
      return
    }
    if debouncer.observe(size, at: now) == .hold { onEvent(.holding(size)) }
  }

  public func handle(_ response: GraphicsResponse, at now: UInt64) {
    guard !isShutDown else { return }
    if response.id >= FenceIDs.base {
      settle(through: response.id, at: now)
      return
    }
    guard !response.isOK, ledger.live.contains(response.id) else { return }
    failures[response.id] = response.message
    let editedSinceTransmit = outstanding.contains {
      $0.record.imageID == response.id && $0.record.kind != .full
    }
    if ledger.unsettled.contains(response.id), !editedSinceTransmit {
      ledger.discard(response.id)
      output.write(Kitty.deleteImage(id: response.id))
    }
    damage.invalidateAll()
  }

  public func nextWake(after now: UInt64) -> UInt64? {
    var wakes: [UInt64] = []
    if let deadline = debouncer.deadline { wakes.append(deadline) }
    if let inFlight = pacer.inFlight { wakes.append(inFlight.sentAt + pacer.fenceTimeout) }
    if canSendSoon, let plan = nextPlan(), plan != .none, !isBlocked(plan) {
      wakes.append(max(pacer.earliestSend(after: now), retryAfter ?? 0))
    }
    return wakes.min()
  }

  public func pump(at now: UInt64) {
    guard !isShutDown else { return }
    if case .settle(let size) = debouncer.fire(at: now) {
      viewport = relayout(size, viewport)
      damage.invalidateAll()
      onEvent(.settled(size))
    }
    if let expired = pacer.expire(at: now) { timedOut(expired, at: now) }
    if let cutoff = lastTimedOutSentAt, now > Self.staleStagingNanoseconds {
      stager.reclaim(olderThan: min(cutoff + 1, now - Self.staleStagingNanoseconds))
    }
    guard canSendSoon, pacer.canSend(at: now), now >= retryAfter ?? 0, let plan = nextPlan(), !isBlocked(plan)
    else { return }
    damage.reset()
    switch plan {
    case .none: break
    case .full: sendFullFrame(at: now)
    case .patches(let rects): sendPatches(rects, shift: 0, at: now)
    case .scroll(let shift, let rects): sendPatches(rects, shift: shift, at: now)
    }
  }

  public func shutdown() {
    guard !isShutDown else { return }
    isShutDown = true
    let ids = ledger.removeAll()
    if !ids.isEmpty { output.write(ids.map(Kitty.deleteImage).joined()) }
    stager.removeAll()
    fallback?.removeAll()
    outstanding = []
    failures = [:]
    frameBitmap = nil
    patchBitmaps = [:]
    patchBitmapOrder = []
  }

  private var canSendSoon: Bool {
    !isStopped && !debouncer.isHolding && !damage.isEmpty && viewport.isDrawable && pacer.inFlight == nil
  }

  private func nextPlan() -> FramePlan? {
    guard ledger.newest != nil else { return .full }
    let plan = damage.plan(in: viewport.frameRect)
    switch plan {
    case .patches, .scroll: return patchesEnabled ? plan : .full
    case .none, .full: return plan
    }
  }

  private func isBlocked(_ plan: FramePlan) -> Bool {
    plan == .full && ledger.unsettled.count >= Self.maximumUnsettledFrames
  }

  private func clock() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  private func sendFullFrame(at now: UInt64) {
    let width = viewport.frameWidth
    let height = viewport.frameHeight
    if frameBitmap?.width != width || frameBitmap?.height != height {
      frameBitmap = RasterBitmap(width: width, height: height)
    }
    guard let bitmap = frameBitmap else { return fail("could not allocate a \(width)x\(height) frame", at: now) }
    let started = clock()
    source.drawFrame(viewport, into: bitmap)
    let rendered = clock()
    guard let staged = stage(bitmap, at: now) else { return }
    let stagedAt = clock()
    let id = ledger.allocate()
    let fence = fences.allocate()
    output.write(
      Kitty.beginSynchronizedUpdate
        + Kitty.transmitRGBA(id: id, width: width, height: height, medium: staged.frame.medium, quiet: .errorsOnly)
        + "\u{1b}[1;1H"
        + Kitty.place(
          id: id, placement: Self.placement, columns: viewport.size.columns, rows: viewport.size.rows,
          quiet: .errorsOnly)
        + Kitty.endSynchronizedUpdate + Kitty.fence(id: fence))
    let written = clock()
    let record = FrameRecord(
      kind: .full, imageID: id, fence: fence, width: width, height: height, bytes: width * height * 4,
      renderNanoseconds: rendered - started, stageNanoseconds: stagedAt - rendered,
      writeNanoseconds: written - stagedAt, sentAt: now)
    dispatched(record, stagedThrough: staged.frame.sequence, at: now)
  }

  private func shiftCommands(_ id: UInt32, by shift: Int) -> String {
    let content = viewport.contentRect
    let height = content.height - abs(shift)
    var commands = ""
    if scratchFrameImage != id {
      commands += Kitty.createScratchFrame(id: id, quiet: .errorsOnly)
      scratchFrameImage = id
    }
    let kept = (x: content.x, y: shift > 0 ? content.y + shift : content.y)
    let moved = (x: content.x, y: shift > 0 ? content.y : content.y - shift)
    commands += Kitty.composeFrame(
      id: id, from: 1, to: 2, sourceOrigin: kept, destinationOrigin: kept, width: content.width, height: height,
      quiet: .errorsOnly)
    commands += Kitty.composeFrame(
      id: id, from: 2, to: 1, sourceOrigin: kept, destinationOrigin: moved, width: content.width, height: height,
      quiet: .errorsOnly)
    return commands
  }

  private func sendPatches(_ rects: [PixelRect], shift: Int, at now: UInt64) {
    guard let id = ledger.newest else { return sendFullFrame(at: now) }
    batch: while true {
      var edits = ""
      var renderTime: UInt64 = 0
      var stageTime: UInt64 = 0
      var lastSequence: UInt64?
      var bytes = 0
      for rect in rects {
        guard let bitmap = patchBitmap(for: rect) else {
          return fail("could not allocate a \(rect) patch", at: now)
        }
        let started = clock()
        source.drawPatch(rect, viewport: viewport, into: bitmap)
        let rendered = clock()
        guard let staged = stage(bitmap, at: now) else { return }
        if staged.switchedMedium, !edits.isEmpty { continue batch }
        stageTime += clock() - rendered
        renderTime += rendered - started
        lastSequence = staged.frame.sequence
        bytes += rect.area * 4
        edits += Kitty.editRootFrame(
          id: id, x: rect.x, y: rect.y, width: rect.width, height: rect.height, medium: staged.frame.medium,
          quiet: .errorsOnly)
      }
      let fence = fences.allocate()
      let writeStarted = clock()
      output.write(
        Kitty.beginSynchronizedUpdate + (shift == 0 ? "" : shiftCommands(id, by: shift)) + edits
          + Kitty.endSynchronizedUpdate + Kitty.fence(id: fence))
      let record = FrameRecord(
        kind: shift == 0 ? .patch(rects) : .scroll(shift, rects), imageID: id, fence: fence,
        width: rects.map(\.width).max() ?? 0,
        height: rects.reduce(0) { $0 + $1.height }, bytes: bytes, renderNanoseconds: renderTime,
        stageNanoseconds: stageTime, writeNanoseconds: clock() - writeStarted, sentAt: now)
      return dispatched(record, stagedThrough: lastSequence, at: now)
    }
  }

  private func dispatched(_ record: FrameRecord, stagedThrough: UInt64?, at now: UInt64) {
    pacer.sent(fence: record.fence, stagedThrough: stagedThrough, at: now)
    outstanding.append(Outstanding(record: record, stagedThrough: stagedThrough, stager: stager))
    onEvent(.sent(record))
  }

  private func stage(_ bitmap: RasterBitmap, at now: UInt64) -> (frame: StagedFrame, switchedMedium: Bool)? {
    do {
      return (try stager.stage(bitmap.bytes, at: now), false)
    } catch {
      guard let replacement = fallback else {
        fail(error.localizedDescription, at: now)
        return nil
      }
      onEvent(.failed("\(stager.name) staging failed (\(error.localizedDescription)); using \(replacement.name)"))
      useFallback()
      guard let staged = stage(bitmap, at: now) else { return nil }
      return (staged.frame, true)
    }
  }

  private func useFallback() {
    guard let replacement = fallback else { return }
    stager.removeAll()
    stager = replacement
    fallback = nil
  }

  private func timedOut(_ expired: FramePacer.InFlight, at now: UInt64) {
    lastTimedOutSentAt = expired.sentAt
    if let entry = outstanding.first(where: { $0.record.fence == expired.fence }) {
      onEvent(.timedOut(entry.record))
    }
    registerFailure(at: now)
    if ledger.unsettled.count >= Self.maximumUnsettledFrames, !isStopped {
      isStopped = true
      onEvent(.failed("stopped drawing: the terminal is not answering"))
    }
  }

  private func settle(through fence: UInt32, at now: UInt64) {
    guard let index = outstanding.firstIndex(where: { $0.record.fence == fence }) else { return }
    if pacer.inFlight?.fence == fence { _ = pacer.acknowledge(fence) }
    let settled = outstanding[...index]
    outstanding.removeFirst(index + 1)
    for entry in settled {
      if let sequence = entry.stagedThrough { entry.stager.acknowledge(through: sequence) }
      onEvent(.acknowledged(entry.record, latency: now - entry.record.sentAt))
      settle(entry.record, failure: failures.removeValue(forKey: entry.record.imageID), at: now)
    }
    failures = failures.filter { ledger.live.contains($0.key) }
    if outstanding.isEmpty { lastTimedOutSentAt = nil }
  }

  private func settle(_ record: FrameRecord, failure: String?, at now: UInt64) {
    switch (record.kind, failure) {
    case (.full, nil) where ledger.live.contains(record.imageID):
      let retired = ledger.confirm(record.imageID)
      if !retired.isEmpty {
        output.write(retired.map(Kitty.deleteImage).joined())
        onEvent(.retired(retired))
      }
      succeeded()
    case (.full, nil):
      break
    case (.full, let message?):
      if ledger.unsettled.contains(record.imageID) {
        ledger.discard(record.imageID)
        output.write(Kitty.deleteImage(id: record.imageID))
      }
      rejected(message, at: now)
    case (.patch, let message?):
      if !message.hasPrefix("ENOENT"), !Self.isLoadError(message) { patchesEnabled = false }
      rejected(message, at: now)
    case (.scroll, let message?):
      shiftScrolling = false
      rejected(message, at: now)
    case (.patch, nil), (.scroll, nil):
      succeeded()
    }
  }

  static func isLoadError(_ message: String) -> Bool {
    [
      "EINVAL: invalid data", "EINVAL: unsupported medium", "ENODATA", "EINVAL: temporary file",
      "EINVAL: file path too long",
    ].contains { message.hasPrefix($0) }
  }

  private func rejected(_ message: String, at now: UInt64) {
    onEvent(.failed("terminal rejected a frame from \(stager.name): \(message)"))
    if Self.isLoadError(message) { useFallback() }
    damage.invalidateAll()
    registerFailure(at: now)
  }

  private func succeeded() {
    consecutiveFailures = 0
    retryAfter = nil
    isStopped = false
  }

  private func fail(_ message: String, at now: UInt64) {
    damage.invalidateAll()
    onEvent(.failed(message))
    registerFailure(at: now)
  }

  private func registerFailure(at now: UInt64) {
    consecutiveFailures += 1
    if consecutiveFailures >= Self.maximumConsecutiveFailures {
      if !isStopped {
        isStopped = true
        onEvent(.failed("stopped drawing after \(consecutiveFailures) consecutive failures"))
      }
      return
    }
    let delay = Self.retryBaseNanoseconds << UInt64(consecutiveFailures - 1)
    retryAfter = now + min(delay, Self.retryCapNanoseconds)
  }

  private func patchBitmap(for rect: PixelRect) -> RasterBitmap? {
    let key = PixelRect(x: 0, y: 0, width: rect.width, height: rect.height)
    if let cached = patchBitmaps[key] {
      patchBitmapOrder.removeAll { $0 == key }
      patchBitmapOrder.append(key)
      return cached
    }
    guard let bitmap = RasterBitmap(width: rect.width, height: rect.height) else { return nil }
    patchBitmaps[key] = bitmap
    patchBitmapOrder.append(key)
    if patchBitmapOrder.count > 4 { patchBitmaps.removeValue(forKey: patchBitmapOrder.removeFirst()) }
    return bitmap
  }
}
