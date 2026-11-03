import CoreGraphics
import Darwin
import Foundation
import MDViewerCore

public struct SVGRenderProcess: Sendable {
  public static let command = "__render-svg"
  public static let protocolVersion = "1"
  public static let defaultTimeout: TimeInterval = 2
  public static let defaultMemoryLimit: UInt64 = 512 << 20
  static let requestHeaderSize = 5 * 8
  static let responseTrailerSize = 4 * 8
  static let pollInterval: Int32 = 5

  public var executable: URL?
  public var launchPath: URL?
  public var timeout: TimeInterval
  public var memoryLimit: UInt64

  public init(
    executable: URL? = Bundle.main.executableURL?.resolvingSymlinksInPath(), launchPath: URL? = nil,
    timeout: TimeInterval = defaultTimeout, memoryLimit: UInt64 = defaultMemoryLimit
  ) {
    self.executable = executable
    self.launchPath = launchPath
    self.timeout = timeout
    self.memoryLimit = memoryLimit
  }

  public func render(_ svg: Data, limits: ImageStore.Limits, dimension: Int?) -> LoadedImage? {
    guard let executable,
      let output = run(
        executable, input: Self.request(svg, limits: limits, dimension: dimension, timeout: timeout),
        outputLimit: limits.maximumPixels * 4 + Self.responseTrailerSize)
    else { return nil }
    return Self.response(output, limits: limits)
  }

  public static func serve(
    arguments: [String], input: FileHandle = .standardInput, output: FileHandle = .standardOutput
  ) -> Int32 {
    guard arguments == [protocolVersion] else { return 2 }
    let request = input.readDataToEndOfFile()
    guard request.count >= requestHeaderSize else { return 1 }
    let fields = (0..<5).map { integer(in: request, at: $0 * 8) }
    alarm(UInt32(min(max(fields[4] / 1000 + 1, 1), 60)))
    var limits = ImageStore.Limits()
    limits.maximumSourcePixels = fields[0]
    limits.maximumPixels = fields[1]
    limits.maximumDimension = fields[2]
    let svg = request.subdata(in: requestHeaderSize..<request.count)
    guard limits.maximumPixels > 0, limits.maximumDimension > 0, ImageStore.vectorWeight(of: svg) != nil,
      let (context, size) = ImageStore.rasterizeSVG(svg, limits: limits, dimension: fields[3] < 0 ? nil : fields[3]),
      context.bytesPerRow == context.width * 4, let pixels = context.data
    else { return 1 }
    var trailer = Data()
    for value in [context.width, context.height] { append(value, to: &trailer) }
    for value in [size.width, size.height] { append(Int(bitPattern: UInt(value.bitPattern)), to: &trailer) }
    do {
      try output.write(
        contentsOf: Data(bytesNoCopy: pixels, count: context.bytesPerRow * context.height, deallocator: .none))
      try output.write(contentsOf: trailer)
    } catch {
      return 1
    }
    return 0
  }

  static func request(_ svg: Data, limits: ImageStore.Limits, dimension: Int?, timeout: TimeInterval) -> Data {
    var data = Data(capacity: requestHeaderSize + svg.count)
    let milliseconds = Int((timeout * 1000).rounded(.up))
    for value in [
      limits.maximumSourcePixels, limits.maximumPixels, limits.maximumDimension, dimension ?? -1, milliseconds,
    ] {
      append(value, to: &data)
    }
    data.append(svg)
    return data
  }

  static func response(_ output: Data, limits: ImageStore.Limits) -> LoadedImage? {
    guard output.count >= responseTrailerSize else { return nil }
    let trailer = output.suffix(responseTrailerSize)
    let width = integer(in: trailer, at: 0)
    let height = integer(in: trailer, at: 8)
    let size = CGSize(
      width: Double(bitPattern: UInt64(UInt(bitPattern: integer(in: trailer, at: 16)))),
      height: Double(bitPattern: UInt64(UInt(bitPattern: integer(in: trailer, at: 24)))))
    guard width > 0, height > 0, width <= limits.maximumPixels, height <= limits.maximumPixels,
      width * height <= limits.maximumPixels, output.count - responseTrailerSize == width * height * 4,
      size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
      size.width * size.height <= CGFloat(limits.maximumSourcePixels),
      let provider = CGDataProvider(data: output as CFData),
      let space = CGColorSpace(name: CGColorSpace.sRGB),
      let image = CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { return nil }
    return LoadedImage(image: image, size: size, isVector: true)
  }

  private static func append(_ value: Int, to data: inout Data) {
    withUnsafeBytes(of: Int64(value).littleEndian) { data.append(contentsOf: $0) }
  }

  private static func integer(in data: Data, at offset: Int) -> Int {
    var value: Int64 = 0
    _ = withUnsafeMutableBytes(of: &value) {
      data.copyBytes(to: $0, from: (data.startIndex + offset)..<(data.startIndex + offset + 8))
    }
    return Int(Int64(littleEndian: value))
  }

  static func replacement(for missing: URL, launchPath: URL?) -> URL? {
    guard let resolved = launchPath?.resolvingSymlinksInPath(), resolved.path != missing.path,
      isRegularFile(resolved.path), access(resolved.path, X_OK) == 0
    else { return nil }
    return resolved
  }

  func spawn(_ executable: URL) -> Child? {
    let arguments = [Self.command, Self.protocolVersion]
    switch Child.spawn(executable, arguments: arguments) {
    case .success(let child): return child
    case .failure(let failure) where failure.code == ENOENT:
      return Self.replacement(for: executable, launchPath: launchPath)
        .flatMap { try? Child.spawn($0, arguments: arguments).get() }
    case .failure: return nil
    }
  }

  func run(_ executable: URL, input: Data, outputLimit: Int) -> Data? {
    guard let child = spawn(executable) else { return nil }
    defer { child.finish() }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(timeout, 0) * 1_000_000_000)
    var written = 0
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline, child.footprint() <= memoryLimit else { return nil }
      if child.output < 0 {
        guard let status = child.reap() else {
          poll(nil, 0, Self.pollInterval)
          continue
        }
        return status == 0 ? output : nil
      }
      var descriptors = [pollfd(fd: child.output, events: Int16(POLLIN), revents: 0)]
      if child.input >= 0 { descriptors.append(pollfd(fd: child.input, events: Int16(POLLOUT), revents: 0)) }
      let wait = Int32(min(UInt64(Self.pollInterval), (deadline - now) / 1_000_000 + 1))
      guard poll(&descriptors, nfds_t(descriptors.count), wait) >= 0 || errno == EINTR else { return nil }
      if child.input >= 0, descriptors.count > 1, descriptors[1].revents != 0 {
        let count = input.withUnsafeBytes { bytes in
          Darwin.write(child.input, bytes.baseAddress! + written, min(bytes.count - written, 1 << 16))
        }
        if count >= 0 {
          written += count
          if written == input.count { child.closeInput() }
        } else if errno != EAGAIN, errno != EINTR {
          child.closeInput()
        }
      }
      guard descriptors[0].revents != 0 else { continue }
      while true {
        let count = read(child.output, &buffer, buffer.count)
        if count > 0 {
          output.append(buffer, count: count)
          guard output.count <= outputLimit else { return nil }
        } else if count == 0 {
          child.closeOutput()
          break
        } else if errno == EINTR {
          continue
        } else if errno == EAGAIN {
          break
        } else {
          return nil
        }
      }
    }
  }
}

struct SpawnFailure: Error {
  let code: Int32
}

final class Child {
  let pid: pid_t
  private(set) var input: Int32
  private(set) var output: Int32
  private var reaped = false

  private init(pid: pid_t, input: Int32, output: Int32) {
    self.pid = pid
    self.input = input
    self.output = output
  }

  static func spawn(_ executable: URL, arguments: [String]) -> Result<Child, SpawnFailure> {
    var toChild: [Int32] = [-1, -1]
    var fromChild: [Int32] = [-1, -1]
    guard pipe(&toChild) == 0 else { return .failure(SpawnFailure(code: errno)) }
    guard pipe(&fromChild) == 0 else {
      let code = errno
      for descriptor in toChild { close(descriptor) }
      return .failure(SpawnFailure(code: code))
    }
    let descriptors = toChild + fromChild
    for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_adddup2(&actions, toChild[0], STDIN_FILENO)
    posix_spawn_file_actions_adddup2(&actions, fromChild[1], STDOUT_FILENO)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    var noSignals = sigset_t()
    var allSignals = sigset_t()
    sigemptyset(&noSignals)
    sigfillset(&allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    posix_spawnattr_setflags(
      &attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    let path = executable.path
    let argv = ([path] + arguments).map { strdup($0) } + [nil]
    defer { for argument in argv { free(argument) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
    close(toChild[0])
    close(fromChild[1])
    guard spawned == 0 else {
      close(toChild[1])
      close(fromChild[0])
      return .failure(SpawnFailure(code: spawned))
    }
    _ = fcntl(toChild[1], F_SETNOSIGPIPE, 1)
    for descriptor in [toChild[1], fromChild[0]] {
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    return .success(Child(pid: pid, input: toChild[1], output: fromChild[0]))
  }

  func footprint() -> UInt64 {
    var info = rusage_info_v2()
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
    }
    return result == 0 ? info.ri_phys_footprint : 0
  }

  func closeInput() {
    guard input >= 0 else { return }
    close(input)
    input = -1
  }

  func closeOutput() {
    guard output >= 0 else { return }
    close(output)
    output = -1
  }

  func reap() -> Int32? {
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    if result == 0 || (result < 0 && errno == EINTR) { return nil }
    reaped = true
    guard result == pid, status & 0x7f == 0 else { return -1 }
    return (status >> 8) & 0xff
  }

  func finish() {
    closeInput()
    closeOutput()
    guard !reaped else { return }
    kill(pid, SIGKILL)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0, errno == EINTR {}
    reaped = true
  }
}
