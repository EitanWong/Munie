import Foundation
import MunieCore

/// Host-side Release benchmark. Fixtures and reports never contain user data.
@main
struct MunieCoreBenchmark {
  private static let warmupCount = 3
  private static let sampleCount = 20
  private static let syntheticText = String(repeating: "Synthetic thought 合成记录.", count: 8)

  static func main() async {
    do {
      let report = try await run()
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(report)
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
      FileHandle.standardError.write(Data("Core benchmark failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func run() async throws -> Report {
    #if DEBUG
      throw Failure.releaseRequired
    #else
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MunieCoreBenchmark-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      var workloads: [Workload] = []
      for count in [100, 1_000] {
        let records = try (0..<count).map { index in
          guard
            let id = UUID(
              uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))
          else { throw Failure.invalidFixture }
          return CaptureRecord(
            id: id,
            text: syntheticText, createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        let file = directory.appendingPathComponent("records-\(count).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fixture = try encoder.encode(Envelope(schemaVersion: 1, records: records))
        try fixture.write(to: file, options: .atomic)
        let store = FileCaptureStore(fileURL: file)
        var listSamples: [Double] = []
        var saveSamples: [Double] = []
        var deleteSamples: [Double] = []
        for iteration in 0..<(warmupCount + sampleCount) {
          let listStart = ContinuousClock.now
          let listed = try await store.list()
          let listTime = milliseconds(since: listStart)
          guard listed == records.reversed() else { throw Failure.invalidRoundTrip }

          let saveStart = ContinuousClock.now
          let saved = try await store.save(text: syntheticText)
          let saveTime = milliseconds(since: saveStart)
          let reopenedAfterSave = try await FileCaptureStore(fileURL: file).list()
          guard reopenedAfterSave.count == count + 1,
            reopenedAfterSave.contains(saved)
          else { throw Failure.invalidRoundTrip }

          let deleteStart = ContinuousClock.now
          try await store.delete(id: saved.id)
          let deleteTime = milliseconds(since: deleteStart)
          let reopenedAfterDelete = try await FileCaptureStore(fileURL: file).list()
          guard reopenedAfterDelete == records.reversed() else { throw Failure.invalidRoundTrip }
          if iteration >= warmupCount {
            listSamples.append(listTime)
            saveSamples.append(saveTime)
            deleteSamples.append(deleteTime)
          }
        }
        workloads.append(
          Workload(
            recordCount: count, fixtureBytes: fixture.count, roundTripVerified: true,
            operations: [
              "list": Measurement(samplesMilliseconds: listSamples),
              "save": Measurement(samplesMilliseconds: saveSamples),
              "delete": Measurement(samplesMilliseconds: deleteSamples),
            ]))
      }
      return Report(
        schemaVersion: 1, configuration: "release", warmupCount: warmupCount,
        sampleCount: sampleCount, textUTF8Bytes: syntheticText.utf8.count,
        environment: Environment(
          operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
          processorCount: ProcessInfo.processInfo.processorCount), workloads: workloads)
    #endif
  }

  private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let components = start.duration(to: .now).components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
  }

  private struct Envelope: Encodable {
    let schemaVersion: Int
    let records: [CaptureRecord]
  }

  private struct Report: Encodable {
    let schemaVersion: Int
    let configuration: String
    let warmupCount: Int
    let sampleCount: Int
    let textUTF8Bytes: Int
    let environment: Environment
    let workloads: [Workload]
  }

  private struct Environment: Encodable {
    let operatingSystem: String
    let processorCount: Int
  }

  private struct Workload: Encodable {
    let recordCount: Int
    let fixtureBytes: Int
    let roundTripVerified: Bool
    let operations: [String: Measurement]
  }

  private struct Measurement: Encodable {
    let samplesMilliseconds: [Double]
    let p50Milliseconds: Double
    let p95Milliseconds: Double

    init(samplesMilliseconds: [Double]) {
      self.samplesMilliseconds = samplesMilliseconds
      let sorted = samplesMilliseconds.sorted()
      p50Milliseconds = sorted[Int(ceil(Double(sorted.count) * 0.50)) - 1]
      p95Milliseconds = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
    }
  }

  private enum Failure: Error {
    case releaseRequired
    case invalidFixture
    case invalidRoundTrip
  }
}
