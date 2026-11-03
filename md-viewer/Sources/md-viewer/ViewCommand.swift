import AppKit
import Darwin
import MDViewerCore
import MDViewerDisplay
import MDViewerHost
import MDViewerInteraction
import MDViewerMermaid
import MDViewerRender

@MainActor
enum ViewCommand {
  private static var retained: [AnyObject] = []

  static func run(_ arguments: ViewArguments) async -> Never {
    let url = URL(fileURLWithPath: arguments.file).standardizedFileURL
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
      fail("md-viewer view must run in a terminal", status: 1)
    }
    guard let size = Terminal.size() else { fail("could not read the terminal size", status: 1) }

    let paths = SupportPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    let status = ViewerStatus(file: url, opener: arguments.origin.opener)
    let control = ViewerControl()
    let server = startControlSocket(control, status: status, paths: paths)
    if let server { retained.append(server) }
    let log = ViewerLog(url: paths.viewerLog)
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    Terminal.installRestoreHandlers()
    guard Terminal.enterViewerMode() else { fail("could not configure the terminal", status: 1) }

    let source = arguments.origin.themeSourceBlock
    let resolved = Terminal.resolveTheme(themeSourceBlock: source)
    Terminal.write(TerminalSequences.enableViewerModes + TerminalSequences.queryInBandResizeReports)
    logTheme(resolved.theme, timedOut: resolved.queryTimedOut, log: log)
    Terminal.crossCheckTheme(resolved.theme, themeSourceBlock: source) { log.write($0) }

    var trace: (@Sendable (String) -> Void)?
    if ProcessInfo.processInfo.environment["MDVIEWER_TRACE"] == "1" { trace = { log.write("trace " + $0) } }
    let gate = GatedTerminalOutput(FileDescriptorOutput())
    let services = HostServices(
      output: gate, stagers: FrameStaging.preferred(),
      environment: InteractionEnvironment(openURL: { NSWorkspace.shared.open($0) }),
      highlighter: SyntaxHighlighter(), mermaid: MermaidRenderer(),
      resolveTheme: { Terminal.themeResolver().resolve(inBand: $0, sourceBlock: source) },
      crossCheck: { $0.note(for: Terminal.themeResolver().crossCheck($0, sourceBlock: source)) },
      log: { log.write($0) },
      trace: trace,
      screenScale: NSScreen.main?.backingScaleFactor,
      reduceMotion: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion })
    let host = ViewerHost(
      size: size, theme: resolved.theme, themeQueryTimedOut: resolved.queryTimedOut, services: services)
    host.onQuit = { quit(host) }
    host.onDocumentShown = { status.show($0) }
    let environment = ProcessInfo.processInfo.environment
    let editor = EditorCoordinator(
      context: EditorContext(
        paths: paths, rexPath: (try? ConfigStore.load(paths))?.rexPath ?? locateExecutable("rex"),
        session: environment["REX_SESSION"], block: environment["REX_BLOCK"], previewSocket: server?.path,
        ownEnvironment: environment),
      system: EditorSystem(log: { log.write($0) }))
    host.setEditMode(SettingsStore.load(paths).editMode)
    host.attachEditor(editor)
    control.onEditorMessage = { host.receiveEditor($0) }
    control.onLiveFollow = { editor.liveFollow(token: $0, file: $1) }
    host.start(file: url, windowSize: size)
    control.attach(host)
    let input = startInput(host)
    retained.append(input)
    let handoff = HandoffController(
      host: host, control: control, gate: gate, terminal: Handoff(input: input, inputQueue: inputQueue))
    retained.append(handoff)
    editor.onHandoff = { handoff.start($0) }
    retained.append(startResizeSignal(host))
    let themeWatch = ThemeWatchService(paths: paths, ownSocket: server?.path)
    themeWatch.onLocalChange = { host.themeChanged() }
    themeWatch.start()
    retained.append(themeWatch)

    RunLoop.main.perform {
      MainActor.assumeIsolated {
        application.run()
        quit(host)
      }
    }
    await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
    exit(0)
  }

  static func quit(_ host: ViewerHost) -> Never {
    for case let server as ViewerSocketServer in retained { server.close() }
    for case let watch as ThemeWatchService in retained { watch.stop() }
    host.shutdown()
    Terminal.restore()
    exit(0)
  }

  private static func logTheme(_ theme: ResolvedTheme, timedOut: Bool, log: ViewerLog) {
    log.write("theme: \(theme.source)")
    if timedOut { log.write("theme: the terminal did not answer the color query in time") }
    if theme.colors.background == nil || theme.colors.foreground == nil {
      log.write("theme: no page colors from Rex or the terminal; using the built-in fallback")
    }
  }

  nonisolated private static let inputQueue = DispatchQueue(label: "md-viewer.stdin", qos: .userInteractive)

  nonisolated private static func startInput(_ host: ViewerHost) -> DispatchSourceRead {
    let input = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: inputQueue)
    input.setEventHandler {
      var buffer = [UInt8](repeating: 0, count: 16_384)
      let count = read(STDIN_FILENO, &buffer, buffer.count)
      if count < 0, errno == EINTR || errno == EAGAIN { return }
      let bytes = count > 0 ? Array(buffer[0..<count]) : nil
      if bytes == nil { input.cancel() }
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if let bytes { host.receive(bytes) } else { quit(host) }
        }
      }
    }
    input.resume()
    return input
  }

  private static func startResizeSignal(_ host: ViewerHost) -> DispatchSourceSignal {
    signal(SIGWINCH, SIG_IGN)
    let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    resize.setEventHandler {
      MainActor.assumeIsolated {
        if let size = Terminal.size() { host.windowChanged(size) }
      }
    }
    resize.resume()
    return resize
  }

  private static func startControlSocket(
    _ control: ViewerControl, status: ViewerStatus, paths: SupportPaths
  ) -> ViewerSocketServer? {
    guard let block = ProcessInfo.processInfo.environment["REX_BLOCK"], !block.isEmpty else { return nil }
    return try? control.listen(
      on: paths.viewerSocket(block: block), status: status, buffersDirectory: paths.buffersDirectory)
  }
}
