import CryptoKit
import Foundation
import MDViewerCore
import MDViewerInteraction
import MDViewerRender

public struct EditorContext: Sendable {
  public var paths: SupportPaths
  public var rexPath: String?
  public var session: String?
  public var block: String?
  public var previewSocket: URL?
  public var ownEnvironment: [String: String]

  public init(
    paths: SupportPaths, rexPath: String?, session: String?, block: String?, previewSocket: URL?,
    ownEnvironment: [String: String]
  ) {
    self.paths = paths
    self.rexPath = rexPath.flatMap { $0.isEmpty ? nil : $0 }
    self.session = session.flatMap { $0.isEmpty ? nil : $0 }
    self.block = block.flatMap { $0.isEmpty ? nil : $0 }
    self.previewSocket = previewSocket
    self.ownEnvironment = ownEnvironment
  }
}

public struct EditorLaunch: Equatable, Sendable {
  public var command: [String]
  public var environment: [String: String]
  public var directory: URL
  public var kind: EditorKind
  public var block: String?
  public var token: String?
}

public struct EditorSystem: @unchecked Sendable {
  public var runner: ProcessRunning
  public var isExecutable: @Sendable (String) -> Bool
  public var sendControl: @Sendable (EditorControlCommand, URL) -> Bool
  public var launchGUI: @Sendable (EditorLaunch) throws -> Void
  public var paneWait: PaneWaitLauncher?
  public var makeToken: @Sendable () -> String
  public var log: @Sendable (String) -> Void

  public init(
    runner: ProcessRunning = ProcessRunner(timeout: EditorCoordinator.rexTimeout),
    isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    sendControl: @escaping @Sendable (EditorControlCommand, URL) -> Bool = { ViewerSocketClient.send($0, to: $1) },
    launchGUI: @escaping @Sendable (EditorLaunch) throws -> Void = EditorCoordinator.launchProcess,
    paneWait: PaneWaitLauncher? = nil,
    makeToken: @escaping @Sendable () -> String = EditorCoordinator.randomToken,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.runner = runner
    self.isExecutable = isExecutable
    self.sendControl = sendControl
    self.launchGUI = launchGUI
    self.paneWait = paneWait
    self.makeToken = makeToken
    self.log = log
  }
}

public struct EditorLinkState: Equatable, Sendable {
  public struct Pending: Equatable, Sendable {
    public var token: String
    public var block: String?
    public var kind: EditorKind
    public var controlSocket: String?
  }

  public internal(set) var block: String?
  public internal(set) var token: String?
  public internal(set) var kind: EditorKind?
  public internal(set) var controlSocket: String?
  public internal(set) var followedFile: String?
  public internal(set) var pendings: [Pending] = []
  var bufferToken: String?
  var lastSeq: [String: Int] = [:]

  public var pending: Pending? { pendings.last }

  func pending(for token: String) -> Pending? {
    pendings.first { $0.token == token }
  }

  public mutating func accept(_ message: EditorMessage, shownFile: URL?) -> Bool {
    guard let envelope = message.envelope else { return true }
    guard envelope.token == token || pending(for: envelope.token) != nil else { return false }
    if let last = lastSeq[envelope.token], envelope.seq <= last { return false }
    if let match = pending(for: envelope.token), let block = match.block, message.confirmsLink {
      adopt(match, block: block)
    }
    lastSeq[envelope.token] = envelope.seq
    switch message {
    case .cursor, .buffer, .clean:
      guard let shownFile, canonicalPath(envelope.file) == canonicalPath(shownFile.path) else { return false }
    case .follow:
      followedFile = canonicalPath(envelope.file)
    case .unlinked, .exit, .edit:
      break
    }
    return true
  }

  func block(owning token: String) -> String? {
    if token == self.token { return block }
    return pending(for: token)?.block
  }

  var jumpTargets: [(token: String, controlSocket: String)] {
    var targets: [(token: String, controlSocket: String)] = []
    if let token, let controlSocket { targets.append((token, controlSocket)) }
    for pending in pendings where pending.block != nil {
      if let controlSocket = pending.controlSocket { targets.append((pending.token, controlSocket)) }
    }
    return targets
  }

  mutating func record(_ pending: Pending) {
    pendings.removeAll { earlier in
      pending.block == nil || earlier.block == nil || earlier.controlSocket == nil
        || earlier.controlSocket != pending.controlSocket
    }
    pendings.append(pending)
    lastSeq[pending.token] = nil
  }

  mutating func discard(_ token: String) {
    pendings.removeAll { $0.token == token }
    lastSeq[token] = nil
  }

  private func keepingPendingSeqs(_ tokens: Set<String> = []) -> [String: Int] {
    let kept = tokens.union(pendings.map(\.token))
    return lastSeq.filter { kept.contains($0.key) }
  }

  func follows(_ file: URL) -> Bool {
    followedFile == canonicalPath(file.path)
  }

  mutating func adopt(_ pending: Pending, block: String) {
    self.block = block
    token = pending.token
    kind = pending.kind
    controlSocket = pending.controlSocket
    if let index = pendings.firstIndex(where: { $0.token == pending.token }) {
      pendings.removeFirst(index + 1)
    }
    lastSeq = keepingPendingSeqs([pending.token])
  }

  mutating func adoptPlain(block: String, kind: EditorKind) {
    self.block = block
    self.kind = kind
    token = nil
    controlSocket = nil
    followedFile = nil
    lastSeq = keepingPendingSeqs()
  }

  mutating func unlink() {
    block = nil
    token = nil
    kind = nil
    controlSocket = nil
    followedFile = nil
    bufferToken = nil
    lastSeq = keepingPendingSeqs()
  }
}

extension EditorMessage {
  fileprivate var confirmsLink: Bool {
    switch self {
    case .cursor, .buffer, .clean, .follow: true
    case .unlinked, .exit, .edit: false
    }
  }
}

@MainActor
public final class EditorCoordinator {
  public nonisolated static let rexTimeout: TimeInterval = 10
  public nonisolated static let busyMessage = "Still opening the editor"
  public nonisolated static let notInRexMessage = "Not in a Rex pane; editing here"
  public nonisolated static let focusedMessage = "Focused the editor"
  public nonisolated static let unreachableMessage = "Could not reach Neovim"
  public nonisolated static let alreadyEditingMessage = "Already editing in another pane"
  public nonisolated static let relinkedMessage = "Editor linked to another preview"
  public nonisolated static let closedMessage = "Editor closed"
  public nonisolated static let unrecordedMessage = "Could not record the editor; another e may open a second one"

  public nonisolated static func liveSyncUnavailable(_ reason: String) -> String {
    "Neovim live sync unavailable (\(reason)); refreshing on save"
  }

  public let context: EditorContext
  public private(set) var link = EditorLinkState()
  private(set) var isBusy = false
  public var onHandoff: (EditorLaunch, [StatusMessage]) -> Void = { _, _ in }
  weak var host: ViewerHost?
  nonisolated let queue = DispatchQueue(label: "md-viewer.editor")
  nonisolated let work: EditorWork
  let watches: PaneWatches?
  private var isShutDown = false

  public init(context: EditorContext, system: EditorSystem = EditorSystem()) {
    self.context = context
    work = EditorWork(context: context, system: system)
    if let session = context.session, let launch = system.paneWait ?? context.rexPath.map(RexWaitProcess.launcher) {
      watches = PaneWatches(session: session, launch: launch)
    } else {
      watches = nil
    }
    watches?.onFinish = { [unowned self] block, generation, output in
      watchFinished(block, generation: generation, output: output)
    }
  }

  var buffersDirectory: URL { context.paths.buffersDirectory }

  var watchedBlocks: Set<String> { watches?.blocks ?? [] }

  public func shutdown() {
    isShutDown = true
    watches?.stopAll()
  }

  // MARK: Presses

  public func edit(_ request: EditRequest, fromSocket: Bool = false) {
    guard let file = host?.interaction.file, begin() else { return }
    let job = EditJob(request: request, file: file.standardizedFileURL, fromSocket: fromSocket, link: link)
    queue.async { [self] in run(job) }
  }

  public func openPicker() {
    guard begin() else { return }
    queue.async { [self] in
      work.refreshLoginEnvironment()
      let settings = work.settings()
      let candidates = work.candidates()
      finish(Outcome(notices: work.loginNotices) { $0.host?.showEditorPicker(candidates, mode: settings.editMode) })
    }
  }

  public func choose(_ candidate: EditorCandidate, mode: EditMode, pending: EditRequest?) {
    guard begin() else { return }
    let file = host?.interaction.file?.standardizedFileURL
    let snapshot = link
    queue.async { [self] in
      do {
        try SettingsStore.update(
          context.paths, set: [.editor: candidate.name, .editMode: mode.rawValue], unset: [.editorKind])
      } catch {
        return finish(Outcome(status: ("Could not save the editor setting", .error)))
      }
      guard let pending, let file else { return finish(Outcome { $0.host?.setEditMode(mode) }) }
      run(EditJob(request: pending, file: file, fromSocket: false, link: snapshot))
    }
  }

  public func jump(line: Int) {
    let targets = link.jumpTargets
    guard !targets.isEmpty else { return }
    let send = work.system.sendControl
    queue.async {
      for target in targets {
        _ = send(.jump(token: target.token, line: line), URL(fileURLWithPath: target.controlSocket))
      }
    }
  }

  public func refreshEnvironment() {
    queue.async { [work] in work.forgetLoginEnvironment() }
  }

  private func begin() -> Bool {
    guard !isShutDown else { return false }
    guard !isBusy else {
      host?.showEditorStatus(Self.busyMessage, kind: .info)
      return false
    }
    isBusy = true
    return true
  }

  // MARK: Plugin messages and link state

  func accept(_ message: EditorMessage, shownFile: URL?) -> Bool {
    let current = link.token
    let accepted = link.accept(message, shownFile: shownFile)
    if link.token != current, let block = link.block { watches?.start(block) }
    if accepted, case .buffer(let envelope, _) = message { link.bufferToken = envelope.token }
    if accepted, case .clean = message { link.bufferToken = nil }
    return accepted
  }

  public func liveFollow(token: String, file: String) {
    guard let block = link.block(owning: token) else { return }
    queue.async { [work] in work.addFile(file, block: block) }
  }

  func unlinked(token: String) -> Bool {
    if link.pending(for: token) != nil {
      discardPending(token)
      return false
    }
    guard token == link.token else { return false }
    if let block = link.block, !link.pendings.contains(where: { $0.block == block }) { watches?.stop(block) }
    link.unlink()
    return true
  }

  func exited(token: String) {
    if token == link.token, let block = link.block { return blockEnded(block) }
    guard let pending = link.pending(for: token) else { return }
    if let block = pending.block { return blockEnded(block) }
    discardPending(token)
    host?.editorEnded(status: Self.closedMessage)
  }

  func recordPending(_ pending: EditorLinkState.Pending) {
    link.record(pending)
  }

  func discardPending(_ token: String) {
    guard link.pending(for: token) != nil else { return }
    link.discard(token)
    guard link.bufferToken == token else { return }
    link.bufferToken = nil
    host?.dropLiveBuffer()
  }

  func attachPending(_ token: String, block: String) -> Bool {
    guard let pending = link.pending(for: token) else { return false }
    link.adopt(pending, block: block)
    host?.editorLinkChanged()
    return true
  }

  func adoptPlain(block: String, kind: EditorKind) {
    link.adoptPlain(block: block, kind: kind)
    watches?.start(block)
    host?.editorLinkChanged()
  }

  func watch(_ block: String) {
    watches?.start(block)
  }

  func isLinked(to block: String) -> Bool {
    block == link.block || link.pendings.contains { $0.block == block }
  }

  func blockEnded(_ block: String) {
    watches?.stop(block)
    queue.async { [work] in work.remove(block: block) }
    guard isLinked(to: block) else { return }
    for pending in link.pendings where pending.block == block { discardPending(pending.token) }
    guard block == link.block || link.block == nil else { return }
    link.unlink()
    host?.editorEnded(status: Self.closedMessage)
  }

  func watchFinished(_ block: String, generation: Int, output: Data) {
    if RexEditorPane.classifyWait(stdout: output) == .ended { return blockEnded(block) }
    queue.async { [self] in
      let state = work.blockState(block)
      onMain { state == .notFound ? $0.blockEnded(block) : $0.watches?.retry(block, generation: generation) }
    }
  }

  // MARK: Queue work

  struct EditJob: Sendable {
    var request: EditRequest
    var file: URL
    var fromSocket: Bool
    var link: EditorLinkState
  }

  struct Outcome: Sendable {
    var notices: [String] = []
    var status: (text: String, kind: StatusMessage.Kind)?
    var handoff: EditorLaunch?
    var then: (@MainActor @Sendable (EditorCoordinator) -> Void)?

    init(
      notices: [String] = [], status: (text: String, kind: StatusMessage.Kind)? = nil, handoff: EditorLaunch? = nil,
      then: (@MainActor @Sendable (EditorCoordinator) -> Void)? = nil
    ) {
      self.notices = notices
      self.status = status
      self.handoff = handoff
      self.then = then
    }
  }

  nonisolated func onMain(_ body: @escaping @MainActor @Sendable (EditorCoordinator) -> Void) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isShutDown else { return }
        body(self)
      }
    }
  }

  nonisolated func onMainSync<T: Sendable>(_ body: @MainActor (EditorCoordinator) -> T) -> T {
    DispatchQueue.main.sync { MainActor.assumeIsolated { body(self) } }
  }

  nonisolated func finish(_ outcome: Outcome) {
    onMain { coordinator in
      coordinator.isBusy = false
      if let launch = outcome.handoff {
        outcome.then?(coordinator)
        var statuses = outcome.notices.map { StatusMessage($0) }
        if let status = outcome.status { statuses.append(StatusMessage(status.text, kind: status.kind)) }
        coordinator.onHandoff(launch, statuses)
        return
      }
      for notice in outcome.notices { coordinator.host?.showEditorStatus(notice, kind: .info) }
      outcome.then?(coordinator)
      if let status = outcome.status { coordinator.host?.showEditorStatus(status.text, kind: status.kind) }
    }
  }

  nonisolated func run(_ job: EditJob) {
    let settings = work.settings()
    let resolution = work.resolve(settings)
    var outcome: Outcome
    switch resolution.outcome {
    case .needsPicker:
      let candidates = work.candidates()
      outcome = Outcome { $0.host?.showEditorPicker(candidates, mode: settings.editMode, pending: job.request) }
    case .stopped(let message):
      outcome = Outcome(status: (message, .error))
    case .resolved(let editor):
      let configured = settings.editMode
      let mode = job.request.mode == .configured ? configured : (configured == .split ? .here : .split)
      outcome = start(editor, mode: mode, job: job)
    }
    outcome.notices = resolution.notices
    let then = outcome.then
    outcome.then = { coordinator in
      coordinator.host?.setEditMode(settings.editMode)
      then?(coordinator)
    }
    finish(outcome)
  }

  nonisolated func start(_ editor: ResolvedEditor, mode: EditMode, job: EditJob) -> Outcome {
    guard let rex = work.rex else {
      if !editor.profile.runsInTerminal { return launchGUI(editor, job: job) }
      let launch = work.terminalLaunch(editor, job: job, neovim: nil)
      let status = mode == .split ? (EditorCoordinator.notInRexMessage, StatusMessage.Kind.info) : nil
      return Outcome(status: status, handoff: launch)
    }
    if job.fromSocket, mode == .here, editor.profile.runsInTerminal { work.focus(rex.block) }
    do {
      return try work.registry.withLock { lock in
        if let entry = try work.registry.lookup(
          file: job.file.path, session: rex.session, under: lock, blockState: work.blockState)
        {
          return reuse(entry, job: job, lock: lock)
        }
        if let block = job.link.block, job.link.kind == .neovim, let control = job.link.controlSocket,
          job.link.token != nil, !job.link.follows(job.file)
        {
          return relink(block: block, control: control, job: job, lock: lock, focusAfter: true)
        }
        if !editor.profile.runsInTerminal { return launchGUI(editor, job: job) }
        return mode == .split ? launchSplit(editor, job: job, lock: lock) : launchHere(editor, job: job, lock: lock)
      }
    } catch {
      return Outcome(status: ("\(error)", .error))
    }
  }

  nonisolated func reuse(_ entry: EditorEntry, job: EditJob, lock: OpenLock) -> Outcome {
    work.focus(entry.block)
    if entry.mode == .here { return Outcome(status: (EditorCoordinator.alreadyEditingMessage, .info)) }
    if entry.kind == .neovim, let control = entry.controlSocket, work.context.previewSocket != nil {
      return relink(block: entry.block, control: control, job: job, lock: lock, focusAfter: false)
    }
    let block = entry.block
    let kind = entry.kind
    return Outcome(status: (EditorCoordinator.focusedMessage, .info)) { $0.adoptPlain(block: block, kind: kind) }
  }

  nonisolated func relink(block: String, control: String, job: EditJob, lock: OpenLock, focusAfter: Bool) -> Outcome {
    guard let socket = work.context.previewSocket else { return Outcome() }
    let token = work.system.makeToken()
    onMainSync {
      $0.recordPending(EditorLinkState.Pending(token: token, block: block, kind: .neovim, controlSocket: control))
    }
    let command = EditorControlCommand.link(
      socket: socket.path, token: token, file: job.file.path, line: job.request.line)
    guard work.system.sendControl(command, URL(fileURLWithPath: control)) else {
      onMainSync { $0.discardPending(token) }
      let ended = work.blockState(block) == .notFound
      return Outcome(status: (EditorCoordinator.unreachableMessage, .error)) { coordinator in
        if ended { coordinator.blockEnded(block) }
      }
    }
    work.setPreview(block: block, under: lock)
    if focusAfter { work.focus(block) }
    return Outcome { coordinator in
      guard coordinator.link.block(owning: token) == block else { return }
      coordinator.watch(block)
      coordinator.host?.showEditorStatus(EditorCoordinator.focusedMessage, kind: .info)
    }
  }

  nonisolated func launchGUI(_ editor: ResolvedEditor, job: EditJob) -> Outcome {
    let name = editor.kind.displayName
    do {
      try work.system.launchGUI(work.terminalLaunch(editor, job: job, neovim: nil))
      return Outcome(status: ("Opened \(name)", .info))
    } catch {
      return Outcome(status: ("Could not open \(name)", .error))
    }
  }

  nonisolated func launchSplit(_ editor: ResolvedEditor, job: EditJob, lock: OpenLock) -> Outcome {
    guard let rex = work.rex else { return Outcome() }
    let (neovim, unavailable) = work.prepareNeovim(editor)
    if let neovim {
      onMainSync {
        $0.recordPending(
          EditorLinkState.Pending(token: neovim.token, block: nil, kind: .neovim, controlSocket: neovim.controlSocket))
      }
    }
    let anchor = job.link.block.map { ($0, "below") } ?? (rex.block, "left")
    let command = work.paneCommand(editor, job: job, neovim: neovim)
    let arguments = RexEditorPane.runArguments(
      session: rex.session, anchorBlock: anchor.0, directory: job.file.deletingLastPathComponent().path,
      command: command, split: anchor.1)
    let name = editor.kind.displayName
    guard let block = work.runPane(arguments, session: rex.session) else {
      if let neovim { onMainSync { $0.discardPending(neovim.token) } }
      return Outcome(status: ("Could not open \(name)", .error))
    }
    if let neovim, !onMainSync({ $0.attachPending(neovim.token, block: block) }) { return Outcome() }
    let entry = EditorEntry(
      block: block, mode: .split, session: rex.session, files: [job.file.path], kind: editor.kind,
      controlSocket: neovim?.controlSocket, preview: rex.block)
    let recorded = work.write(entry, under: lock)
    let kind = editor.kind
    let status =
      !recorded
      ? (EditorCoordinator.unrecordedMessage, StatusMessage.Kind.error)
      : (unavailable.map(EditorCoordinator.liveSyncUnavailable) ?? "Opened \(name)", StatusMessage.Kind.info)
    return Outcome(status: status) { coordinator in
      if neovim == nil { coordinator.adoptPlain(block: block, kind: kind) } else { coordinator.watch(block) }
    }
  }

  nonisolated func launchHere(_ editor: ResolvedEditor, job: EditJob, lock: OpenLock) -> Outcome {
    guard let rex = work.rex else { return Outcome() }
    let (neovim, unavailable) = work.prepareNeovim(editor)
    if let neovim {
      onMainSync {
        $0.recordPending(
          EditorLinkState.Pending(
            token: neovim.token, block: rex.block, kind: .neovim, controlSocket: neovim.controlSocket))
      }
    }
    let entry = EditorEntry(
      block: rex.block, mode: .here, session: rex.session, files: [job.file.path], kind: editor.kind,
      controlSocket: neovim?.controlSocket, preview: rex.block)
    let recorded = work.write(entry, under: lock)
    let launch = work.terminalLaunch(editor, job: job, neovim: neovim)
    var status = unavailable.map { (EditorCoordinator.liveSyncUnavailable($0), StatusMessage.Kind.info) }
    if !recorded { status = (EditorCoordinator.unrecordedMessage, .error) }
    return Outcome(status: status, handoff: launch) { coordinator in
      if let neovim { _ = coordinator.attachPending(neovim.token, block: rex.block) }
    }
  }

  // MARK: Defaults

  public nonisolated static func randomToken() -> String {
    var generator = SystemRandomNumberGenerator()
    return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
  }

  public nonisolated static func launchProcess(_ launch: EditorLaunch) throws {
    guard let executable = launch.command.first else { throw CocoaError(.executableNotLoadable) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = Array(launch.command.dropFirst())
    process.environment = launch.environment
    process.currentDirectoryURL = launch.directory
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
  }
}

struct NeovimSetup: Sendable {
  var token: String
  var controlSocket: String
  var filesSidecar: String
}

final class EditorWork: @unchecked Sendable {
  struct Rex {
    var path: String
    var session: String
    var block: String
  }

  let context: EditorContext
  let system: EditorSystem
  let registry: EditorRegistry
  private var login: LoginEnvironment?
  private(set) var loginNotices: [String] = []

  init(context: EditorContext, system: EditorSystem) {
    self.context = context
    self.system = system
    registry = EditorRegistry(paths: context.paths)
  }

  var rex: Rex? {
    guard let path = context.rexPath, let session = context.session, let block = context.block else { return nil }
    return Rex(path: path, session: session, block: block)
  }

  func settings() -> Settings {
    SettingsStore.load(context.paths)
  }

  func loginEnvironment() -> LoginEnvironment {
    if let login { return login }
    let probed = LoginEnvironment.probe(
      runner: system.runner, ownEnvironment: context.ownEnvironment, isExecutable: system.isExecutable)
    login = probed
    loginNotices = probed.notice.map { [$0] } ?? []
    return probed
  }

  func forgetLoginEnvironment() {
    login = nil
  }

  func refreshLoginEnvironment() {
    forgetLoginEnvironment()
    _ = loginEnvironment()
  }

  func resolver(_ settings: Settings) -> EditorResolver {
    EditorResolver(
      settings: settings, ownEnvironment: context.ownEnvironment, loginEnvironment: { self.loginEnvironment() },
      isExecutable: system.isExecutable)
  }

  func resolve(_ settings: Settings) -> EditorResolution {
    resolver(settings).resolve()
  }

  func candidates() -> [EditorCandidate] {
    resolver(settings()).candidates()
  }

  @discardableResult
  func rexCommand(_ arguments: [String]) -> (status: Int32, stdout: Data, stderr: Data)? {
    guard let path = context.rexPath else { return nil }
    return try? system.runner.run(path, arguments, timeout: EditorCoordinator.rexTimeout)
  }

  func focus(_ block: String) {
    guard let session = context.session else { return }
    rexCommand(RexEditorPane.focusArguments(block: block) + ["-s", session])
  }

  func blockState(_ block: String) -> BlockState {
    guard let session = context.session,
      let result = rexCommand(RexEditorPane.inspectArguments(block: block, session: session))
    else { return .unknown }
    return RexEditorPane.classifyInspect(block: block, status: result.status, stderr: result.stderr)
  }

  func runPane(_ arguments: [String], session: String) -> String? {
    let known = Set(registry.entries().filter { $0.session == session }.map(\.block))
    guard let result = rexCommand(arguments), result.status == 0 else { return nil }
    if let block = RexEditorPane.blockID(runJSON: result.stdout) { return block }
    guard let list = rexCommand(RexEditorPane.blockListArguments(session: session)), list.status == 0 else {
      return nil
    }
    return RexEditorPane.fallbackBlockID(blockListJSON: list.stdout, excluding: known)
  }

  func prepareNeovim(_ editor: ResolvedEditor) -> (setup: NeovimSetup?, unavailable: String?) {
    guard editor.kind == .neovim else { return (nil, nil) }
    func unavailable(_ reason: String, _ detail: String = "") -> (NeovimSetup?, String?) {
      system.log("editor: Neovim live sync unavailable: \(reason)\(detail)")
      return (nil, reason)
    }
    guard context.previewSocket != nil else { return unavailable("no preview socket") }
    let paths = context.paths
    let digest = SHA256.hash(data: Data(UUID().uuidString.utf8))
    let id = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    let control = paths.neovimControlSocket(id: id)
    guard socketAddress(path: control.path) != nil else {
      return unavailable("socket path too long", ": \(control.path)")
    }
    do {
      _ = try NeovimPlugin.install(paths)
      for directory in [paths.neovimSocketsDirectory, paths.buffersDirectory] {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      }
    } catch {
      return unavailable("plugin install failed", ": \(error)")
    }
    let setup = NeovimSetup(
      token: system.makeToken(), controlSocket: control.path, filesSidecar: paths.neovimFiles(id: id).path)
    return (setup, nil)
  }

  func neovimLaunch(_ neovim: NeovimSetup) -> NeovimLaunch? {
    guard let socket = context.previewSocket else { return nil }
    return NeovimLaunch(
      socket: socket.path, token: neovim.token, controlSocket: neovim.controlSocket,
      filesSidecar: neovim.filesSidecar, buffersDirectory: context.paths.buffersDirectory.path,
      plugin: context.paths.neovimPlugin.path)
  }

  func paneCommand(
    _ editor: ResolvedEditor, job: EditorCoordinator.EditJob, neovim: NeovimSetup?
  ) -> [String] {
    let profile = editor.profile
    if let neovim, let launch = neovimLaunch(neovim),
      let command = profile.neovimCommand(
        executable: editor.executable, words: editor.words, file: job.file.path, line: job.request.line,
        launch: launch)
    {
      return command
    }
    return profile.commandLine(
      executable: editor.executable, words: editor.words, file: job.file.path, line: job.request.line)
  }

  func terminalLaunch(
    _ editor: ResolvedEditor, job: EditorCoordinator.EditJob, neovim: NeovimSetup?
  ) -> EditorLaunch {
    var environment = loginEnvironment().variables
    var command = paneCommand(editor, job: job, neovim: neovim)
    if command.first == "/usr/bin/env", neovim != nil {
      let assignments = command.dropFirst().prefix { $0.hasPrefix("MD_VIEWER_") }
      for assignment in assignments {
        let parts = assignment.split(separator: "=", maxSplits: 1)
        environment[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
      }
      command = Array(command.dropFirst(1 + assignments.count))
    }
    return EditorLaunch(
      command: command, environment: environment, directory: job.file.deletingLastPathComponent(),
      kind: editor.kind, block: rex?.block, token: neovim?.token)
  }

  func write(_ entry: EditorEntry, under lock: OpenLock) -> Bool {
    attempt("write the entry for \(entry.block)") { try registry.write(entry, under: lock) }
  }

  func setPreview(block: String, under lock: OpenLock) {
    guard let preview = context.block else { return }
    attempt("set the preview of \(block)") { _ = try registry.setPreview(preview, block: block, under: lock) }
  }

  func addFile(_ file: String, block: String) {
    attempt("add \(file) to \(block)") {
      _ = try registry.withLock { try registry.addFile(file, block: block, under: $0) }
    }
  }

  func remove(block: String) {
    attempt("remove the entry for \(block)") {
      _ = try registry.withLock { try registry.remove(block: block, under: $0) }
    }
  }

  @discardableResult
  private func attempt(_ action: String, _ body: () throws -> Void) -> Bool {
    do {
      try body()
      return true
    } catch {
      system.log("editor: could not \(action): \(error)")
      return false
    }
  }
}
