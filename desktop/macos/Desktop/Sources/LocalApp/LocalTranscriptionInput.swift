import Foundation

/// Align each stream to its first received buffer, including system-tap startup
/// delay. This is callback-time alignment, not sample-accurate clock correlation.
final class LocalTranscriptionInput: @unchecked Sendable {
  let service: LocalTranscriptionService
  private let lock = NSLock()
  private let startedAt: Date
  private var firstOffset: Double?

  init(startedAt: Date, isUser: Bool) {
    self.startedAt = startedAt
    service = LocalTranscriptionService(language: "en", isUser: isUser)
  }

  var offset: Double { lock.withLock { firstOffset ?? 0 } }

  func append(_ data: Data) {
    lock.withLock {
      if firstOffset == nil {
        firstOffset = max(0, Date().timeIntervalSince(startedAt) - Double(data.count) / 32_000)
      }
    }
    service.appendAudio(data)
  }
}
