import Foundation
import GRDB

/// Completes recordings in Omi's existing database, without a server ID, upload,
/// subscription, or network client. The caller owns the database write transaction.
public enum DeviceOnlyCompletion {
  public static let strategy = "device_only"

  public enum Failure: Error, Equatable {
    case sessionNotFound
    case notDeviceOnly
    case hasRemoteBinding
    case recordingNotFinished
    case invalidIdentity
    case deleted
  }

  /// Returns false for an already-completed recording. Never changes transcript
  /// rows, the captured stop time, or the fact that no server has received it.
  @discardableResult
  public static func complete(in db: Database, sessionID: Int64, now: Date) throws -> Bool {
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM transcription_sessions WHERE id = ?", arguments: [sessionID]
      )
    else { throw Failure.sessionNotFound }

    let savedStrategy: String? = row["finalizationStrategy"]
    guard savedStrategy == strategy else { throw Failure.notDeviceOnly }
    let backendID: String? = row["backendId"]
    let synced: Bool = row["backendSynced"]
    guard backendID == nil, !synced else { throw Failure.hasRemoteBinding }
    let deleted: Bool = row["deleted"]
    guard !deleted else { throw Failure.deleted }
    let identity: String? = row["clientConversationId"]
    guard let identity, !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw Failure.invalidIdentity
    }
    let status: String = row["status"]
    if status == "completed" { return false }
    let startedAt: Date = row["startedAt"]
    let finishedAt: Date? = row["finishedAt"]
    guard status != "recording", let finishedAt,
      finishedAt.timeIntervalSince1970.isFinite, startedAt.timeIntervalSince1970.isFinite,
      finishedAt >= startedAt, finishedAt <= now
    else { throw Failure.recordingNotFinished }

    try db.execute(
      sql: """
        UPDATE transcription_sessions
        SET status = 'completed', conversationStatus = 'completed',
            cacheCompleteness = 'detail', retryCount = 0, lastError = NULL,
            finalizationCompletedAt = ?, updatedAt = ?
        WHERE id = ?
        """,
      arguments: [now, now, sessionID]
    )
    return true
  }
}
