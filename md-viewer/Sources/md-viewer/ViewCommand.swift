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
  private var pendingAnchor: Anchor?
  private var deferredAnchor: Anchor?
  private var reloading = false
  private var redrawScheduled = false
  private var lastDraw: UInt64 = 0
  private var placed: Set<UInt32> = []
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

  func open(file: URL, pushHistory: Bool, fragment: String?) {
    watcher?.stop()
    self.file = file
    watcher = FileWatcher(url: file) { [unowned self] in
      requestReload(.offset(viewport?.offset ?? 0))
    }
    requestReload(fragment.map(Anchor.fragment) ?? .top)
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
    case .key(.char("q")), .key(.ctrl("q")):
      quit()
    default:
      break
    }
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
    if let measured = Terminal.size() { size = measured }
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
      tiles.reset(
        layout: TileLayout(
          pixelWidth: layoutWidth, tileHeight: viewHeight, scale: scale, pageHeight: height,
          background: theme.background))
      self.viewport = viewport
      message = nil
      placed = []
      Terminal.write("\u{1b}[2J")
      draw()
    } catch {
      show(error.localizedDescription)
    }
  }

  private func draw() {
    lastDraw = DispatchTime.now().uptimeNanoseconds
    var output = ""
    var shown: Set<UInt32> = []
    if let viewport, let layout = tiles.layout {
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
    placed = shown
    output += statusLine()
    Terminal.write(output)
  }

  private func statusLine() -> String {
    var parts = [file?.lastPathComponent ?? ""]
    if let viewport { parts.append("\(viewport.percent)%") }
    if let statusTarget { parts.append("->\(statusTarget)") }
    if let message { parts.append(message) }
    let printable = parts.joined(separator: "  ").filter { character in
      character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    let text = String(printable.prefix(size.columns))
    return "\u{1b}[\(size.rows);1H\u{1b}[2K\(text)"
  }
}
