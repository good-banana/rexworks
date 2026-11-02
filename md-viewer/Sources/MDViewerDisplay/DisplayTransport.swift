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

  public private(set) var viewport: DisplayViewport
  public private(set) var ledger: ImageLedger
  public private(set) var damage = FrameDamage()
  public private(set) var pacer: FramePacer
  public private(set) var debouncer: ResizeDebouncer
  public private(set) var stager: FrameStager
  public var relayout: (PaneSize, DisplayViewport) -> DisplayViewport
  public var onEvent: (DisplayEvent) -> Void = { _ in }
  public var shiftScrolling = true

  private let output: TerminalOutput
  private let source: FrameSource
  private var fallback: FrameStager?
  private var fences = FenceIDs()
  private var inFlightRecord: FrameRecord?
  private var failures: [UInt32: String] = [:]
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
    if shiftScrolling, ledger.displayed != nil {
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
    if response.id >= FenceIDs.base {
      guard let completed = pacer.acknowledge(response.id) else { return }
      complete(completed, at: now, timedOut: false)
    } else if !response.isOK {
      failures[response.id] = response.message
    }
  }

  public func nextWake(after now: UInt64) -> UInt64? {
    var wakes: [UInt64] = []
    if let deadline = debouncer.deadline { wakes.append(deadline) }
    if let inFlight = pacer.inFlight { wakes.append(inFlight.sentAt + pacer.fenceTimeout) }
    if !damage.isEmpty, !debouncer.isHolding, pacer.inFlight == nil { wakes.append(pacer.earliestSend(after: now)) }
    return wakes.min()
  }

  public func pump(at now: UInt64) {
    guard !isShutDown else { return }
    if case .settle(let size) = debouncer.fire(at: now) {
      viewport = relayout(size, viewport)
      damage.invalidateAll()
      onEvent(.settled(size))
    }
    if let expired = pacer.expire(at: now) { complete(expired, at: now, timedOut: true) }
    stager.reclaim(olderThan: now > Self.staleStagingNanoseconds ? now - Self.staleStagingNanoseconds : 0)
    guard !debouncer.isHolding, !damage.isEmpty, viewport.isDrawable, pacer.canSend(at: now) else { return }
    let plan = ledger.displayed == nil ? .full : damage.plan(in: viewport.frameRect)
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
    frameBitmap = nil
    patchBitmaps = [:]
    patchBitmapOrder = []
  }

  private func clock() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  private func sendFullFrame(at now: UInt64) {
    let width = viewport.frameWidth
    let height = viewport.frameHeight
    if frameBitmap?.width != width || frameBitmap?.height != height {
      frameBitmap = RasterBitmap(width: width, height: height)
    }
    guard let bitmap = frameBitmap else { return fail("could not allocate a \(width)x\(height) frame") }
    let started = clock()
    source.drawFrame(viewport, into: bitmap)
    let rendered = clock()
    guard let staged = stage(bitmap, at: now) else { return }
    let stagedAt = clock()
    let id = ledger.allocate()
    let fence = fences.allocate()
    output.write(
      Kitty.beginSynchronizedUpdate
        + Kitty.transmitRGBA(id: id, width: width, height: height, medium: staged.medium, quiet: .errorsOnly)
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
    dispatched(record, stagedThrough: staged.sequence, at: now)
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
    guard let id = ledger.displayed else { return sendFullFrame(at: now) }
    var commands = Kitty.beginSynchronizedUpdate
    if shift != 0 { commands += shiftCommands(id, by: shift) }
    var renderTime: UInt64 = 0
    var stageTime: UInt64 = 0
    var lastSequence: UInt64?
    var bytes = 0
    for rect in rects {
      guard let bitmap = patchBitmap(for: rect) else { return fail("could not allocate a \(rect) patch") }
      let started = clock()
      source.drawPatch(rect, viewport: viewport, into: bitmap)
      let rendered = clock()
      guard let staged = stage(bitmap, at: now) else { return }
      stageTime += clock() - rendered
      renderTime += rendered - started
      lastSequence = staged.sequence
      bytes += rect.area * 4
      commands += Kitty.editRootFrame(
        id: id, x: rect.x, y: rect.y, width: rect.width, height: rect.height, medium: staged.medium,
        quiet: .errorsOnly)
    }
    let fence = fences.allocate()
    let writeStarted = clock()
    output.write(commands + Kitty.endSynchronizedUpdate + Kitty.fence(id: fence))
    let record = FrameRecord(
      kind: shift == 0 ? .patch(rects) : .scroll(shift, rects), imageID: id, fence: fence,
      width: rects.map(\.width).max() ?? 0,
      height: rects.reduce(0) { $0 + $1.height }, bytes: bytes, renderNanoseconds: renderTime,
      stageNanoseconds: stageTime, writeNanoseconds: clock() - writeStarted, sentAt: now)
    dispatched(record, stagedThrough: lastSequence, at: now)
  }

  private func dispatched(_ record: FrameRecord, stagedThrough: UInt64?, at now: UInt64) {
    pacer.sent(fence: record.fence, stagedThrough: stagedThrough, at: now)
    inFlightRecord = record
    onEvent(.sent(record))
  }

  private func stage(_ bitmap: RasterBitmap, at now: UInt64) -> StagedFrame? {
    do {
      return try stager.stage(bitmap.bytes, at: now)
    } catch {
      guard let replacement = fallback else {
        fail(error.localizedDescription)
        return nil
      }
      onEvent(.failed("\(stager.name) staging failed (\(error.localizedDescription)); using \(replacement.name)"))
      useFallback()
      return stage(bitmap, at: now)
    }
  }

  private func useFallback() {
    guard let replacement = fallback else { return }
    stager.removeAll()
    stager = replacement
    fallback = nil
  }

  private func complete(_ completed: FramePacer.InFlight, at now: UInt64, timedOut: Bool) {
    if let sequence = completed.stagedThrough, !timedOut { stager.acknowledge(through: sequence) }
    guard let record = inFlightRecord, record.fence == completed.fence else { return }
    inFlightRecord = nil
    onEvent(timedOut ? .timedOut(record) : .acknowledged(record, latency: now - record.sentAt))
    let failure = failures.removeValue(forKey: record.imageID)
    failures = [:]
    switch (record.kind, failure) {
    case (.full, nil):
      let retired = ledger.confirm(record.imageID)
      if !retired.isEmpty {
        output.write(retired.map(Kitty.deleteImage).joined())
        onEvent(.retired(retired))
      }
    case (.full, let message?):
      ledger.discard(record.imageID)
      output.write(Kitty.deleteImage(id: record.imageID))
      recover(from: message)
    case (.patch, let message?):
      recover(from: message)
    case (.scroll, let message?):
      shiftScrolling = false
      recover(from: message)
    case (.patch, nil), (.scroll, nil):
      break
    }
  }

  private func recover(from message: String) {
    onEvent(.failed("terminal rejected a frame from \(stager.name): \(message)"))
    if !message.hasPrefix("ENOENT") { useFallback() }
    damage.invalidateAll()
  }

  private func fail(_ message: String) {
    damage.invalidateAll()
    onEvent(.failed(message))
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
