import Foundation

public enum ResourceLocator {
  public static func directories(executable: URL? = Bundle.main.executableURL, anchors: [URL]) -> [URL] {
    var directories = anchors
    if let executable = executable?.resolvingSymlinksInPath() {
      let directory = executable.deletingLastPathComponent()
      directories.append(directory)
      directories.append(directory.appendingPathComponent("../libexec").standardizedFileURL)
    }
    return directories
  }
}
