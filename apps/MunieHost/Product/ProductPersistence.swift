import Darwin
import Foundation
import MunieRemote

public enum ProductHostError: Error, Equatable, Sendable {
  case invalidConfiguration, invalidStorage, corruptStorage, storageFailure, capacityExceeded
  case unavailable, noPairingCandidate, unauthorized, closed
}

struct ProductState: Codable {
  var schema = 1
  let hostID: UUID
  var revision: UInt64 = 0
  var projects: [ProductProject] = []
  var devices: [ProductDevice] = []
  var tasks: [ProductTask] = []
  var requests: [ProductRequest] = []
}

struct ProductProject: Codable {
  let id: UUID
  let name: String
  let directory: URL
}

struct ProductDevice: Codable {
  let id: UUID
  let name: String
  let credentialDigest: String
  var projects: Set<UUID>
  var enabled = true
  var notificationToken: String?
}

struct ProductTask: Codable {
  let id: UUID
  let deviceID: UUID
  let projectID: UUID
  let title: String
  var requestID: UUID
  var phase: RemotePhase
  var cancellationRequested = false
  var messages: [RemoteMessage]
  var threadID: UUID?
  var updatedAt: Date

  func wire(approval: RemoteApproval? = nil, includeMessages: Bool = true) -> RemoteTask {
    RemoteTask(
      id: id, requestID: requestID, projectID: projectID, title: title, phase: phase,
      cancellationRequested: cancellationRequested, approval: approval,
      messages: includeMessages ? messages : [], updatedAt: updatedAt)
  }
}

struct ProductRequest: Codable {
  let id: UUID
  let deviceID: UUID
  let taskID: UUID
  let digest: String
}

/// The product history and credential digests are host-private, never in an authorized project.
/// Atomic replacement and fsync happen on the owning ProductHost actor, away from MainActor.
final class ProductPersistence {
  static let maximumBytes = 16 * 1_024 * 1_024
  let directory: URL
  private var directoryDescriptor: Int32 = -1
  private var ownerDescriptor: Int32 = -1

  init(directory: URL) throws {
    self.directory = directory
    let parent = directory.deletingLastPathComponent()
    guard directory.isFileURL, directory.path.hasPrefix("/"),
      !directory.path.utf8.contains(0),
      Self.canonicalPath(parent.path) == parent.path
    else { throw ProductHostError.invalidStorage }
    if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
      throw ProductHostError.invalidStorage
    }
    directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryDescriptor >= 0 else { throw ProductHostError.invalidStorage }
    do {
      var info = stat()
      guard fstat(directoryDescriptor, &info) == 0, info.st_uid == geteuid(),
        info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700
      else { throw ProductHostError.invalidStorage }
      ownerDescriptor = openat(
        directoryDescriptor, ".product-owner", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard ownerDescriptor >= 0 else { throw ProductHostError.invalidStorage }
      try validateFile(ownerDescriptor)
      guard flock(ownerDescriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw ProductHostError.invalidStorage
      }
      try validateDirectory()
    } catch {
      release()
      throw error
    }
  }

  deinit { release() }

  func load(hostID: UUID) throws -> ProductState {
    try validateDirectory()
    let fd = openat(
      directoryDescriptor, "history.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0 {
      guard errno == ENOENT else { throw ProductHostError.invalidStorage }
      return ProductState(hostID: hostID)
    }
    defer { Darwin.close(fd) }
    try validateFile(fd)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count >= 0 else { throw ProductHostError.storageFailure }
      if count == 0 { break }
      guard data.count + count <= Self.maximumBytes else {
        throw ProductHostError.corruptStorage
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    let state: ProductState
    do { state = try JSONDecoder().decode(ProductState.self, from: data) } catch {
      throw ProductHostError.corruptStorage
    }
    guard state.schema == 1, state.hostID == hostID, state.tasks.count <= 1_000,
      state.projects.count <= 100, state.devices.count <= 100, state.requests.count <= 10_000,
      Set(state.tasks.map(\.id)).count == state.tasks.count,
      Set(state.devices.map(\.id)).count == state.devices.count,
      Set(state.projects.map(\.id)).count == state.projects.count,
      Set(state.requests.map(\.id)).count == state.requests.count
    else { throw ProductHostError.corruptStorage }
    let projectIDs = Set(state.projects.map(\.id))
    let deviceIDs = Set(state.devices.map(\.id))
    for project in state.projects {
      guard !project.name.isEmpty, project.name.utf8.count <= 256, project.directory.isFileURL
      else {
        throw ProductHostError.corruptStorage
      }
    }
    for device in state.devices {
      guard !device.name.isEmpty, device.name.utf8.count <= 128,
        device.projects.isSubset(of: projectIDs), device.credentialDigest.utf8.count == 64,
        device.credentialDigest.utf8.allSatisfy({
          (48...57).contains($0) || (97...102).contains($0)
        })
      else { throw ProductHostError.corruptStorage }
    }
    for task in state.tasks {
      guard deviceIDs.contains(task.deviceID), projectIDs.contains(task.projectID),
        task.title.utf8.count <= 256, task.messages.count <= 512,
        try JSONEncoder().encode(task.messages).count <= 786_432,
        state.requests.contains(where: {
          $0.id == task.requestID && $0.taskID == task.id && $0.deviceID == task.deviceID
        })
      else { throw ProductHostError.corruptStorage }
    }
    return state
  }

  func save(_ state: ProductState) throws {
    try validateDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    guard data.count <= Self.maximumBytes else { throw ProductHostError.capacityExceeded }
    let temporary = ".history-\(UUID().uuidString)"
    let fd = openat(
      directoryDescriptor, temporary,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ProductHostError.storageFailure }
    defer {
      Darwin.close(fd)
      unlinkat(directoryDescriptor, temporary, 0)
    }
    try data.withUnsafeBytes { bytes in
      guard let base = bytes.baseAddress else { throw ProductHostError.storageFailure }
      var offset = 0
      while offset < bytes.count {
        let count = write(fd, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw ProductHostError.storageFailure }
        offset += count
      }
    }
    guard fsync(fd) == 0,
      renameat(directoryDescriptor, temporary, directoryDescriptor, "history.json") == 0,
      fsync(directoryDescriptor) == 0
    else { throw ProductHostError.storageFailure }
    try validateDirectory()
  }

  private func validateFile(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
      info.st_size <= Self.maximumBytes
    else { throw ProductHostError.invalidStorage }
  }

  private func validateDirectory() throws {
    var held = stat()
    var current = stat()
    guard fstat(directoryDescriptor, &held) == 0, lstat(directory.path, &current) == 0,
      current.st_mode & S_IFMT == S_IFDIR, held.st_dev == current.st_dev,
      held.st_ino == current.st_ino, current.st_uid == geteuid(), current.st_mode & 0o777 == 0o700
    else { throw ProductHostError.invalidStorage }
    if ownerDescriptor >= 0 {
      var ownerHeld = stat()
      var ownerNamed = stat()
      guard fstat(ownerDescriptor, &ownerHeld) == 0,
        fstatat(directoryDescriptor, ".product-owner", &ownerNamed, AT_SYMLINK_NOFOLLOW) == 0,
        ownerNamed.st_mode & S_IFMT == S_IFREG, ownerHeld.st_dev == ownerNamed.st_dev,
        ownerHeld.st_ino == ownerNamed.st_ino, ownerNamed.st_nlink == 1,
        ownerNamed.st_uid == geteuid(), ownerNamed.st_mode & 0o777 == 0o600
      else { throw ProductHostError.invalidStorage }
    }
  }

  private func release() {
    if ownerDescriptor >= 0 {
      Darwin.close(ownerDescriptor)
      ownerDescriptor = -1
    }
    if directoryDescriptor >= 0 {
      Darwin.close(directoryDescriptor)
      directoryDescriptor = -1
    }
  }

  private static func canonicalPath(_ path: String) -> String? {
    guard let pointer = realpath(path, nil) else { return nil }
    defer { free(pointer) }
    return String(cString: pointer)
  }
}
