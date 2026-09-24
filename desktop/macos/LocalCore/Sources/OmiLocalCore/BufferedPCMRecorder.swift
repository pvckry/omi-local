import Foundation

/// Keeps filesystem I/O off CoreAudio's callback thread, with a hard memory bound.
/// Backpressure stops recording with an error rather than silently dropping audio.
public final class BufferedPCMRecorder: @unchecked Sendable {
  public enum Failure: Error { case bufferFull, closed }
  private let writer: PCMRecordingWriter
  private let queue = DispatchQueue(label: "org.omi.local.audio-writer", qos: .utility)
  private let lock = NSLock()
  private let capacity: Int
  private let onFailure: @Sendable (Error) -> Void
  private var pending = 0
  private var accepting = true
  private var failure: Error?

  public init(
    writer: PCMRecordingWriter, capacity: Int = 256_000,
    onFailure: @escaping @Sendable (Error) -> Void
  ) {
    self.writer = writer
    self.capacity = max(0, capacity)
    self.onFailure = onFailure
  }

  public func append(_ data: Data) throws {
    lock.lock()
    defer { lock.unlock() }
    guard accepting else { throw Failure.closed }
    if let failure { throw failure }
    guard !data.isEmpty else { return }
    guard data.count <= capacity - pending else { throw Failure.bufferFull }
    pending += data.count
    // Enqueue under the same lock as finish's barrier: an accepted tail chunk
    // must never arrive behind the close operation.
    queue.async { [self] in
      do { try writer.append(data) } catch {
        lock.lock()
        let firstFailure = failure == nil
        failure = error
        lock.unlock()
        if firstFailure { onFailure(error) }
      }
      lock.lock()
      pending -= data.count
      lock.unlock()
    }
  }

  public func finish() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      lock.lock()
      accepting = false
      queue.async { [self] in
        do {
          try writer.finish()
          lock.lock()
          let savedFailure = failure
          lock.unlock()
          if let savedFailure { throw savedFailure }
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
      lock.unlock()
    }
  }
}
