import Foundation
import GRDB
import OmiLocalCore

struct LocalTranscriptChecks {
  func run() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var store: LocalRecordingStore? = try LocalRecordingStore(root: root)
    let session = try require(store).start(systemAudio: true)
    try require(store).setTranscriptStatus(.transcribing, for: session)
    let mic = LocalRecordingStore.Transcript(
      id: "mic", source: "microphone", start: 1, end: 3, text: "Keep the final words.")
    let system = LocalRecordingStore.Transcript(
      id: "sys", source: "system", start: 0, end: 2, text: "Other audio source.")
    try require(store).appendTranscript(mic, to: session)
    try require(store).appendTranscript(system, to: session)
    try expectFailure(try require(store).appendTranscript(mic, to: session))
    try expectFailure(
      try require(store).appendTranscript(
        .init(id: "bad", source: "microphone", start: -1, end: 3, text: "invalid"), to: session))
    try expectEqual(try require(store).transcript(for: session), [system, mic])
    try require(store).setTranscriptStatus(.completed, for: session)
    try require(store).finish(session)
    try expectFailure(
      try require(store).appendTranscript(
        .init(id: "late", source: "microphone", start: 4, end: 5, text: "late"), to: session))
    store = nil
    store = try LocalRecordingStore(root: root)
    try expectEqual(try require(store).transcript(for: session), [system, mic])
    try expectEqual(try require(store).list().first?.transcriptStatus, "completed")
    let interrupted = try require(store).start(systemAudio: false)
    try require(store).setTranscriptStatus(.transcribing, for: interrupted)
    try require(store).appendTranscript(
      .init(id: "partial", source: "microphone", start: 0, end: 1, text: "Preserved partial transcript"),
      to: interrupted)
    store = nil
    store = try LocalRecordingStore(root: root)
    try expectEqual(try require(store).list().first { $0.id == interrupted.id }?.transcriptStatus, "interrupted")
    try expectEqual(try require(store).transcript(for: interrupted).first?.text, "Preserved partial transcript")
    store = nil
    print(
      "PASS: ordered source transcripts persist across restart; late/invalid writes are rejected and interrupted text survives"
    )
  }

  func checkMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try DatabaseQueue(path: root.appendingPathComponent("recordings.sqlite").path)
    var migration = DatabaseMigrator()
    migration.registerMigration("local-recordings-v1") { db in
      // Previous released-in-branch schema, with an existing saved audio entry.
      try db.execute(
        sql: """
          CREATE TABLE workspace (id TEXT PRIMARY KEY NOT NULL);
          INSERT INTO workspace VALUES ('existing-workspace');
          CREATE TABLE recordings (id TEXT PRIMARY KEY NOT NULL, startedAt DATETIME NOT NULL,
            status TEXT NOT NULL, systemAudio BOOLEAN NOT NULL);
          INSERT INTO recordings VALUES ('existing-audio', '2026-09-24 07:33:00.000', 'saved', 1);
          """)
    }
    try migration.migrate(db)
    try db.close()
    let store = try LocalRecordingStore(root: root)
    try expectEqual(store.workspaceID, "existing-workspace")
    try expectEqual(try store.list().first?.id, "existing-audio")
    try expectEqual(try store.list().first?.transcriptStatus, "not_requested")
    print("PASS: migration preserves the existing workspace and audio-only recordings")
  }
}
