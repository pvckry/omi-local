import GRDB
import OmiSupport
import XCTest

@testable import Omi_Computer

/// Exercises the real app schema and cache projection, beyond LocalCore's isolated transaction tests.
final class DeviceOnlyTranscriptionTests: XCTestCase {
  private var testUserID = ""
  private var previousUserID: String?

  override func setUp() async throws {
    try await super.setUp()
    previousUserID = RewindDatabase.currentUserId
    testUserID = "device-only-test-\(UUID().uuidString)"
    await RewindDatabase.shared.close()
    await TranscriptionStorage.shared.invalidateCache()
    RewindDatabase.currentUserId = testUserID
    await RewindDatabase.shared.configure(userId: testUserID)
    try await RewindDatabase.shared.initialize()
  }

  override func tearDown() async throws {
    await RewindDatabase.shared.close()
    await TranscriptionStorage.shared.invalidateCache()
    RewindDatabase.currentUserId = previousUserID
    let directory = DesktopLocalProfile.applicationSupportURL()
      .appendingPathComponent("users").appendingPathComponent(testUserID)
    try FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  func testFinalizeAndReopenDeviceOnlyConversationWithoutServerIdentity() async throws {
    let storage = TranscriptionStorage.shared
    let id = try await storage.startSession(source: "desktop", finalizationStrategy: .deviceOnly)
    try await storage.appendSegment(
      sessionId: id, speaker: 0, text: "Kept on this Mac", startTime: 0, endTime: 1
    )
    // Persist an elapsed capture interval without sleeping in a unit test.
    let pool = await RewindDatabase.shared.getDatabaseQueue()
    let db = try XCTUnwrap(pool)
    try await db.write { database in
      try database.execute(
        sql: "UPDATE transcription_sessions SET startedAt = ? WHERE id = ?",
        arguments: [Date().addingTimeInterval(-60), id]
      )
    }
    try await storage.finishSession(id: id)
    await ConversationFinalizationService.shared.finalizeSession(id: id, reason: .userStop)
    let saved = try await storage.getSession(id: id)
    let session = try XCTUnwrap(saved)
    XCTAssertEqual(session.status, .completed)
    XCTAssertFalse(session.backendSynced)
    XCTAssertNil(session.backendId)
    let identity = try XCTUnwrap(session.clientConversationId)
    XCTAssertTrue(identity.hasPrefix("local-"))

    await RewindDatabase.shared.close()
    await storage.invalidateCache()
    await ConversationFinalizationService.shared.recoverPendingFinalizations()
    let listed = try await storage.getLocalConversations()
    XCTAssertEqual(listed.map(\.id), [identity])
    let count = try await storage.getLocalConversationsCount()
    XCTAssertEqual(count, 1)
    let reopened = try await storage.getCachedConversation(id: identity)
    XCTAssertEqual(reopened?.transcriptSegments.map(\.text), ["Kept on this Mac"])
    let pending = try await storage.getSessionsNeedingFinalization()
    XCTAssertTrue(pending.isEmpty)
    let repeated = try await storage.markSessionCompletedOnDevice(id: id)
    XCTAssertFalse(repeated)
  }

  func testImmediateStopDoesNotInventFutureCaptureTime() async throws {
    let storage = TranscriptionStorage.shared
    let id = try await storage.startSession(source: "desktop", finalizationStrategy: .deviceOnly)
    try await storage.finishSession(id: id)
    let stoppedAt = Date()
    let completed = try await storage.markSessionCompletedOnDevice(id: id)
    XCTAssertTrue(completed)
    let session = try await storage.getSession(id: id)
    let end = try XCTUnwrap(session?.finishedAt)
    XCTAssertLessThanOrEqual(end, stoppedAt)
  }

}
