import Foundation

/// Shared transcript value; using on-device ASR must not link a network client.
struct SpeechTranscriptTranslation: Decodable, Sendable {
  let lang: String
  let text: String
}

struct SpeechTranscriptSegment: Decodable, Sendable {
  let id: String?
  let text: String
  let speaker: String?
  // Preserve the existing wire field and memberwise initializer used by in-tree callers.
  // swift-format-ignore: AlwaysUseLowerCamelCase
  let speaker_id: Int?
  // Preserve the existing wire field and memberwise initializer used by in-tree callers.
  // swift-format-ignore: AlwaysUseLowerCamelCase
  let is_user: Bool
  // Preserve the existing wire field and memberwise initializer used by in-tree callers.
  // swift-format-ignore: AlwaysUseLowerCamelCase
  let person_id: String?
  let start: Double
  let end: Double
  let translations: [SpeechTranscriptTranslation]?
}
