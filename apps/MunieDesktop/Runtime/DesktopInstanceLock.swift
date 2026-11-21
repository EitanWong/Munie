import Darwin
import Foundation

/// Owns the app's launch slot for the lifetime of the process, independent of the app bundle path.
final class DesktopInstanceLock {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit { close(descriptor) }

  static func acquire(in directory: URL) throws -> DesktopInstanceLock? {
    let path = directory.appending(path: ".desktop-instance.lock").path
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard fd >= 0 else { throw posixError() }
    var transferOwnership = false
    defer { if !transferOwnership { close(fd) } }
    var metadata = stat()
    guard fstat(fd, &metadata) == 0 else { throw posixError() }
    guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
      metadata.st_nlink == 1, metadata.st_mode & 0o077 == 0
    else { throw POSIXError(.EPERM) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { return nil }
      throw posixError()
    }
    // Keep the inode after exit so contenders always lock the same file.
    transferOwnership = true
    return DesktopInstanceLock(descriptor: fd)
  }

  private static func posixError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
}
