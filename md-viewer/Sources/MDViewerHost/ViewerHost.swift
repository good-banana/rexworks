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
  public var reduceMotion: () -> Bool

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
    screenScale: CGFloat? = nil, watchesFiles: Bool = true, reduceMotion: @escaping () -> Bool = { false }
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
    self.reduceMotion = reduceMotion
  }
}

@MainActor
public final class ViewerHost {
  public static let themeQueryTimeout: UInt64 = 200_000_000
  public static let highlightRetryDelay: UInt64 = 1_000_000_000
  public static let maximumHighlightRetries = 3
  public static let assetSettleDelay: UInt64 = 30_000_000
  public static let handoffDrainTimeout: UInt64 = 2_000_000_000

  public private(set) var interaction: ViewerInteraction
  public private(set) var theme: ResolvedTheme
  public private(set) var palette: RenderPalette
  public let transport: DisplayTransport
  public let driver: DisplayDriver
  public var onQuit: () -> Void = {}
  public var onDocumentShown: (URL) -> Void = { _ in }
  public private(set) var editor: EditorCoordinator?
  public private(set) var handoffActive = false
  public private(set) var pendingDeviceAttributes: Int

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
  var player = AnimationPlayer()
  let animationFrames = AnimationFrames()
  var animationTimer: DispatchSourceTimer?
  var animationTimerDeadline: UInt64?
  var tickTimerDeadline: UInt64?
  var lastAnimationTick: UInt64 = 0
  var liveBufferNoticeShown = false
  var liveBufferSession = 0
  var diskChangePending = false
  var displaySuspended = false
  var drainCompletion: (() -> Void)?
  var drainID = 0

  public init(size: PaneSize, theme: ResolvedTheme, themeQueryTimedOut: Bool = false, services: HostServices) {
    self.services = services
    self.theme = theme
    pendingDeviceAttributes = themeQueryTimedOut ? 1 : 0
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
    onDocumentShown(file)
    watch(file)
    apply(sizeTracker.windowChanged(windowSize))
    settle()
  }

  public func receive(_ bytes: [UInt8]) {
    let now = Self.now()
    if services.trace != nil, bytes.count <= 64, !bytes.starts(with: Array("\u{1b}_G".utf8)) {
      trace("input \(String(decoding: bytes, as: UTF8.self).debugDescription)")
    }
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
    guard !handoffActive else { return }
    apply(sizeTracker.windowChanged(size))
    settle()
  }

  public func open(_ url: URL) {
    leaveLiveBuffer()
    perform(interaction.clearEditorCursor())
    perform(interaction.open(url))
    settle()
  }

  public func fileChanged() {
    if interaction.liveBuffer {
      scheduleDiskChangeNotice()
    } else {
      reloadFile()
    }
    settle()
  }

  func scheduleDiskChangeNotice() {
    guard !liveBufferNoticeShown, !diskChangePending else { return }
    diskChangePending = true
    let session = liveBufferSession
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.editorSaveGrace) { [weak self] in
      MainActor.assumeIsolated { self?.noticeDiskChange(session: session) }
    }
  }

  func noticeDiskChange(session: Int) {
    diskChangePending = false
    guard interaction.liveBuffer, session == liveBufferSession, !liveBufferNoticeShown else { return }
    if let url = interaction.file, (try? read(url)) == interaction.source { return }
    liveBufferNoticeShown = true
    perform(interaction.show(Self.liveBufferNotice, kind: .info, at: Self.now()))
    settle()
  }

  public func themeChanged() {
    requestTheme(.reload)
    settle()
  }

  public func shutdown() {
    editor?.shutdown()
    watcher?.stop()
    watcher = nil
    tickTimer?.cancel()
    tickTimer = nil
    animationTimer?.cancel()
    animationTimer = nil
    worker.stop()
    services.mermaid?.shutDown()
    transport.shutdown()
  }

  func settle() {
    scheduleTick()
    updateAnimations()
    driver.kick()
  }

  func flushEscape() {
    let now = Self.now()
    for event in parser.flushEscape(at: now) { handle(event, answeringThemeQuery: false, at: now) }
    settle()
  }

  func handle(_ event: InputEvent, answeringThemeQuery: Bool, at now: UInt64) {
    if handoffActive {
      if event == .deviceAttributes { deviceAttributesArrived() }
      return
    }
    switch event {
    case .key, .mouse:
      if transport.isStopped { transport.resume() }
      perform(interaction.handle(event, at: now))
    case .colorScheme:
      if !answeringThemeQuery { requestTheme(.colorScheme) }
    case .deviceAttributes:
      deviceAttributesArrived()
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
      if services.trace != nil {
        let status = interaction.status
        trace("status \(status.findField.map { "find [\($0)] " } ?? "")\(status.message?.text ?? "")")
      }
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
    case .pointerShape(let shape):
      trace("pointer \(shape.rawValue)")
      services.output.write(TerminalSequences.pointerShape(shape))
    case .loadDocument(let url):
      trace("load \(url.lastPathComponent)")
      load(url)
    case .reload:
      watcher?.rearmIfNeeded()
      leaveLiveBuffer()
      reloadFile()
      requestTheme(.reload)
      editor?.refreshEnvironment()
    case .quit:
      onQuit()
    case .edit(let request):
      editor?.edit(request)
    case .openEditorPicker:
      editor?.openPicker()
    case .chooseEditor(let candidate, let mode, let pending):
      editor?.choose(candidate, mode: mode, pending: pending)
    case .jumpEditor(let line):
      editor?.jump(line: line)
    }
  }

  func syncFrameSource() {
    source.showsHelp = interaction.helpVisible
    source.editMode = interaction.editMode
    source.editorPicker = interaction.editorPicker
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
      refreshEditorLink()
      onDocumentShown(url)
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

  // MARK: Editor

  public static let liveBufferNotice = "File changed on disk; showing the editor's unsaved text"
  static let editorSaveGrace: TimeInterval = 0.5

  public func attachEditor(_ editor: EditorCoordinator) {
    self.editor = editor
    editor.host = self
    refreshEditorLink()
  }

  public func setEditMode(_ mode: EditMode) {
    guard interaction.editMode != mode else { return }
    interaction.editMode = mode
    source.editMode = mode
    guard interaction.helpVisible else { return }
    transport.invalidateAll()
    settle()
  }

  public func receiveEditor(_ message: EditorMessage) {
    guard let editor else { return }
    if case .edit(let mode, let line) = message {
      editor.edit(EditRequest(mode: mode, line: line), fromSocket: true)
      return
    }
    guard editor.accept(message, shownFile: interaction.file) else {
      trace("editor message dropped \(message)")
      return
    }
    switch message {
    case .cursor(_, let line, let top, let height):
      perform(interaction.applyEditorCursor(EditorCursor(line: line, top: top, height: height)))
    case .buffer(_, let text):
      showLiveBuffer(text, buffers: editor.buffersDirectory)
    case .clean:
      leaveLiveBuffer()
      reloadFile()
    case .follow(let envelope):
      followEditor(to: URL(fileURLWithPath: envelope.file))
    case .unlinked(let envelope):
      if editor.unlinked(token: envelope.token) { editorEnded(status: EditorCoordinator.relinkedMessage) }
    case .exit(let envelope):
      editor.exited(token: envelope.token)
    case .edit:
      break
    }
    refreshEditorLink()
    settle()
  }

  func showLiveBuffer(_ text: URL, buffers: URL) {
    guard let url = validateBufferPath(text.path, buffersDirectory: buffers), let source = try? read(url) else {
      return
    }
    if !interaction.liveBuffer { liveBufferNoticeShown = false }
    perform(interaction.fileChanged(source: source))
    perform(interaction.setLiveBuffer(true))
  }

  func leaveLiveBuffer() {
    if interaction.liveBuffer { liveBufferSession += 1 }
    perform(interaction.setLiveBuffer(false))
  }

  func followEditor(to url: URL) {
    let wasLive = interaction.liveBuffer
    leaveLiveBuffer()
    perform(interaction.clearEditorCursor())
    if let file = interaction.file, canonicalPath(file.path) == canonicalPath(url.path) {
      if wasLive { reloadFile() }
    } else {
      perform(interaction.open(url))
    }
  }

  func dropLiveBuffer() {
    guard interaction.liveBuffer else { return }
    leaveLiveBuffer()
    reloadFile()
    settle()
  }

  func editorEnded(status: String) {
    perform(interaction.clearEditorCursor())
    leaveLiveBuffer()
    reloadFile()
    refreshEditorLink()
    perform(interaction.show(status, kind: .info, at: Self.now()))
    settle()
  }

  func editorLinkChanged() {
    refreshEditorLink()
    settle()
  }

  func refreshEditorLink() {
    var current: EditorLink?
    if let link = editor?.link, link.block != nil, let kind = link.kind {
      current = EditorLink(
        name: kind.displayName, syncsLive: kind == .neovim && link.token != nil,
        followsShownFile: interaction.file.map(link.follows) ?? false)
    }
    perform(interaction.setEditorLink(current))
  }

  func showEditorStatus(_ text: String, kind: StatusMessage.Kind) {
    perform(interaction.show(text, kind: kind, at: Self.now()))
    settle()
  }

  func showEditorPicker(_ candidates: [EditorCandidate], mode: EditMode, pending: EditRequest? = nil) {
    perform(interaction.showEditorPicker(candidates: candidates, mode: mode, pending: pending))
    settle()
  }

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

  // MARK: Handoff

  public func beginHandoff() {
    handoffActive = true
    watcher?.stop()
    watcher = nil
    suspendDisplay()
  }

  public func suspendDisplay() {
    displaySuspended = true
    if themeReplies != nil {
      themeReplies = nil
      themeQueryID += 1
      themeScheduler.finish(now: Self.seconds(), queryTimedOut: false)
    }
    transport.suspend()
    updateAnimations()
  }

  public func awaitSentinelReply(
    timeout: UInt64 = ViewerHost.handoffDrainTimeout, then completion: @escaping () -> Void
  ) {
    pendingDeviceAttributes += 1
    drainID += 1
    let drain = drainID
    drainCompletion = completion
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(timeout))) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.drainID == drain else { return }
        self.endDrain()
      }
    }
  }

  func deviceAttributesArrived() {
    pendingDeviceAttributes = max(pendingDeviceAttributes - 1, 0)
    if pendingDeviceAttributes == 0 { endDrain() }
  }

  func endDrain() {
    guard let completion = drainCompletion else { return }
    drainCompletion = nil
    drainID += 1
    pendingDeviceAttributes = 0
    DispatchQueue.main.async { completion() }
  }

  public func resetInput() {
    parser = InputParser()
  }

  public func resumeDisplay(size: PaneSize?) {
    displaySuspended = false
    transport.resume()
    if let size { apply(sizeTracker.windowChanged(size)) }
    settle()
  }

  public func endHandoff(block: String?) {
    handoffActive = false
    if let file = interaction.file { watch(file) }
    let linked = block.map { editor?.isLinked(to: $0) == true } ?? false
    if let block { editor?.blockEnded(block) }
    if !linked {
      perform(interaction.clearEditorCursor())
      leaveLiveBuffer()
      reloadFile()
    }
    requestTheme(.reload)
    settle()
  }

  public func applyHandoffCursor(_ message: EditorMessage?, shownBefore: URL?) {
    guard case .cursor(let envelope, let line, let top, let height) = message, let file = interaction.file,
      let shownBefore, canonicalPath(file.path) == canonicalPath(shownBefore.path),
      canonicalPath(envelope.file) == canonicalPath(file.path)
    else { return }
    perform(interaction.applyEditorCursor(EditorCursor(line: line, top: top, height: height)))
    settle()
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
      assets: RenderAssets(image: animatedImageProvider(), diagram: diagram),
      highlights: highlights)
  }

  func animatedImageProvider() -> @Sendable (String) -> CGImage? {
    let images = services.images
    let document = interaction.file
    let frames = animationFrames
    return { source in images.image(for: source, relativeTo: document)?.frame(frames.index(for: source)) }
  }

  // MARK: Animation

  func updateAnimations() {
    var visible: [String: AnimationPlayer.Clip] = [:]
    if !displaySuspended, !services.reduceMotion(), !interaction.helpVisible, interaction.editorPicker == nil,
      !transport.isStopped,
      let layout = interaction.layout
    {
      for box in layout.images {
        guard case .image(let source) = box.content, visible[source] == nil,
          layout.displayRect(box.rect, region: box.region).intersects(visibleRect),
          let image = services.images.image(for: source, relativeTo: interaction.file), image.isAnimated
        else { continue }
        visible[source] = AnimationPlayer.Clip(delays: image.delays, loopCount: image.loopCount)
      }
    }
    player.show(visible, at: Self.now())
    scheduleAnimation()
  }

  func scheduleAnimation() {
    guard let deadline = player.nextDeadline else {
      if animationTimerDeadline != nil { animationTimer?.schedule(deadline: .distantFuture) }
      animationTimerDeadline = nil
      return
    }
    if animationTimer == nil {
      let timer = DispatchSource.makeTimerSource(queue: .main)
      timer.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.animationTick() }
      }
      timer.schedule(deadline: .distantFuture)
      timer.resume()
      animationTimer = timer
    }
    let at = max(deadline, lastAnimationTick + AnimationPlayer.minimumTickInterval)
    animationTimerDeadline = at
    animationTimer?.schedule(deadline: DispatchTime(uptimeNanoseconds: at))
  }

  func animationTick() {
    let now = Self.now()
    lastAnimationTick = now
    guard let layout = interaction.layout else { return }
    for source in player.advance(at: now) {
      let frame = player.frame(for: source)
      animationFrames.set(frame, for: source)
      trace("animate \(source) frame \(frame)")
      for box in layout.images where box.content == .image(source: source) {
        let rect = layout.displayRect(box.rect, region: box.region).intersection(visibleRect)
        if !rect.isNull { invalidate(rect) }
      }
    }
    settle()
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
    guard !displaySuspended, themeReplies == nil, !themeScheduler.inFlight else { return }
    guard themeScheduler.start(now: Self.seconds()) else { return scheduleThemeQuery() }
    let includeScheme = themeScheduler.sendsColorSchemeQuery
    themeReplies = TerminalColorReplyReader(expectsPalette: true, expectsColorScheme: includeScheme)
    themeQueryID += 1
    let query = themeQueryID
    trace("theme query \(query)\(includeScheme ? " with scheme" : "")")
    services.output.write(TerminalColorQuery.request(includePalette: true, includeColorSchemeQuery: includeScheme))
    pendingDeviceAttributes += 1
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
    guard let deadline = interaction.nextDeadline else {
      if tickTimerDeadline != nil { tickTimer?.schedule(deadline: .distantFuture) }
      tickTimerDeadline = nil
      return
    }
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
    tickTimerDeadline = deadline
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
