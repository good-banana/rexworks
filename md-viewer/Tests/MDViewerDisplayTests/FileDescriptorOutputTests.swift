import Darwin
import XCTest

@testable import MDViewerDisplay

final class FileDescriptorOutputTests: XCTestCase {
  func testWritesEverythingToTheDescriptor() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(pipe(&fds), 0)
    defer { close(fds[0]) }
    let output = FileDescriptorOutput(descriptor: fds[1])
    output.write("hello \u{1b}_Gi=1\u{1b}\\")
    close(fds[1])
    let data = FileHandle(fileDescriptor: fds[0]).readDataToEndOfFile()
    XCTAssertEqual(String(decoding: data, as: UTF8.self), "hello \u{1b}_Gi=1\u{1b}\\")
  }

  func testWaitsForTheDescriptorOnEAGAIN() {
    let output = FileDescriptorOutput(descriptor: 99)
    var written: [UInt8] = []
    var attempts = 0
    var waits = 0
    output.systemWrite = { _, pointer, count in
      attempts += 1
      if attempts == 2 {
        errno = EAGAIN
        return -1
      }
      let chunk = min(count, 3)
      written += Array(UnsafeRawBufferPointer(start: pointer, count: chunk))
      return chunk
    }
    output.waitWritable = { _ in
      waits += 1
      return true
    }
    output.write("abcdefg")
    XCTAssertEqual(String(decoding: written, as: UTF8.self), "abcdefg")
    XCTAssertEqual(waits, 1)
  }

  func testPartialFailureClosesTheOpenSequence() {
    let output = FileDescriptorOutput(descriptor: 99)
    var written: [UInt8] = []
    var failed = false
    output.systemWrite = { _, pointer, count in
      if !failed, written.count >= 5 {
        failed = true
        errno = EPIPE
        return -1
      }
      let chunk = failed ? count : min(count, 5)
      written += Array(UnsafeRawBufferPointer(start: pointer, count: chunk))
      return chunk
    }
    output.write("\u{1b}_Ga=t,i=1;payload\u{1b}\\")
    XCTAssertEqual(String(decoding: written, as: UTF8.self), "\u{1b}_Ga=\u{1b}\\")
  }

  func testWritableTimeoutGivesUpWithoutClosingWhenNothingWasWritten() {
    let output = FileDescriptorOutput(descriptor: 99)
    var calls = 0
    output.systemWrite = { _, _, _ in
      calls += 1
      errno = EAGAIN
      return -1
    }
    output.waitWritable = { _ in false }
    output.write("abc")
    XCTAssertEqual(calls, 1)
  }
}
