import Foundation
import GRDB
import OmiLocalCore

struct DeviceOnlyCompletionChecks {
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeDatabase(path: String? = nil) throws -> DatabaseQueue {
    let db = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
    try db.write { database in
      // Minimal projection of Omi's existing schema. App-level tests additionally
      // exercise its real migrations and TranscriptionStorage adapter.
      try database.execute(
        sql: """
          CREATE TABLE transcription_sessions (
            id INTEGER PRIMARY KEY, startedAt DATETIME NOT NULL, finishedAt DATETIME,
            status TEXT NOT NULL DEFAULT 'pending_upload', conversationStatus TEXT DEFAULT 'in_progress',
            finalizationStrategy TEXT DEFAULT 'device_only', backendId TEXT,
            backendSynced BOOLEAN NOT NULL DEFAULT 0, clientConversationId TEXT DEFAULT 'local-test',
            deleted BOOLEAN NOT NULL DEFAULT 0, cacheCompleteness TEXT DEFAULT 'list',
            retryCount INTEGER DEFAULT 2, lastError TEXT DEFAULT 'interrupted',
            finalizationCompletedAt DATETIME, updatedAt DATETIME
          );
          CREATE TABLE transcription_segments (sessionId INTEGER, text TEXT, startTime DOUBLE, endTime DOUBLE);
          """)
      try database.execute(
        sql: "INSERT INTO transcription_sessions (id, startedAt, finishedAt) VALUES (1, ?, ?)",
        arguments: [start, start.addingTimeInterval(60)]
      )
      try database.execute(
        sql: "INSERT INTO transcription_segments VALUES (1, 'Original transcript', 0, 55)"
      )
    }
    return db
  }

  func testCompletionPreservesTranscriptIdentityAndCapturedDurationWithoutClaimingSync() throws {
    let db = try makeDatabase()
    let completedAt = start.addingTimeInterval(600)
    try expectTrue(try db.write { try DeviceOnlyCompletion.complete(in: $0, sessionID: 1, now: completedAt) })
    try db.read { database in
      let row = try require(Row.fetchOne(database, sql: "SELECT * FROM transcription_sessions"))
      try expectEqual(row["status"] as String, "completed")
      try expectEqual(row["conversationStatus"] as String, "completed")
      try expectEqual(row["cacheCompleteness"] as String, "detail")
      try expectEqual(row["clientConversationId"] as String, "local-test")
      try expectEqual(row["finishedAt"] as Date, start.addingTimeInterval(60))
      try expectEqual(row["finalizationCompletedAt"] as Date, completedAt)
      try expectFalse(row["backendSynced"] as Bool)
      try expectNil(row["backendId"] as String?)
      try expectEqual(row["retryCount"] as Int, 0)
      try expectNil(row["lastError"] as String?)
      try expectEqual(
        try String.fetchOne(database, sql: "SELECT text FROM transcription_segments"), "Original transcript")
      try expectEqual(try Double.fetchOne(database, sql: "SELECT endTime FROM transcription_segments"), 55)
    }
  }

  func testReopenAndRepeatedCompletionKeepOriginalTimestamp() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("omi.db").path
    let db = try makeDatabase(path: path)
    let completedAt = start.addingTimeInterval(600)
    try db.write { try DeviceOnlyCompletion.complete(in: $0, sessionID: 1, now: completedAt) }
    try db.close()
    let reopened = try DatabaseQueue(path: path)
    try expectFalse(
      try reopened.write {
        try DeviceOnlyCompletion.complete(in: $0, sessionID: 1, now: completedAt.addingTimeInterval(3600))
      })
    try reopened.read { database in
      try expectEqual(
        try Date.fetchOne(database, sql: "SELECT finalizationCompletedAt FROM transcription_sessions"), completedAt)
      try expectEqual(try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM transcription_segments"), 1)
    }
    try reopened.close()
  }

  func testUnfinishedCorruptAndCloudOwnedSessionsAreRefusedWithoutMutation() throws {
    let cases: [(String, DeviceOnlyCompletion.Failure)] = [
      ("status = 'recording'", .recordingNotFinished),
      ("finishedAt = NULL", .recordingNotFinished),
      ("finishedAt = '2000-01-01 00:00:00.000'", .recordingNotFinished),
      ("finishedAt = '2100-01-01 00:00:00.000'", .recordingNotFinished),
      ("finalizationStrategy = 'local_segments'", .notDeviceOnly),
      ("finalizationStrategy = 'cloud_reconcile'", .notDeviceOnly),
      ("backendId = 'server-conversation'", .hasRemoteBinding),
      ("backendSynced = 1", .hasRemoteBinding),
      ("clientConversationId = NULL", .invalidIdentity),
      ("clientConversationId = '  '", .invalidIdentity),
      ("deleted = 1", .deleted),
    ]
    for (assignment, expected) in cases {
      let db = try makeDatabase()
      try db.write { try $0.execute(sql: "UPDATE transcription_sessions SET \(assignment)") }
      let before = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM transcription_sessions") }
      try expectFailure(
        try db.write {
          try DeviceOnlyCompletion.complete(in: $0, sessionID: 1, now: start.addingTimeInterval(600))
        }
      ) { try expectEqual($0 as? DeviceOnlyCompletion.Failure, expected, assignment) }
      let after = try db.read { try Row.fetchAll($0, sql: "SELECT * FROM transcription_sessions") }
      try expectEqual(before, after, assignment)
    }
  }

  func testMissingSessionIsNotReportedAsCompleted() throws {
    let db = try makeDatabase()
    try expectFailure(
      try db.write {
        try DeviceOnlyCompletion.complete(in: $0, sessionID: 99, now: start.addingTimeInterval(600))
      }
    ) { try expectEqual($0 as? DeviceOnlyCompletion.Failure, .sessionNotFound) }
  }

  func testTransactionRollbackLeavesRecordingRetryable() throws {
    enum SimulatedCrash: Error { case beforeCommit }
    let db = try makeDatabase()
    try expectFailure(
      try db.write { database in
        try DeviceOnlyCompletion.complete(in: database, sessionID: 1, now: start.addingTimeInterval(600))
        throw SimulatedCrash.beforeCommit
      })
    try expectEqual(
      try db.read { try String.fetchOne($0, sql: "SELECT status FROM transcription_sessions") }, "pending_upload")
    try expectTrue(
      try db.write {
        try DeviceOnlyCompletion.complete(in: $0, sessionID: 1, now: start.addingTimeInterval(700))
      })
  }
}

struct CheckFailure: Error, CustomStringConvertible {
  let description: String
}

func require<T>(_ value: T?) throws -> T {
  guard let value else { throw CheckFailure(description: "Expected a value") }
  return value
}
func expectEqual<T: Equatable>(_ value: @autoclosure () throws -> T, _ expected: T, _ context: String = "") throws {
  guard try value() == expected else { throw CheckFailure(description: "Values differ: \(context)") }
}
func expectTrue(_ value: @autoclosure () throws -> Bool) throws {
  try expectEqual(value(), true)
}
func expectFalse(_ value: @autoclosure () throws -> Bool) throws {
  try expectEqual(value(), false)
}
func expectNil<T>(_ value: T?) throws {
  guard value == nil else { throw CheckFailure(description: "Expected nil") }
}
func expectFailure<T>(_ expression: @autoclosure () throws -> T, _ check: (Error) throws -> Void = { _ in }) throws {
  let failure: Error
  do {
    _ = try expression()
  } catch {
    failure = error
    try check(failure)
    return
  }
  throw CheckFailure(description: "Expected operation to fail")
}

@main
struct LocalCoreChecks {
  static func main() throws {
    let checks = DeviceOnlyCompletionChecks()
    try checks.testCompletionPreservesTranscriptIdentityAndCapturedDurationWithoutClaimingSync()
    print("PASS: local completion preserves identity, transcript and capture duration")
    try checks.testReopenAndRepeatedCompletionKeepOriginalTimestamp()
    print("PASS: reopen and repeated completion are idempotent")
    try checks.testUnfinishedCorruptAndCloudOwnedSessionsAreRefusedWithoutMutation()
    print("PASS: 11 invalid, unfinished or cloud-owned states refused without mutation")
    try checks.testMissingSessionIsNotReportedAsCompleted()
    print("PASS: absent recording is not reported as complete")
    try checks.testTransactionRollbackLeavesRecordingRetryable()
    print("PASS: transaction rollback and retry preserve the recording")
  }
}
