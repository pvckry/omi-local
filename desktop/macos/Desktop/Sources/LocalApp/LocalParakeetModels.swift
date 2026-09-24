@preconcurrency import CoreML
import FluidAudio
import Foundation
import OmiLocalCore

/// Downloads are an explicit setup operation. Recording uses direct CoreML file
/// loading, because FluidAudio's convenience loaders can repair/download models.
actor LocalParakeetModels {
  static let shared = LocalParakeetModels()
  nonisolated static let directory = LocalRecordingStore.defaultRoot
    .appendingPathComponent("Models", isDirectory: true)
    .appendingPathComponent(Repo.parakeetV2.folderName, isDirectory: true)

  nonisolated static var isInstalled: Bool {
    AsrModels.modelsExist(at: directory, version: .v2)
  }

  func download() async throws {
    _ = try await AsrModels.download(to: Self.directory, version: .v2)
  }

  func loadOffline(from directory: URL = LocalParakeetModels.directory) throws -> AsrModels {
    guard AsrModels.modelsExist(at: directory, version: .v2) else { throw Failure.notInstalled }
    let config = AsrModels.defaultConfiguration()
    func model(_ name: String, cpuOnly: Bool = false) throws -> MLModel {
      let settings = MLModelConfiguration()
      settings.computeUnits = cpuOnly ? .cpuOnly : config.computeUnits
      return try MLModel(contentsOf: directory.appendingPathComponent(name), configuration: settings)
    }
    let raw = try JSONDecoder().decode(
      [String: String].self,
      from: Data(contentsOf: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)))
    var vocabulary: [Int: String] = [:]
    for (key, text) in raw {
      guard let id = Int(key), vocabulary[id] == nil else { throw Failure.invalidVocabulary }
      vocabulary[id] = text
    }
    guard !vocabulary.isEmpty else { throw Failure.invalidVocabulary }
    return AsrModels(
      encoder: try model(ModelNames.ASR.encoderFile),
      preprocessor: try model(ModelNames.ASR.preprocessorFile, cpuOnly: true),
      decoder: try model(ModelNames.ASR.decoderFile),
      joint: try model(ModelNames.ASR.jointFile),
      configuration: config, vocabulary: vocabulary, version: .v2)
  }

  enum Failure: LocalizedError {
    case notInstalled, invalidVocabulary
    var errorDescription: String? {
      switch self {
      case .notInstalled: "Download the English Parakeet model before starting transcription."
      case .invalidVocabulary: "The Parakeet vocabulary is invalid. Reinstall the model before recording."
      }
    }
  }
}
