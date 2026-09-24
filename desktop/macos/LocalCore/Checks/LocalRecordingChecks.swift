import Foundation
import OmiLocalCore

struct LocalRecordingChecks {
  func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var store: LocalRecordingStore? = try LocalRecordingStore(root: root)
    let workspaceID = try require(store).workspaceID
    try expectEqual(try require(store).list().count, 0)
    try expectFailure(try LocalRecordingStore(root: root)) {
      guard case LocalRecordingStore.Failure.workspaceInUse = $0 else { throw $0 }
    }
    let session = try require(store).start(systemAudio: true)
    let directory = try require(store).directory(for: session)
    let mic = try PCMRecordingWriter(directory: directory, source: .microphone, secondsPerChunk: 1)
    let system = try PCMRecordingWriter(directory: directory, source: .system, secondsPerChunk: 1)
    // Distinct synthetic PCM markers prove no channel mixing or dropped bytes at rotation.
    let audio = Data(repeating: 17, count: 80_000)
    try mic.append(audio.prefix(12_800))
    try mic.append(audio.dropFirst(12_800))
    try system.append(Data(repeating: 29, count: 16_000))
    try mic.finish()
    try system.finish()
    try mic.finish()  // A repeated close must be harmless.
    try expectFailure(try mic.append(Data([0, 0])))
    var reconstructed = Data()
    for index in 0..<3 {
      let file = directory.appendingPathComponent(String(format: "microphone-%06d.wav", index))
      let wav = try Data(contentsOf: file)
      try expectEqual(wav.prefix(4), Data("RIFF".utf8))
      let expectedCount = index == 2 ? 16_000 : 32_000
      try expectEqual(wav.count, expectedCount + 44)
      try expectEqual(wav.subdata(in: 40..<44), littleEndian(UInt32(expectedCount)))
      reconstructed.append(wav.dropFirst(44))
      let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
      try expectEqual(permissions, 0o600)
    }
    try expectEqual(reconstructed, audio)
    let systemFile = directory.appendingPathComponent("system-000000.wav")
    try expectEqual(try Data(contentsOf: systemFile).dropFirst(44), Data(repeating: 29, count: 16_000))
    try require(store).finish(session)
    store = nil
    store = try LocalRecordingStore(root: root)
    try expectEqual(try require(store).workspaceID, workspaceID)
    try expectEqual(try require(store).list().first?.status, "saved")
    print("PASS: isolated identity, exclusive workspace, microphone/system separation, WAV rotation and reopen")

    // Simulate termination after PCM was written but before its WAV header and DB were finalized.
    let interrupted = try require(store).start(systemAudio: false)
    let interruptedDirectory = try require(store).directory(for: interrupted)
    let writer = try PCMRecordingWriter(directory: interruptedDirectory, source: .microphone)
    try writer.append(Data(repeating: 7, count: 2_000))
    try writer.finish()
    let damaged = interruptedDirectory.appendingPathComponent("microphone-000000.wav")
    let file = try FileHandle(forUpdating: damaged)
    try file.seek(toOffset: 40)
    try file.write(contentsOf: littleEndian(UInt32(0)))
    try file.close()
    store = nil
    store = try LocalRecordingStore(root: root)
    try expectEqual(try Data(contentsOf: damaged).subdata(in: 40..<44), littleEndian(UInt32(2_000)))
    try expectEqual(try require(store).list().first { $0.id == interrupted.id }?.status, "interrupted")
    try expectFailure(try require(store).finish(interrupted))
    try expectEqual(try require(store).list().count, 2)
    let failed = try require(store).start(systemAudio: false)
    try require(store).finish(failed, needsRepair: true)
    try expectEqual(try require(store).list().first { $0.id == failed.id }?.status, "needs_repair")
    let next = try require(store).start(systemAudio: false)
    try require(store).finish(next)
    store = nil
    print("PASS: interrupted recording repairs WAV length and remains distinguishable from a clean stop")

    let invalid = try PCMRecordingWriter(directory: root.appendingPathComponent("validation"), source: .microphone)
    try expectFailure(try invalid.append(Data([1])))
    try invalid.finish()
    try expectFailure(try PCMRecordingWriter(directory: root, source: .microphone, secondsPerChunk: 0))
    let linkedRoot = root.appendingPathComponent("linked-workspace")
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
    try expectFailure(try LocalRecordingStore(root: linkedRoot))
    print("PASS: malformed PCM, writes after stop, invalid rotation limits and symlink workspaces are rejected")
  }

  func checkBufferedTail() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = try PCMRecordingWriter(directory: root, source: .microphone, secondsPerChunk: 1)
    let buffer = BufferedPCMRecorder(writer: writer, capacity: 64_000, onFailure: { _ in })
    try buffer.append(Data(repeating: 13, count: 40_000))
    try expectFailure(try buffer.append(Data(repeating: 0, count: 64_002)))
    try await buffer.finish()
    try expectFailure(try buffer.append(Data([0, 0])))
    try await buffer.finish()
    let tail = try Data(contentsOf: root.appendingPathComponent("microphone-000001.wav"))
    try expectEqual(tail.dropFirst(44), Data(repeating: 13, count: 8_000))
    print("PASS: bounded callback buffer drains accepted tail before closing and rejects overflow")
  }

  private func littleEndian(_ number: UInt32) -> Data {
    var value = number.littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
  }
}
