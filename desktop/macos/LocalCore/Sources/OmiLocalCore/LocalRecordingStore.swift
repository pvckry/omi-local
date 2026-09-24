import Darwin
import Foundation
import GRDB

/// A device-owned workspace. Never opens upstream Omi's database or credentials.
public final class LocalRecordingStore: @unchecked Sendable {
  public struct Recording: Identifiable, Sendable, Codable {
    public let id: String
    public let startedAt: Date
    public let status: String
    public let systemAudio: Bool
    public let transcriptStatus: String
  }

  public let root: URL
  public let workspaceID: String
  private let database: DatabaseQueue
  private let lockFD: Int32

  public static var defaultRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Omi Local", isDirectory: true)
  }

  public init(root: URL = LocalRecordingStore.defaultRoot) throws {
    self.root = root
    try Self.privateDirectory(root)
    let fd = open(root.appendingPathComponent("workspace.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw Failure.workspaceUnavailable }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw Failure.workspaceInUse
    }
    do {
      database = try DatabaseQueue(path: root.appendingPathComponent("recordings.sqlite").path)
      var migrator = DatabaseMigrator()
      migrator.registerMigration("local-recordings-v1") { db in
        try db.execute(
          sql: """
            CREATE TABLE workspace (id TEXT PRIMARY KEY NOT NULL);
            CREATE TABLE recordings (
              id TEXT PRIMARY KEY NOT NULL, startedAt DATETIME NOT NULL,
              status TEXT NOT NULL, systemAudio BOOLEAN NOT NULL
            );
            """)
        try db.execute(sql: "INSERT INTO workspace VALUES (?)", arguments: [UUID().uuidString])
      }
      migrator.registerMigration("local-transcripts-v1") { db in
        try db.execute(
          sql: """
            ALTER TABLE recordings ADD COLUMN transcriptStatus TEXT NOT NULL DEFAULT 'not_requested';
            CREATE TABLE local_transcripts (
              id TEXT PRIMARY KEY NOT NULL,
              recordingID TEXT NOT NULL REFERENCES recordings(id),
              source TEXT NOT NULL CHECK(source IN ('microphone', 'system')),
              start DOUBLE NOT NULL, end DOUBLE NOT NULL, text TEXT NOT NULL
            );
            CREATE INDEX local_transcripts_recording ON local_transcripts(recordingID, start);
            """)
      }
      try migrator.migrate(database)
      workspaceID = try database.read { db in
        guard let id = try String.fetchOne(db, sql: "SELECT id FROM workspace") else {
          throw Failure.workspaceUnavailable
        }
        return id
      }
      lockFD = fd
    } catch {
      close(fd)
      throw error
    }
    try recoverInterruptedRecordings()
  }

  deinit { close(lockFD) }

  public enum Failure: Error {
    case workspaceUnavailable, workspaceInUse, recordingNotActive, invalidPCM, invalidWaveFile
  }

  static func privateDirectory(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path),
      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    {
      throw Failure.workspaceUnavailable
    }
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  public func list() throws -> [Recording] {
    try database.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM recordings ORDER BY startedAt DESC").map {
        Recording(
          id: $0["id"], startedAt: $0["startedAt"], status: $0["status"], systemAudio: $0["systemAudio"],
          transcriptStatus: $0["transcriptStatus"])
      }
    }
  }

  public func start(systemAudio: Bool, at date: Date = Date()) throws -> Recording {
    let recording = Recording(
      id: UUID().uuidString, startedAt: date, status: "recording", systemAudio: systemAudio,
      transcriptStatus: "not_requested")
    try Self.privateDirectory(directory(for: recording))
    try database.write { db in
      guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM recordings WHERE status = 'recording'") == 0 else {
        throw Failure.workspaceInUse
      }
      try db.execute(
        sql: "INSERT INTO recordings (id, startedAt, status, systemAudio) VALUES (?, ?, ?, ?)",
        arguments: [recording.id, recording.startedAt, recording.status, recording.systemAudio])
    }
    return recording
  }

  public func directory(for recording: Recording) -> URL {
    root.appendingPathComponent(recording.id, isDirectory: true)
  }

  public struct Transcript: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let source: String
    public let start: Double
    public let end: Double
    public let text: String
    public init(id: String, source: String, start: Double, end: Double, text: String) {
      self.id = id
      self.source = source
      self.start = start
      self.end = end
      self.text = text
    }
  }

  public enum TranscriptStatus: String { case transcribing, completed, failed }

  public func setTranscriptStatus(_ status: TranscriptStatus, for recording: Recording) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE recordings SET transcriptStatus = ? WHERE id = ?",
        arguments: [status.rawValue, recording.id])
      guard db.changesCount == 1 else { throw Failure.recordingNotActive }
    }
  }

  public func appendTranscript(_ segment: Transcript, to recording: Recording) throws {
    guard ["microphone", "system"].contains(segment.source),
      segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start,
      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw Failure.invalidPCM }
    try database.write { db in
      guard
        try String.fetchOne(
          db, sql: "SELECT transcriptStatus FROM recordings WHERE id = ?",
          arguments: [recording.id]) == "transcribing"
      else { throw Failure.recordingNotActive }
      try db.execute(
        sql: "INSERT INTO local_transcripts VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [segment.id, recording.id, segment.source, segment.start, segment.end, segment.text])
    }
  }

  public func transcript(for recording: Recording) throws -> [Transcript] {
    try database.read { db in
      try Row.fetchAll(
        db, sql: "SELECT * FROM local_transcripts WHERE recordingID = ? ORDER BY start, source, id",
        arguments: [recording.id]
      ).map {
        Transcript(id: $0["id"], source: $0["source"], start: $0["start"], end: $0["end"], text: $0["text"])
      }
    }
  }

  public func finish(_ recording: Recording, interrupted: Bool = false, needsRepair: Bool = false) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE recordings SET status = ? WHERE id = ? AND status = 'recording'",
        arguments: [needsRepair ? "needs_repair" : (interrupted ? "interrupted" : "saved"), recording.id])
      guard db.changesCount == 1 else { throw Failure.recordingNotActive }
    }
  }

  private func recoverInterruptedRecordings() throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE recordings SET transcriptStatus = 'interrupted' WHERE transcriptStatus = 'transcribing'")
    }
    for recording in try list() where recording.status == "recording" {
      let files = try FileManager.default.contentsOfDirectory(
        at: directory(for: recording), includingPropertiesForKeys: nil)
      for file in files where file.pathExtension == "wav" { try PCMRecordingWriter.repairHeader(at: file) }
      try finish(recording, interrupted: true)
    }
  }
}

/// Bounded, independently playable WAV chunks: 16 kHz, mono, signed 16-bit PCM.
/// Use BufferedPCMRecorder to keep these synchronous writes off capture callbacks.
public final class PCMRecordingWriter: @unchecked Sendable {
  public enum Source: String, Sendable { case microphone, system }
  private let lock = NSLock()
  private let directory: URL
  private let source: Source
  private let chunkBytes: Int
  private var index = 0
  private var handle: FileHandle?
  private var bytes = 0
  private var closed = false

  public init(directory: URL, source: Source, secondsPerChunk: Int = 60) throws {
    guard (1...3600).contains(secondsPerChunk) else { throw LocalRecordingStore.Failure.invalidPCM }
    self.directory = directory
    self.source = source
    chunkBytes = secondsPerChunk * 32_000
    try LocalRecordingStore.privateDirectory(directory)
  }

  public func append(_ data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { throw LocalRecordingStore.Failure.recordingNotActive }
    guard data.count.isMultiple(of: 2) else { throw LocalRecordingStore.Failure.invalidPCM }
    var offset = 0
    while offset < data.count {
      if handle == nil { try openChunk() }
      let count = min(chunkBytes - bytes, data.count - offset)
      try handle?.write(contentsOf: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count)))
      bytes += count
      offset += count
      if bytes == chunkBytes { try closeChunk() }
    }
  }

  public func finish() throws {
    lock.lock()
    defer { lock.unlock() }
    closed = true
    try closeChunk()
  }

  private func openChunk() throws {
    let url = directory.appendingPathComponent(String(format: "%@-%06d.wav", source.rawValue, index))
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw LocalRecordingStore.Failure.workspaceUnavailable }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    handle = file
    try file.write(contentsOf: Self.header(bytes: 0))
    bytes = 0
    index += 1
  }

  private func closeChunk() throws {
    guard let file = handle else { return }
    try file.seek(toOffset: 0)
    try file.write(contentsOf: Self.header(bytes: bytes))
    try file.synchronize()
    try file.close()
    handle = nil
  }

  public static func repairHeader(at url: URL) throws {
    let file = try FileHandle(forUpdating: url)
    defer { try? file.close() }
    let size = try file.seekToEnd()
    guard size >= 44, size <= UInt64(UInt32.max), (size - 44).isMultiple(of: 2) else {
      throw LocalRecordingStore.Failure.invalidWaveFile
    }
    try file.seek(toOffset: 0)
    let existing = try file.read(upToCount: 44) ?? Data()
    guard existing.prefix(4) == Data("RIFF".utf8), existing.dropFirst(8).prefix(4) == Data("WAVE".utf8) else {
      throw LocalRecordingStore.Failure.invalidWaveFile
    }
    try file.seek(toOffset: 0)
    try file.write(contentsOf: header(bytes: Int(size - 44)))
    try file.synchronize()
  }

  private static func header(bytes: Int) -> Data {
    var data = Data()
    func text(_ text: String) { data.append(contentsOf: text.utf8) }
    func word<T: FixedWidthInteger>(_ number: T) {
      var value = number.littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    text("RIFF")
    word(UInt32(bytes + 36))
    text("WAVEfmt ")
    word(UInt32(16))
    word(UInt16(1))
    word(UInt16(1))
    word(UInt32(16_000))
    word(UInt32(32_000))
    word(UInt16(2))
    word(UInt16(16))
    text("data")
    word(UInt32(bytes))
    return data
  }
}
