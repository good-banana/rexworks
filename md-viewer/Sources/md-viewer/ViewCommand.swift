import AppKit
import Darwin
import MDViewerCore
import MDViewerWeb

@MainActor
enum ViewCommand {
  static func run(file: String) async -> Never {
    let url = URL(fileURLWithPath: file).standardizedFileURL
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
      fail("md-viewer view must run in a terminal", status: 1)
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      fail("cannot read \(url.path)", status: 1)
    }
    guard let size = Terminal.size() else {
      fail("could not read the terminal size", status: 1)
    }
    let resources: URL
    do {
      resources = try WebRenderer.resourcesURL()
    } catch {
      fail(error.localizedDescription, status: 1)
    }

    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    let colors = Terminal.queryColors()
    let theme = Theme(foreground: colors.foreground, background: colors.background)
    let session: ViewerSession
    do {
      session = try ViewerSession(renderer: WebRenderer(resources: resources), theme: theme, size: size)
    } catch {
      fail(error.localizedDescription, status: 1)
    }
    Terminal.installRestoreHandlers()
    guard Terminal.enterViewerMode() else { fail("could not configure the terminal", status: 1) }
    session.start()
    session.open(file: url, pushHistory: false, fragment: nil)
    session.startControlSocket()
    RunLoop.main.perform {
      MainActor.assumeIsolated {
        application.run()
        session.quit()
      }
    }
    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    exit(0)
  }
}

@MainActor
final class ViewerSession {
  private static let frameInterval: UInt64 = 33_000_000
  private static let lineRows = 3
  private static let focusPadding: CGFloat = 4
  private static let posterLimit = 16

  private enum Anchor {
    case top
    case offset(CGFloat)
    case fraction(CGFloat)
    case fragment(String)
  }

  private let renderer: WebRenderer
  private let tiles: TileCache
  private let theme: Theme
  private var size: TerminalSize
  private var parser = InputParser()
  private var signalSource: DispatchSourceSignal?
  private var inputSource: DispatchSourceRead?
  private var watcher: FileWatcher?
  private var controlSocket: ViewerSocketServer?
  private var pendingAnchor: Anchor?
  private var deferredAnchor: Anchor?
  private var reloading = false
  private var redrawScheduled = false
  private var lastDraw: UInt64 = 0
  private var placed: Set<UInt32> = []
  private var layoutSize: TerminalSize?
  private var documentGeneration = 0
  private var history = History()
  private var links: [PageLink] = []
  private var focusedLink: Int?
  private var prompt: String?
  private var searchQuery: String?
  private var matches: [CGRect] = []
  private var matchIndex: Int?
  private var posters: [String: String] = [:]
  private(set) var file: URL?
  private(set) var viewport: Viewport?
  private(set) var message: String?
  var statusTarget: String? {
    didSet { if statusTarget != oldValue { redraw() } }
  }

  var cellWidth: Int { max(size.pixelWidth / size.columns, 1) }
  var cellHeight: Int { max(size.pixelHeight / size.rows, 1) }
  var viewRows: Int { max(size.rows - 1, 1) }

  init(renderer: WebRenderer, theme: Theme, size: TerminalSize) throws {
    self.renderer = renderer
    self.theme = theme
    self.size = size
    tiles = try TileCache(renderer: renderer)
    tiles.onTileReady = { [unowned self] in redraw() }
    tiles.onError = { [unowned self] error in show(error.localizedDescription) }
  }

  func start() {
    signal(SIGWINCH, SIG_IGN)
    let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    resize.setEventHandler {
      MainActor.assumeIsolated { self.requestReload(self.deferredAnchor ?? .fraction(self.viewport?.fraction ?? 0)) }
    }
    resize.resume()
    signalSource = resize

    inputSource = Self.readInput { bytes in
      MainActor.assumeIsolated {
        if let bytes { self.handle(bytes) } else { self.quit() }
      }
    }
  }

  nonisolated private static func readInput(
    deliver: @escaping @Sendable ([UInt8]?) -> Void
  ) -> DispatchSourceRead {
    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global(qos: .userInteractive))
    input.setEventHandler {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = read(STDIN_FILENO, &buffer, buffer.count)
      if count < 0, errno == EINTR || errno == EAGAIN { return }
      let bytes = count > 0 ? Array(buffer[0..<count]) : nil
      if bytes == nil { input.cancel() }
      DispatchQueue.main.async { deliver(bytes) }
    }
    input.resume()
    return input
  }

  func startControlSocket() {
    guard let block = ProcessInfo.processInfo.environment["REX_BLOCK"], !block.isEmpty else { return }
    let paths = SupportPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    controlSocket = try? ViewerSocketServer(socket: paths.viewerSocket(block: block)) { url in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.open(file: url, pushHistory: true, fragment: nil) }
      }
    }
  }

  func open(file: URL, pushHistory: Bool, fragment: String?) {
    guard Self.isReadableDocument(file) else { return show("cannot read \(file.lastPathComponent)") }
    if pushHistory, let current = self.file {
      history.push(History.Entry(file: current, offset: viewport?.offset ?? 0))
    }
    load(file, anchor: fragment.map(Anchor.fragment) ?? .top)
  }

  private func load(_ file: URL, anchor: Anchor) {
    watcher?.stop()
    self.file = file
    watcher = FileWatcher(
      url: file,
      onChange: { [unowned self] in requestReload(.offset(viewport?.offset ?? 0)) },
      onMissing: { [unowned self] in show("file missing; r to reload") })
    requestReload(anchor)
  }

  func scroll(by delta: CGFloat) {
    guard var viewport else { return }
    viewport.scroll(by: delta)
    update(viewport)
  }

  func scroll(to offset: CGFloat) {
    guard var viewport else { return }
    viewport.scroll(to: offset)
    update(viewport)
  }

  func reload() {
    watcher?.rearmIfNeeded()
    requestReload(.offset(viewport?.offset ?? 0))
  }

  func redraw() {
    guard !redrawScheduled else { return }
    redrawScheduled = true
    let elapsed = DispatchTime.now().uptimeNanoseconds - lastDraw
    let delay = elapsed >= Self.frameInterval ? 0 : Self.frameInterval - elapsed
    DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(delay))) {
      MainActor.assumeIsolated {
        self.redrawScheduled = false
        self.draw()
      }
    }
  }

  func quit() -> Never {
    controlSocket?.close()
    watcher?.stop()
    tiles.removeDirectory()
    Terminal.restore()
    exit(0)
  }

  func handle(_ bytes: [UInt8]) {
    for event in parser.feed(bytes) {
      handle(event)
    }
  }

  private func handle(_ event: InputEvent) {
    if prompt != nil, case .key(let key) = event {
      handlePrompt(key)
      return
    }
    let line = CGFloat(Self.lineRows * cellHeight)
    let view = CGFloat(viewRows * cellHeight)
    switch event {
    case .key(.char("j")), .key(.down):
      scroll(by: line)
    case .key(.char("k")), .key(.up):
      scroll(by: -line)
    case .mouse(let mouse) where mouse.kind == .wheelDown:
      scroll(by: line)
    case .mouse(let mouse) where mouse.kind == .wheelUp:
      scroll(by: -line)
    case .key(.char("d")):
      scroll(by: view / 2)
    case .key(.char("u")):
      scroll(by: -(view / 2))
    case .key(.char(" ")), .key(.pageDown):
      scroll(by: view)
    case .key(.char("b")), .key(.pageUp):
      scroll(by: -view)
    case .key(.char("g")), .key(.home):
      scroll(to: 0)
    case .key(.char("G")), .key(.end):
      scroll(to: .greatestFiniteMagnitude)
    case .key(.char("r")):
      reload()
    case .mouse(let mouse) where mouse.isPrimaryClick:
      click(at: mouse)
    case .key(.tab):
      moveFocus(forward: true)
    case .key(.backTab):
      moveFocus(forward: false)
    case .key(.enter):
      if let focusedLink { activate(links[focusedLink]) }
    case .key(.escape):
      setFocus(nil)
    case .key(.backspace), .key(.char("h")):
      goBack()
    case .key(.char("/")):
      prompt = ""
      redraw()
    case .key(.char("n")):
      stepMatch(forward: true)
    case .key(.char("N")):
      stepMatch(forward: false)
    case .key(.char("q")), .key(.ctrl("q")), .key(.ctrl("c")):
      quit()
    default:
      break
    }
  }

  private var pixelsPerCSS: CGFloat? {
    tiles.layout.map { CGFloat($0.pixelWidth) / $0.cssWidth }
  }

  private func handlePrompt(_ key: Key) {
    switch key {
    case .char(let character):
      prompt?.append(character)
    case .backspace:
      if prompt?.isEmpty == true { prompt = nil } else { prompt?.removeLast() }
    case .enter:
      let query = prompt ?? ""
      prompt = nil
      search(query)
    case .escape:
      prompt = nil
    case .ctrl("c"), .ctrl("q"):
      quit()
    default:
      break
    }
    redraw()
  }

  private func click(at mouse: MouseEvent) {
    guard let viewport, let pixelsPerCSS, mouse.y < viewRows * cellHeight else { return }
    let pageX = CGFloat(mouse.x) / pixelsPerCSS
    let pageY = (CGFloat(mouse.y) + viewport.offset) / pixelsPerCSS
    if let link = hitTest(links, pageX: pageX, pageY: pageY) { activate(link) }
  }

  private func activate(_ link: PageLink) {
    guard let file else { return }
    let action = linkAction(href: link.href, currentFile: file) { FileManager.default.fileExists(atPath: $0.path) }
    switch action {
    case .openMarkdown(let target, let fragment):
      if target.path != file.path {
        open(file: target, pushHistory: true, fragment: fragment)
      } else if let fragment {
        jump(toAnchor: fragment)
      }
    case .scrollToAnchor(let id):
      jump(toAnchor: id)
    case .openExternal(let url):
      openExternal(url)
    case .ignore:
      show("cannot open \(link.href)")
    }
  }

  private func jump(toAnchor id: String) {
    let generation = documentGeneration
    Task { @MainActor in
      let offset = try? await renderer.anchorOffset(id)
      guard generation == documentGeneration, let file, let viewport, let pixelsPerCSS else { return }
      guard let offset else {
        show("no anchor #\(id)")
        return
      }
      history.push(History.Entry(file: file, offset: viewport.offset))
      scroll(to: offset * pixelsPerCSS)
    }
  }

  private func openExternal(_ url: URL) {
    if url.isFileURL, !isSafeToOpenLocally(url) {
      show("not opening \(url.lastPathComponent)")
    } else if !NSWorkspace.shared.open(url) {
      show("could not open \(url.absoluteString)")
    }
  }

  private func goBack() {
    guard let entry = history.pop() else {
      show("no previous page")
      return
    }
    if entry.file.path == file?.path, viewport != nil {
      scroll(to: entry.offset)
    } else if Self.isReadableDocument(entry.file) {
      load(entry.file, anchor: .offset(entry.offset))
    } else {
      show("cannot read \(entry.file.lastPathComponent)")
    }
  }

  private func moveFocus(forward: Bool) {
    guard let next = cycle(from: focusedLink, count: links.count, forward: forward) else {
      show("no links")
      return
    }
    setFocus(next)
  }

  private func setFocus(_ index: Int?) {
    guard index != focusedLink else { return }
    let changed = [focusedLink, index].compactMap { $0 }.map { links[$0].rect }
    focusedLink = index
    statusTarget = index.map { links[$0].href }
    if let index { reveal(links[index].rect) }
    let generation = documentGeneration
    Task { @MainActor in
      guard generation == documentGeneration else { return }
      try? await renderer.focusLink(index)
      guard generation == documentGeneration else { return }
      refreshTiles(covering: changed, padding: Self.focusPadding)
    }
  }

  private func refreshTiles(covering rects: [CGRect], padding: CGFloat) {
    guard let viewport, let pixelsPerCSS else { return }
    for rect in rects {
      tiles.refresh(
        viewport.tiles(
          coveringTop: (rect.minY - padding) * pixelsPerCSS, bottom: (rect.maxY + padding) * pixelsPerCSS))
    }
    redraw()
  }

  private static func isReadableDocument(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
      && FileManager.default.isReadableFile(atPath: url.path)
  }

  private func reveal(_ rect: CGRect) {
    guard var viewport, let pixelsPerCSS else { return }
    viewport.reveal(top: rect.minY * pixelsPerCSS, bottom: rect.maxY * pixelsPerCSS)
    update(viewport)
  }

  private func search(_ query: String) {
    searchQuery = query.isEmpty ? nil : query
    matches = []
    matchIndex = nil
    guard let searchQuery else { return show(nil) }
    let generation = documentGeneration
    Task { @MainActor in
      let found = (try? await renderer.search(searchQuery)) ?? []
      guard generation == documentGeneration, searchQuery == self.searchQuery else { return }
      matches = found
      let top = (viewport?.offset ?? 0) / (pixelsPerCSS ?? 1)
      matchIndex = matches.firstIndex { $0.minY >= top } ?? (matches.isEmpty ? nil : 0)
      showMatch()
    }
  }

  private func stepMatch(forward: Bool) {
    guard searchQuery != nil else { return show("no search; / to search") }
    matchIndex = cycle(from: matchIndex, count: matches.count, forward: forward)
    showMatch()
  }

  private func showMatch() {
    guard let searchQuery else { return }
    guard let matchIndex else { return show("no matches for \(searchQuery)") }
    reveal(matches[matchIndex])
    show("\(searchQuery) \(matchIndex + 1)/\(matches.count)")
  }

  private func loadPosters(for file: URL, generation: Int) async {
    guard let placeholders = try? await renderer.missingPosters() else { return }
    for placeholder in placeholders.prefix(Self.posterLimit) {
      guard generation == documentGeneration else { return }
      let action = linkAction(href: placeholder.href, currentFile: file) { isPosterCandidate($0) }
      guard case .openExternal(let url) = action, let poster = await poster(for: url),
        generation == documentGeneration
      else { continue }
      guard (try? await renderer.setPoster(index: placeholder.index, dataURL: poster)) == true,
        generation == documentGeneration
      else { continue }
      refreshTiles(covering: [placeholder.rect], padding: 0)
    }
  }

  private func poster(for url: URL) async -> String? {
    let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    let key = "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
    if let cached = posters[key] { return cached }
    guard let poster = try? await VideoPoster.dataURL(for: url) else { return nil }
    posters[key] = poster
    return poster
  }

  private func update(_ viewport: Viewport) {
    guard viewport != self.viewport else { return }
    self.viewport = viewport
    redraw()
  }

  private func show(_ text: String?) {
    message = text
    redraw()
  }

  private func requestReload(_ anchor: Anchor) {
    pendingAnchor = anchor
    guard !reloading else { return }
    reloading = true
    Task { @MainActor in
      while let anchor = pendingAnchor {
        pendingAnchor = nil
        await performReload(anchor)
      }
      reloading = false
    }
  }

  private func performReload(_ anchor: Anchor) async {
    guard let file else { return }
    documentGeneration += 1
    if let measured = Terminal.size() { size = measured }
    if size != layoutSize { hideTiles() }
    guard size.pixelWidth > 0, size.pixelHeight > 0 else {
      deferredAnchor = anchor
      show("waiting for the terminal to report its size in pixels")
      return
    }
    deferredAnchor = nil
    let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
    let layoutWidth = size.columns * cellWidth
    let viewHeight = viewRows * cellHeight
    do {
      let markdown = try String(contentsOf: file, encoding: .utf8)
      tiles.invalidate()
      let height = try await renderer.render(
        markdown: markdown, fileURL: file, width: CGFloat(layoutWidth) / scale, theme: theme)
      var viewport = Viewport(
        pageHeight: height * scale, viewHeight: CGFloat(viewHeight), tileHeight: CGFloat(viewHeight), offset: 0,
        cellHeight: CGFloat(cellHeight))
      switch anchor {
      case .top: break
      case .offset(let offset): viewport.scroll(to: offset)
      case .fraction(let fraction): viewport.scroll(toFraction: fraction)
      case .fragment(let id):
        if let offset = try? await renderer.anchorOffset(id) { viewport.scroll(to: offset * scale) }
      }
      links = (try? await renderer.links()) ?? []
      focusedLink = nil
      statusTarget = nil
      matches = []
      matchIndex = nil
      if let searchQuery { matches = (try? await renderer.search(searchQuery)) ?? [] }
      tiles.reset(
        layout: TileLayout(
          pixelWidth: layoutWidth, tileHeight: viewHeight, scale: scale, pageHeight: height,
          background: theme.background))
      self.viewport = viewport
      layoutSize = size
      message = nil
      placed = []
      Terminal.write("\u{1b}[2J")
      draw()
      let generation = documentGeneration
      Task { @MainActor in await loadPosters(for: file, generation: generation) }
    } catch {
      show(error.localizedDescription)
    }
  }

  private func draw() {
    lastDraw = DispatchTime.now().uptimeNanoseconds
    var output = ""
    var shown: Set<UInt32> = []
    if let viewport, let layout = tiles.layout, size == layoutSize {
      let slices = viewport.visibleTiles()
      for slice in slices {
        guard let id = tiles.image(for: slice.index) else { continue }
        let source = CGRect(x: 0, y: slice.source.minY, width: CGFloat(layout.pixelWidth), height: slice.source.height)
        output += "\u{1b}[\(slice.destinationRow + 1);1H"
        output += Kitty.place(id: id, placement: 1, source: source, columns: size.columns, rows: slice.rows, z: 0)
        shown.insert(id)
      }
      if let first = slices.first?.index, let last = slices.last?.index {
        tiles.want(Array(first...last) + [last + 1, first - 1], tileCount: viewport.tileCount)
        tiles.evict(farFrom: first...last)
      }
    }
    for id in placed.subtracting(shown) {
      output += Kitty.deletePlacements(id: id)
    }
    output += tiles.takeRetired().map(Kitty.deleteImage).joined()
    placed = shown
    output += statusLine()
    Terminal.write(output)
  }

  private func hideTiles() {
    layoutSize = nil
    Terminal.write(placed.map(Kitty.deletePlacements).joined() + "\u{1b}[2J")
    placed = []
    draw()
  }

  private func statusLine() -> String {
    var parts = [file?.lastPathComponent ?? ""]
    if let viewport { parts.append("\(viewport.percent)%") }
    if let statusTarget { parts.append("->\(statusTarget)") }
    if let message { parts.append(message) }
    let line = prompt.map { "/" + $0 } ?? parts.joined(separator: "  ")
    let printable = line.filter { character in
      character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    let text = String(printable.prefix(size.columns))
    return "\u{1b}[\(size.rows);1H\u{1b}[2K\(text)"
  }
}
