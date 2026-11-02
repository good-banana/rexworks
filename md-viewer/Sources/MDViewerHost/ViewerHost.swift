import CoreGraphics
import Foundation
import MDViewerCore
import MDViewerDisplay
import MDViewerInteraction
import MDViewerLayout
import MDViewerMermaid
import MDViewerRender

public struct HostServices {
  public var output: TerminalOutput
  public var pasteboard: PasteboardWriting
  public var stagers: (primary: FrameStager, fallback: FrameStager?)
  public var environment: InteractionEnvironment
  public var readFile: (URL) throws -> String
  public var images: ImageStore
  public var highlighter: SyntaxHighlighter?
  public var mermaid: MermaidRenderer?
  public var resolveTheme: @Sendable (TerminalColorSet) -> ResolvedTheme
  public var crossCheck: @Sendable (ResolvedTheme) -> String?
  public var log: @Sendable (String) -> Void
  public var trace: (@Sendable (String) -> Void)?
  public var screenScale: CGFloat?
  public var watchesFiles: Bool

  public init(
    output: TerminalOutput, pasteboard: PasteboardWriting = SystemPasteboard(),
    stagers: (primary: FrameStager, fallback: FrameStager?),
    environment: InteractionEnvironment, readFile: @escaping (URL) throws -> String = readMarkdown(at:),
    images: ImageStore = ImageStore(), highlighter: SyntaxHighlighter? = nil, mermaid: MermaidRenderer? = nil,
    resolveTheme: @escaping @Sendable (TerminalColorSet) -> ResolvedTheme = {
      ResolvedTheme(colors: $0, source: .terminalQuery)
    },
    crossCheck: @escaping @Sendable (ResolvedTheme) -> String? = { _ in nil },
    log: @escaping @Sendable (String) -> Void = { _ in }, trace: (@Sendable (String) -> Void)? = nil,
    screenScale: CGFloat? = nil, watchesFiles: Bool = true
  ) {
    self.output = output
    self.pasteboard = pasteboard
    self.stagers = stagers
    self.environment = environment
    self.readFile = readFile
    self.images = images
    self.highlighter = highlighter
    self.mermaid = mermaid
    self.resolveTheme = resolveTheme
    self.crossCheck = crossCheck
    self.log = log
    self.trace = trace
    self.screenScale = screenScale
    self.watchesFiles = watchesFiles
  }
}

@MainActor
public final class ViewerHost {
  public static let themeQueryTimeout: UInt64 = 200_000_000
  public static let highlightRetryDelay: UInt64 = 1_000_000_000
  public static let maximumHighlightRetries = 3
  public static let assetSettleDelay: UInt64 = 30_000_000

  public private(set) var interaction: ViewerInteraction
  public private(set) var theme: ResolvedTheme
  public private(set) var palette: RenderPalette
  public let transport: DisplayTransport
  public let driver: DisplayDriver
  public var onQuit: () -> Void = {}

  let services: HostServices
  let source: RasterFrameSource
  let worker = LayoutWorker()
  let backingScale: CGFloat
  var sizeTracker = PaneSizeTracker()
  var parser = InputParser()
  var themeScheduler = ThemeRefreshScheduler()
  var themeReplies: TerminalColorReplyReader?
  var themeQueryID = 0
  var mermaidTheme: MermaidTheme
  var highlighted: PreparedDocument?
  var highlightAttempts: [BlockID: Int] = [:]
  var diagramsInFlight: Set<MermaidCacheKey> = []
  var hasDiagrams = false
  var assetsPending = false
  var inRelayout = false
  var synchronousLayout = false
  var watcher: FileWatcher?
  var tickTimer: DispatchSourceTimer?

  public init(size: PaneSize, theme: ResolvedTheme, themeQueryTimedOut: Bool = false, services: HostServices) {
    self.services = services
    self.theme = theme
    palette = theme.palette
    mermaidTheme = MermaidTheme(palette: palette)
    let cellHeight = CGFloat(size.rows > 0 ? size.pixelHeight / size.rows : 0)
    backingScale = Typography.backingScale(cellPixelHeight: cellHeight, screenScale: services.screenScale)
    let viewport = DisplayViewport(size: size, backingScale: backingScale, pageHeight: 0)
    let typography = Typography(bodySize: Typography.defaultBodySize, zoom: 1, backingScale: backingScale)
    interaction = ViewerInteraction(
      geometry: Self.geometry(viewport), typography: typography, environment: services.environment)
    let empty = PreparedDocument(markdown: "", typography: typography).layout(width: CGFloat(viewport.frameWidth))
    source = RasterFrameSource(rasterizer: Rasterizer(layout: empty, palette: palette))
    transport = DisplayTransport(
      viewport: viewport, output: services.output, source: source, stager: services.stagers.primary,
      fallback: services.stagers.fallback
    ) { _, viewport in viewport }
    driver = DisplayDriver(transport: transport)
    if themeQueryTimedOut { themeScheduler.queryTimedOut(at: Self.seconds()) }
    services.images.setDisplayWidth(viewport.frameWidth)
    transport.relayout = { [unowned self] size, old in relayout(size, old) }
    transport.onEvent = { [unowned self] event in displayEvent(event) }
  }

  public nonisolated static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

  nonisolated static func seconds() -> TimeInterval { TimeInterval(now()) / 1e9 }

  static func geometry(_ viewport: DisplayViewport) -> ViewGeometry {
    ViewGeometry(
      width: CGFloat(viewport.frameWidth), contentHeight: CGFloat(viewport.contentHeight),
      rowHeight: CGFloat(viewport.cellHeight))
  }

  // MARK: Entry points

  public func start(file: URL, windowSize: PaneSize) {
    synchronousLayout = true
    do {
      perform(interaction.open(file: file, source: try read(file), at: Self.now()))
    } catch {
      perform(interaction.open(file: file, source: Self.unreadableDocument(file), at: Self.now()))
      perform(interaction.show(Self.cannotRead(file), kind: .error, at: Self.now()))
    }
    synchronousLayout = false
    watch(file)
    apply(sizeTracker.windowChanged(windowSize))
    settle()
  }

  public func receive(_ bytes: [UInt8]) {
    let now = Self.now()
    let collecting = themeReplies != nil
    themeReplies?.feed(bytes)
    for event in parser.feed(bytes, at: now) { handle(event, answeringThemeQuery: collecting, at: now) }
    if collecting, themeReplies?.isComplete == true { finishThemeQuery() }
    if let deadline = parser.escapeDeadline {
      DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
        MainActor.assumeIsolated { self?.flushEscape() }
      }
    }
    settle()
  }

  public func windowChanged(_ size: PaneSize) {
    apply(sizeTracker.windowChanged(size))
    settle()
  }

  public func open(_ url: URL) {
    perform(interaction.open(url))
    settle()
  }

  public func fileChanged() {
    reloadFile()
    settle()
  }

  public func shutdown() {
    watcher?.stop()
    watcher = nil
    tickTimer?.cancel()
    tickTimer = nil
    worker.stop()
    services.mermaid?.shutDown()
    transport.shutdown()
  }

  func settle() {
    scheduleTick()
    driver.kick()
  }

  func flushEscape() {
    let now = Self.now()
    for event in parser.flushEscape(at: now) { handle(event, answeringThemeQuery: false, at: now) }
    settle()
  }

  func handle(_ event: InputEvent, answeringThemeQuery: Bool, at now: UInt64) {
    switch event {
    case .key, .mouse:
      if transport.isStopped { transport.resume() }
      perform(interaction.handle(event, at: now))
    case .colorScheme:
      if !answeringThemeQuery { requestTheme(.colorScheme) }
    case .deviceAttributes:
      themeScheduler.deviceAttributesReceived()
    case .paneSize(let size):
      apply(sizeTracker.inBandReport(size))
    case .cellSize(let width, let height):
      apply(sizeTracker.cellSizeReport(width: width, height: height))
    case .modeReport(let report):
      apply(sizeTracker.modeReport(report))
    case .graphics(let response):
      driver.handle(response)
    }
  }

  func apply(_ actions: [PaneSizeTracker.Action]) {
    for action in actions {
      switch action {
      case .observe(let size): driver.observe(size)
      case .queryCellSize: services.output.write(TerminalSequences.queryCellSize)
      }
    }
  }

  // MARK: Effects

  func perform(_ effects: [InteractionEffect]) {
    for effect in effects { perform(effect) }
  }

  func trace(_ message: @autoclosure () -> String) {
    services.trace?(message())
  }

  func perform(_ effect: InteractionEffect) {
    switch effect {
    case .scroll(let offset):
      trace("scroll \(offset)")
      if !inRelayout { transport.scroll(to: offset) }
      source.status = interaction.status
      if hasDiagrams { updateDiagrams() }
    case .redraw(let rect):
      syncFrameSource()
      invalidate(rect)
    case .redrawStatusBar:
      source.status = interaction.status
      if !inRelayout { transport.invalidateStatusBar() }
    case .redrawAll:
      syncFrameSource()
      if !inRelayout { transport.invalidateAll() }
    case .layoutChanged:
      layoutChanged()
    case .regionScrolled(let id, let offset):
      trace("region \(id) offset \(offset)")
      source.rasterizer.setScrollOffset(offset, for: id)
    case .requestLayout(let request):
      runLayout(request)
    case .writeClipboard(let text, let markdown):
      trace("clipboard \(text.count) characters\(markdown ? " as Markdown" : "")")
      if !services.pasteboard.write(text, markdown: markdown) {
        perform(interaction.show("Could not copy to the clipboard", kind: .error, at: Self.now()))
      }
    case .loadDocument(let url):
      trace("load \(url.lastPathComponent)")
      load(url)
    case .reload:
      watcher?.rearmIfNeeded()
      reloadFile()
      requestTheme(.reload)
    case .quit:
      onQuit()
    }
  }

  func syncFrameSource() {
    source.overlay = interaction.overlay
    source.status = interaction.status
  }

  func invalidate(_ rect: CGRect) {
    guard !inRelayout, !rect.isEmpty else { return }
    transport.invalidate(page: rect)
  }

  // MARK: Documents

  func read(_ url: URL) throws -> String {
    guard isRegularFile(url.path) else { throw CocoaError(.fileReadNoSuchFile) }
    return try services.readFile(url)
  }

  func load(_ url: URL) {
    let now = Self.now()
    do {
      perform(interaction.open(file: url, source: try read(url), at: now))
      watch(url)
    } catch {
      perform(interaction.loadFailed(url, reason: Self.cannotRead(url), at: now))
    }
  }

  func reloadFile() {
    guard let url = interaction.file else { return }
    services.images.forgetFailures()
    do {
      perform(interaction.fileChanged(source: try read(url)))
    } catch {
      perform(interaction.show(Self.cannotRead(url), kind: .error, at: Self.now()))
    }
  }

  func watch(_ url: URL) {
    watcher?.stop()
    watcher = nil
    guard services.watchesFiles else { return }
    watcher = FileWatcher(
      url: url, onChange: { [unowned self] in fileChanged() },
      onMissing: { [unowned self] in
        perform(interaction.show("\(url.lastPathComponent) is missing; r to reload", kind: .error, at: Self.now()))
        settle()
      })
  }

  static func cannotRead(_ url: URL) -> String { "Cannot read \(url.lastPathComponent)" }

  static func unreadableDocument(_ url: URL) -> String {
    var run = 0
    var longest = 0
    for character in url.path {
      run = character == "`" ? run + 1 : 0
      longest = max(longest, run)
    }
    let fence = String(repeating: "`", count: longest + 1)
    return "> [!CAUTION]\n> **Cannot read this file.**\n>\n> \(fence) \(url.path) \(fence)\n"
  }

  // MARK: Layout

  func runLayout(_ request: LayoutRequest) {
    let providers = layoutProviders(for: request)
    if inRelayout || synchronousLayout {
      let page = worker.perform { request.perform(providers) }
      perform(interaction.apply(page, for: request, at: Self.now()))
      return
    }
    worker.layout(request, providers: providers) { page in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.perform(self.interaction.apply(page, for: request, at: Self.now()))
          self.settle()
        }
      }
    }
  }

  func layoutProviders(for request: LayoutRequest) -> LayoutProviders {
    let context = DiagramContext(theme: mermaidTheme, pageWidth: request.width, typography: request.typography)
    var diagramSize: @Sendable (String) -> CGSize? = { _ in nil }
    if let mermaid = services.mermaid {
      diagramSize = mermaid.sizeProvider(theme: context.theme, width: context.width, scale: context.scale)
    }
    return LayoutProviders(
      prefersDark: palette.dark, imageSize: services.images.sizeProvider(relativeTo: interaction.file),
      diagramSize: diagramSize)
  }

  func relayout(_ size: PaneSize, _ old: DisplayViewport) -> DisplayViewport {
    inRelayout = true
    defer { inRelayout = false }
    var viewport = DisplayViewport(
      size: size, backingScale: backingScale, pageHeight: old.pageHeight, offset: old.offset)
    services.images.setDisplayWidth(viewport.frameWidth)
    perform(interaction.resize(Self.geometry(viewport)))
    viewport.setPageHeight(interaction.pageHeight)
    viewport.scroll(to: interaction.offset)
    syncFrameSource()
    return viewport
  }

  func layoutChanged() {
    if let layout = interaction.layout {
      trace("layout \(interaction.file?.lastPathComponent ?? "") height \(layout.height) zoom \(interaction.zoom)")
    }
    rebuildRasterizer()
    if !inRelayout, let layout = interaction.layout {
      var viewport = transport.viewport
      viewport.setPageHeight(layout.height)
      transport.replaceViewport(viewport)
    }
    requestImages()
    updateDiagrams()
  }

  func rebuildRasterizer() {
    guard let layout = interaction.layout else { return }
    var highlights = source.rasterizer.highlights
    if highlighted !== layout.prepared {
      highlighted = layout.prepared
      highlightAttempts = [:]
      highlights = requestHighlights(layout.prepared)
    }
    let context = DiagramContext(theme: mermaidTheme, pageWidth: layout.width, typography: layout.prepared.typography)
    var diagram: @Sendable (String) -> CGImage? = { _ in nil }
    if let mermaid = services.mermaid {
      diagram = mermaid.imageProvider(theme: context.theme, width: context.width, scale: context.scale)
    }
    source.rasterizer = Rasterizer(
      layout: layout, palette: palette,
      assets: RenderAssets(image: services.images.imageProvider(relativeTo: interaction.file), diagram: diagram),
      highlights: highlights)
  }

  // MARK: Highlighting

  func requestHighlights(_ prepared: PreparedDocument) -> [BlockID: HighlightResult] {
    guard let highlighter = services.highlighter else { return [:] }
    return highlighter.highlight(prepared, queue: .main) { [weak self] id, result in
      let code = prepared.codeBlocks[id]?.code
      MainActor.assumeIsolated { self?.highlightArrived(id, result, code: code) }
    }
  }

  func highlightArrived(_ id: BlockID, _ result: HighlightResult, code: String?) {
    guard let layout = interaction.layout, let block = layout.prepared.codeBlocks[id], block.code == code else {
      return
    }
    if result.outcome == .timedOut {
      retryHighlight(id, block)
      return
    }
    trace("highlight \(id) \(result.outcome)")
    source.rasterizer.highlights[id] = result
    invalidate(Self.band(of: block, in: layout))
    settle()
  }

  func retryHighlight(_ id: BlockID, _ block: CodeBlockInfo) {
    guard let highlighter = services.highlighter else { return }
    let attempt = (highlightAttempts[id] ?? 0) + 1
    guard attempt <= Self.maximumHighlightRetries else { return }
    highlightAttempts[id] = attempt
    let delay = Self.highlightRetryDelay * UInt64(attempt)
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.interaction.layout?.prepared.codeBlocks[id]?.code == block.code else { return }
        highlighter.highlight(code: block.code, language: block.language, queue: .main) { [weak self] result in
          MainActor.assumeIsolated { self?.highlightArrived(id, result, code: block.code) }
        }
      }
    }
  }

  static func band(of block: CodeBlockInfo, in layout: PageLayout) -> CGRect {
    guard let first = block.lineRanges.first, let last = block.lineRanges.last else { return .null }
    let rects = layout.rects(for: first.lowerBound..<max(last.upperBound, first.lowerBound + 1), scrolled: false)
    guard let union = rects.map(\.rect).reduce(nil, { ($0 ?? $1).union($1) }) else { return .null }
    let typography = layout.prepared.typography
    let pad = typography.pixels(em: typography.codePadding * 2)
    return CGRect(x: 0, y: union.minY - pad, width: layout.width, height: union.height + pad * 2)
  }

  // MARK: Images and diagrams

  func requestImages() {
    guard let layout = interaction.layout else { return }
    let document = interaction.file
    services.images.pin(
      layout.images.compactMap { if case .image(let source) = $0.content { source } else { nil } },
      relativeTo: document)
    for box in layout.images {
      guard case .image(let image) = box.content else { continue }
      let arrived: @Sendable (Bool) -> Void = { [weak self] available in
        MainActor.assumeIsolated { self?.imageArrived(image, available: available) }
      }
      if let video = box.video, video == image {
        services.images.loadPoster(image, relativeTo: document, queue: .main, completion: arrived)
      } else {
        services.images.load(image, relativeTo: document, queue: .main, completion: arrived)
      }
    }
  }

  func imageArrived(_ image: String, available: Bool) {
    trace("image \(image) \(available ? "loaded" : "failed")")
    guard available, let layout = interaction.layout,
      layout.images.contains(where: { $0.content == .image(source: image) })
    else { return }
    scheduleAssetsChanged()
  }

  var visibleRect: CGRect {
    CGRect(
      x: 0, y: interaction.offset, width: interaction.geometry.width, height: interaction.geometry.contentHeight)
  }

  func diagramContext(for layout: PageLayout) -> DiagramContext {
    DiagramContext(theme: mermaidTheme, pageWidth: layout.width, typography: layout.prepared.typography)
  }

  func updateDiagrams() {
    guard let mermaid = services.mermaid, let layout = interaction.layout else { return }
    let codes = DiagramPlan.codes(in: layout, visible: visibleRect)
    guard !codes.isEmpty || hasDiagrams else { return }
    hasDiagrams = !codes.isEmpty
    let context = diagramContext(for: layout)
    let requests = codes.map(context.request)
    mermaid.setCurrentDiagrams(requests)
    for request in requests where !diagramsInFlight.contains(request.key) && mermaid.cached(request) == nil {
      diagramsInFlight.insert(request.key)
      mermaid.render(request, queue: .main) { [weak self] diagram in
        MainActor.assumeIsolated { self?.diagramArrived(request, diagram) }
      }
    }
  }

  func diagramArrived(_ request: MermaidRequest, _ diagram: MermaidDiagram) {
    diagramsInFlight.remove(request.key)
    trace("diagram \(diagram.size) \(diagram.failure.map { "\($0)" } ?? "ok")")
    guard let layout = interaction.layout, diagramContext(for: layout).request(request.code).key == request.key
    else { return }
    if diagram.failure == .cancelled {
      updateDiagrams()
      return
    }
    let boxes = layout.images.filter { $0.content == .diagram(code: request.code) }
    if boxes.contains(where: { !$0.hasIntrinsicSize }) {
      scheduleAssetsChanged()
    } else {
      for box in boxes { invalidate(layout.displayRect(box.rect, region: box.region)) }
      settle()
    }
  }

  func scheduleAssetsChanged() {
    guard !assetsPending else { return }
    assetsPending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.assetSettleDelay))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.assetsPending = false
        self.perform(self.interaction.assetsChanged())
        self.settle()
      }
    }
  }

  // MARK: Theme

  func requestTheme(_ trigger: ThemeRefreshScheduler.Trigger) {
    themeScheduler.request(trigger, now: Self.seconds())
    scheduleThemeQuery()
  }

  func scheduleThemeQuery() {
    guard let due = themeScheduler.dueAt, !themeScheduler.inFlight else { return }
    let delay = max(due - Self.seconds(), 0)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      MainActor.assumeIsolated { self?.startThemeQuery() }
    }
  }

  func startThemeQuery() {
    guard themeReplies == nil, !themeScheduler.inFlight else { return }
    guard themeScheduler.start(now: Self.seconds()) else { return scheduleThemeQuery() }
    let includeScheme = themeScheduler.sendsColorSchemeQuery
    themeReplies = TerminalColorReplyReader(expectsPalette: true, expectsColorScheme: includeScheme)
    themeQueryID += 1
    let query = themeQueryID
    trace("theme query \(query)\(includeScheme ? " with scheme" : "")")
    services.output.write(TerminalColorQuery.request(includePalette: true, includeColorSchemeQuery: includeScheme))
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(Self.themeQueryTimeout))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.themeQueryID == query else { return }
        self.finishThemeQuery()
      }
    }
  }

  func finishThemeQuery() {
    guard let replies = themeReplies else { return }
    themeReplies = nil
    let timedOut = !replies.isComplete
    trace("theme replies \(timedOut ? "timed out" : "complete")")
    let colors = replies.colors
    let resolve = services.resolveTheme
    let crossCheck = services.crossCheck
    let log = services.log
    let trace = services.trace
    DispatchQueue.global(qos: .userInitiated).async {
      let started = Self.now()
      let resolved = resolve(colors)
      trace?("theme resolved in \((Self.now() - started) / 1_000_000) ms")
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.themeResolved(resolved, queryTimedOut: timedOut) }
      }
      if let note = crossCheck(resolved) { log(note) }
    }
  }

  func themeResolved(_ resolved: ResolvedTheme, queryTimedOut: Bool) {
    if queryTimedOut { services.log("theme: the terminal did not answer the color query in time") }
    applyTheme(resolved)
    themeScheduler.finish(now: Self.seconds(), queryTimedOut: queryTimedOut)
    scheduleThemeQuery()
    settle()
  }

  func applyTheme(_ resolved: ResolvedTheme) {
    theme = resolved
    let next = resolved.palette
    trace("theme \(resolved.source) background \(next.pageBackground) changed \(next != palette)")
    guard next != palette else { return }
    palette = next
    mermaidTheme = MermaidTheme(palette: next)
    rebuildRasterizer()
    perform(interaction.assetsChanged())
    transport.invalidateAll()
  }

  // MARK: Timers and display events

  func scheduleTick() {
    guard let deadline = interaction.nextDeadline else { return }
    if tickTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.setEventHandler { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.perform(self.interaction.tick(at: Self.now()))
          self.settle()
        }
      }
      timer.schedule(deadline: .distantFuture)
      timer.resume()
      tickTimer = timer
    }
    tickTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
  }

  func displayEvent(_ event: DisplayEvent) {
    if services.trace != nil { trace(Self.describe(event)) }
    guard case .failed(let message) = event else { return }
    services.log("display: \(message)")
    services.output.write("\u{1b}[1;1H\u{1b}[2Kmd-viewer: \(message). Press a key to retry or q to quit.")
  }

  static func describe(_ event: DisplayEvent) -> String {
    switch event {
    case .sent(let record): "sent \(record.kind) \(record.width)x\(record.height) image \(record.imageID)"
    case .acknowledged(let record, let latency): "ack \(record.kind) image \(record.imageID) \(latency / 1_000_000) ms"
    case .timedOut(let record): "timeout image \(record.imageID)"
    case .holding(let size): "holding \(size.pixelWidth)x\(size.pixelHeight)"
    case .settled(let size): "settled \(size.columns)x\(size.rows) \(size.pixelWidth)x\(size.pixelHeight)"
    case .retired(let ids): "retired \(ids)"
    case .failed(let message): "failed \(message)"
    }
  }
}
