import XCTest

@testable import MDViewerCore

final class SettingsTests: XCTestCase {
  private func paths() throws -> SupportPaths {
    let paths = SupportPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
    return paths
  }

  private func raw(_ paths: SupportPaths) throws -> [String: Any] {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.configFile)) as? [String: Any])
  }

  func testDefaultsWhenFileIsMissingOrCorrupt() throws {
    let paths = try paths()
    XCTAssertEqual(SettingsStore.load(paths), Settings())
    try Data("not json".utf8).write(to: paths.configFile)
    XCTAssertEqual(SettingsStore.load(paths), Settings())
    XCTAssertEqual(Settings().previews, .perFile)
    XCTAssertEqual(Settings().editMode, .split)
    XCTAssertNil(Settings().editor)
    XCTAssertNil(Settings().editorKind)
  }

  func testDecodesWithoutRexPath() throws {
    let json = #"{"previews":"single","editMode":"here","editor":"nvim -u NONE","editorKind":"neovim"}"#
    let settings = Settings(data: Data(json.utf8))
    XCTAssertEqual(settings.previews, .single)
    XCTAssertEqual(settings.editMode, .here)
    XCTAssertEqual(settings.editor, "nvim -u NONE")
    XCTAssertEqual(settings.editorKind, .neovim)
  }

  func testDecodesAlongsideRexPath() {
    let json = #"{"rexPath":"/r","mdViewerPath":"/m","previousHandlers":{},"editMode":"here"}"#
    XCTAssertEqual(Settings(data: Data(json.utf8)).editMode, .here)
  }

  func testBadValuesFallBack() {
    let json = #"{"previews":"tabs","editMode":3,"editor":["vim"],"editorKind":"emacs2"}"#
    XCTAssertEqual(Settings(data: Data(json.utf8)), Settings())
    XCTAssertNil(Settings(data: Data(#"{"editor":""}"#.utf8)).editor)
    XCTAssertEqual(Settings(data: Data("[1]".utf8)), Settings())
  }

  func testEveryEditorKindDecodes() {
    for kind in EditorKind.allCases {
      let json = #"{"editorKind":""# + kind.rawValue + #""}"#
      XCTAssertEqual(Settings(data: Data(json.utf8)).editorKind, kind)
    }
    XCTAssertEqual(
      Set(EditorKind.allCases.map(\.rawValue)),
      [
        "neovim", "vim", "helix", "emacs", "nano", "micro", "kakoune", "vscode", "cursor", "zed", "sublime",
        "terminal",
      ])
  }

  func testUpdateKeepsUnknownKeysAndOtherSettings() throws {
    let paths = try paths()
    let json = #"{"rexPath":"/r","future":[1,2],"editor":"vim","editMode":"here"}"#
    try Data(json.utf8).write(to: paths.configFile)
    try SettingsStore.update(paths, set: [.editorKind: "vim"], unset: [.editor])
    let object = try raw(paths)
    XCTAssertEqual(object["future"] as? [Int], [1, 2])
    XCTAssertEqual(object["rexPath"] as? String, "/r")
    XCTAssertEqual(object["editMode"] as? String, "here")
    XCTAssertEqual(object["editorKind"] as? String, "vim")
    XCTAssertNil(object["editor"])
    let mode = try FileManager.default.attributesOfItem(atPath: paths.configFile.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
  }

  func testUpdateCreatesTheFileWhenMissing() throws {
    let paths = SupportPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    try SettingsStore.update(paths, set: [.editMode: "here"])
    XCTAssertEqual(SettingsStore.load(paths).editMode, .here)
  }

  func testUpdateRejectsInvalidEnumValuesAndWritesNothing() throws {
    let paths = try paths()
    for (key, value) in [
      (SettingKey.previews, "tabs"), (.editMode, "float"), (.editorKind, "ed"), (.editor, "  "),
    ] {
      XCTAssertThrowsError(try SettingsStore.update(paths, set: [key: value]), key.rawValue)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configFile.path))
  }

  func testConcurrentUpdatesLoseNothing() throws {
    let paths = try paths()
    let count = 20
    let errors = ErrorBox()
    DispatchQueue.concurrentPerform(iterations: count) { index in
      do {
        if index.isMultiple(of: 2) {
          try SettingsStore.update(paths, set: [.editor: "ed\(index)"])
        } else {
          try ConfigStore.save(
            Config(rexPath: "/r\(index)", mdViewerPath: "/m", previousHandlers: [:]), paths)
        }
        try SettingsStore.update(paths, set: [.editMode: index.isMultiple(of: 4) ? "here" : "split"])
      } catch {
        errors.add(error)
      }
    }
    XCTAssertEqual(errors.count, 0)
    let object = try raw(paths)
    XCTAssertNotNil(object["editor"])
    XCTAssertNotNil(object["rexPath"])
    XCTAssertNotNil(object["editMode"])
  }

  func testConfigSaveKeepsTheEditorKeys() throws {
    let paths = try paths()
    try SettingsStore.update(paths, set: [.editor: "hx", .editorKind: "helix", .editMode: "here", .previews: "single"])
    try ConfigStore.save(Config(rexPath: "/r", mdViewerPath: "/m", previousHandlers: [:]), paths)
    let settings = SettingsStore.load(paths)
    XCTAssertEqual(settings.editor, "hx")
    XCTAssertEqual(settings.editorKind, .helix)
    XCTAssertEqual(settings.editMode, .here)
    XCTAssertEqual(settings.previews, .single)
    XCTAssertEqual(try ConfigStore.load(paths)?.rexPath, "/r")
  }

  func testNewSupportPaths() {
    let paths = SupportPaths(home: URL(fileURLWithPath: "/Users/x"))
    let root = "/Users/x/Library/Application Support/md-viewer"
    XCTAssertEqual(paths.configLock.path, "\(root)/config.lock")
    XCTAssertEqual(paths.editLock.path, "\(root)/edit.lock")
    XCTAssertEqual(paths.buffersDirectory.path, "\(root)/buffers")
    XCTAssertEqual(paths.editorsDirectory.path, "\(root)/editors")
    XCTAssertEqual(paths.neovimPlugin.path, "\(root)/nvim/md-viewer.lua")
    XCTAssertEqual(paths.neovimSocketsDirectory.path, "\(root)/nvim-sockets")
    XCTAssertEqual(paths.neovimControlSocket(id: "ab").path, "\(root)/nvim-sockets/ab.sock")
    XCTAssertEqual(paths.neovimFiles(id: "ab").path, "\(root)/nvim-sockets/ab.files")
  }
}

private final class ErrorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var errors: [Error] = []
  var count: Int { lock.withLock { errors.count } }
  func add(_ error: Error) { lock.withLock { errors.append(error) } }
}
