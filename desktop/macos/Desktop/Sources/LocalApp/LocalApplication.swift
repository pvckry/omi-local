@preconcurrency import AVFoundation
import AppKit
import FluidAudio
import Foundation
import OmiLocalCore
import SwiftUI
import os

// Local diagnostics only. No reporting client is linked into this executable.
private let localLogger = Logger(subsystem: "org.omi.local", category: "capture")
func log(_ message: String) { localLogger.debug("\(message, privacy: .private)") }
func logError(_ message: String, error: Error? = nil) {
  localLogger.error("\(message, privacy: .private): \(String(describing: error), privacy: .private)")
}

@MainActor
final class LocalRecordingController: ObservableObject {
  @Published private(set) var recordings: [LocalRecordingStore.Recording] = []
  @Published private(set) var state = "Stopped"
  @Published private(set) var busy = false
  @Published private(set) var recording = false
  @Published var includeSystemAudio = false
  @Published var error: String?
  @Published private(set) var modelInstalled = LocalParakeetModels.isInstalled
  @Published private(set) var modelStatus =
    LocalParakeetModels.isInstalled ? "Parakeet v2 · English · on device" : "English transcription model not installed"
  @Published private(set) var selectedRecording: LocalRecordingStore.Recording?
  @Published private(set) var transcript: [LocalRecordingStore.Transcript] = []
  private var transcribers: [LocalTranscriptionInput] = []
  private var transcriptionFailure: Error?
  private var fixtureStarted = false
  private var store: LocalRecordingStore?
  private var microphone: AudioCaptureService?
  // Type erased only to keep the microphone app available on macOS 14.0–14.3.
  private var stopSystem: (() async -> Void)?
  private var writers: [BufferedPCMRecorder] = []
  private var captureFailure: Error?
  private var current: LocalRecordingStore.Recording?

  init(root: URL = LocalRecordingStore.defaultRoot) {
    do {
      store = try LocalRecordingStore(root: root)
      try refresh()
    } catch { self.error = "Cannot open local recordings: \(error)" }
  }

  var canStart: Bool { store != nil && !busy && !recording && modelInstalled }

  func start() async {
    guard canStart, let store else { return }
    busy = true
    state = "Starting"
    captureFailure = nil
    error = nil
    transcriptionFailure = nil
    defer { busy = false }
    do {
      state = "Loading Parakeet"
      let models = try await LocalParakeetModels.shared.loadOffline()
      guard await AudioCaptureService.requestPermission() else {
        throw CaptureFailure.microphonePermissionDenied
      }
      let session = try store.start(systemAudio: includeSystemAudio)
      current = session
      selectedRecording = session
      transcript = []
      try store.setTranscriptStatus(.transcribing, for: session)
      let micASR = try await makeTranscriber(models: models, session: session, isUser: true)
      let systemASR =
        includeSystemAudio ? try await makeTranscriber(models: models, session: session, isUser: false) : nil
      let micWriter = try PCMRecordingWriter(directory: store.directory(for: session), source: .microphone)
      let micBuffer = BufferedPCMRecorder(writer: micWriter) { [weak self] error in
        Task { @MainActor in await self?.captureFailed(error) }
      }
      writers.append(micBuffer)
      let mic = AudioCaptureService()
      microphone = mic
      try await mic.startCapture { [weak self] data in
        do {
          try micBuffer.append(data)
          micASR.append(data)
        } catch { Task { @MainActor in await self?.captureFailed(error) } }
      }
      if includeSystemAudio {
        if #available(macOS 14.4, *) {
          let systemWriter = try PCMRecordingWriter(directory: store.directory(for: session), source: .system)
          let systemBuffer = BufferedPCMRecorder(writer: systemWriter) { [weak self] error in
            Task { @MainActor in await self?.captureFailed(error) }
          }
          writers.append(systemBuffer)
          let system = SystemAudioCaptureService()
          stopSystem = {
            system.stopCapture()
            await system.waitForPhysicalStop()
          }
          try await system.startCapture { [weak self] data in
            do {
              try systemBuffer.append(data)
              systemASR?.append(data)
            } catch { Task { @MainActor in await self?.captureFailed(error) } }
          }
        } else {
          throw CaptureFailure.systemAudioRequiresMacOS144
        }
      }
      if let captureFailure { throw captureFailure }
      recording = true
      state = "Recording"
      try refresh()
    } catch {
      self.error = "Recording could not start: \(error)"
      await closeRecording(interrupted: true)
    }
  }

  func stop() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    await closeRecording(interrupted: false)
  }

  private func captureFailed(_ failure: Error) async {
    guard current != nil else { return }
    captureFailure = failure
    error =
      transcriptionFailure == nil
      ? "Audio could not be saved: \(failure)"
      : "Transcription failed; audio retained: \(failure.localizedDescription)"
    // A pending start owns cleanup until its async capture calls finish.
    if busy { return }
    busy = true
    await closeRecording(interrupted: true)
    busy = false
  }

  private func closeRecording(interrupted: Bool) async {
    state = "Stopping"
    microphone?.stopCapture()
    await microphone?.waitForPhysicalStop()
    microphone = nil
    await stopSystem?()
    stopSystem = nil
    var saved = true
    for writer in writers {
      do { try await writer.finish() } catch {
        self.error = "Audio finalization failed: \(error)"
        saved = false
      }
    }
    writers.removeAll()
    for input in transcribers {
      do { try await input.service.finishChecked() } catch {
        transcriptionFailure = error
        self.error = "Transcription failed; audio retained: \(error.localizedDescription)"
      }
    }
    transcribers.removeAll()
    if let current {
      do {
        try store?.setTranscriptStatus(transcriptionFailure == nil && !interrupted ? .completed : .failed, for: current)
      } catch { self.error = "Transcript status could not be saved: \(error)" }
    }
    if let current {
      do { try store?.finish(current, interrupted: interrupted, needsRepair: !saved) } catch {
        self.error = "Recording status could not be saved: \(error)"
      }
    }
    current = nil
    recording = false
    state = "Stopped"
    do { try refresh() } catch { self.error = "Cannot read recordings: \(error)" }
  }

  func downloadModel() async {
    guard !busy, !recording else { return }
    busy = true
    error = nil
    modelStatus = "Downloading English Parakeet model…"
    defer { busy = false }
    do {
      try await LocalParakeetModels.shared.download()
      // Validate with the exact network-free loader used when recording.
      _ = try await LocalParakeetModels.shared.loadOffline()
      modelInstalled = true
      modelStatus = "Parakeet v2 · English · on device"
    } catch {
      modelInstalled = false
      modelStatus = "Model setup failed"
      self.error = error.localizedDescription
    }
  }

  private func makeTranscriber(
    models: AsrModels, session: LocalRecordingStore.Recording,
    isUser: Bool
  ) async throws -> LocalTranscriptionInput {
    let manager = AsrManager()
    try await manager.loadModels(models)
    let input = LocalTranscriptionInput(startedAt: session.startedAt, isUser: isUser)
    input.service.startPrepared(
      manager: manager,
      onSegments: { [weak self, weak input] segments in
        guard let self, let input, let store = self.store else { return }
        do {
          for segment in segments {
            try store.appendTranscript(
              .init(
                id: segment.id ?? UUID().uuidString,
                source: isUser ? "microphone" : "system", start: segment.start + input.offset,
                end: segment.end + input.offset, text: segment.text), to: session)
          }
          if self.selectedRecording?.id == session.id { self.transcript = try store.transcript(for: session) }
        } catch {
          self.transcriptionFailure = error
          self.error = "Transcript could not be saved; audio retained: \(error.localizedDescription)"
          Task { await self.captureFailed(error) }
        }
      },
      onFailure: { [weak self] error in
        self?.transcriptionFailure = error
        Task { await self?.captureFailed(error) }
      })
    transcribers.append(input)
    return input
  }

  func select(_ recording: LocalRecordingStore.Recording) {
    selectedRecording = recording
    do { transcript = try store?.transcript(for: recording) ?? [] } catch {
      self.error = "Cannot read transcript: \(error)"
    }
  }

  /// In-process integration check with supplied synthetic audio, never a microphone.
  /// Uses the same model, segmentation, callbacks, store and finalization as capture.
  func runFixtureIfRequested() async {
    guard !fixtureStarted, let root = LocalLaunchOptions.smokeWorkspace,
      let path = LocalLaunchOptions.argument("--transcription-fixture"), let store
    else { return }
    fixtureStarted = true
    do {
      _ = try await LocalParakeetModels.shared.loadOffline(from: root.appendingPathComponent("absent-models"))
      error = "Missing-model check unexpectedly succeeded"
      return
    } catch LocalParakeetModels.Failure.notInstalled {
      // Expected: the offline loader refuses missing assets without downloading.
    } catch {
      self.error = "Missing-model check failed: \(error)"
      return
    }
    if CommandLine.arguments.contains("--download-models") { await downloadModel() }
    busy = true
    state = "Transcribing fixture"
    defer { busy = false }
    do {
      let models = try await LocalParakeetModels.shared.loadOffline()
      let limitManager = AsrManager()
      try await limitManager.loadModels(models)
      let limitCheck = LocalTranscriptionService()
      limitCheck.startPrepared(manager: limitManager, onSegments: { _ in }, onFailure: { _ in })
      limitCheck.appendAudio(Data(repeating: 0, count: 31 * 32_000))
      do {
        try await limitCheck.finishChecked()
        throw CaptureFailure.invalidFixture
      } catch LocalTranscriptionService.Failure.bufferFull {
        // A stalled decoder cannot grow the capture queue indefinitely.
      }

      let session = try store.start(systemAudio: true)
      current = session
      selectedRecording = session
      try store.setTranscriptStatus(.transcribing, for: session)
      let mic = try await makeTranscriber(models: models, session: session, isUser: true)
      let system = try await makeTranscriber(models: models, session: session, isUser: false)
      let pcm = try await Task.detached {
        let audio = try AVAudioFile(
          forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatInt16, interleaved: false)
        guard audio.processingFormat.sampleRate == 16_000, audio.processingFormat.channelCount == 1,
          audio.length > 0, audio.length <= 25 * 16_000,
          let buffer = AVAudioPCMBuffer(
            pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))
        else { throw CaptureFailure.invalidFixture }
        try audio.read(into: buffer)
        guard let channel = buffer.int16ChannelData else { throw CaptureFailure.invalidFixture }
        return Data(bytes: channel[0], count: Int(buffer.frameLength) * 2)
      }.value
      let writer = try PCMRecordingWriter(directory: store.directory(for: session), source: .microphone)
      try writer.append(pcm)
      try writer.finish()
      mic.append(pcm)
      system.append(pcm)
      await closeRecording(interrupted: false)
      if let transcriptionFailure { throw transcriptionFailure }
      let result = try store.transcript(for: session)
      guard result.contains(where: { $0.source == "microphone" }),
        result.contains(where: { $0.source == "system" })
      else { throw CaptureFailure.emptyTranscript }
      try JSONEncoder().encode(result).write(
        to: root.appendingPathComponent("transcription-check.json"), options: .atomic)
    } catch {
      self.error = "Transcription check failed: \(error)"
      await closeRecording(interrupted: true)
      try? Data(String(describing: error).utf8).write(to: root.appendingPathComponent("transcription-check.error"))
    }
  }

  private func refresh() throws {
    recordings = try store?.list() ?? []
    if let selected = selectedRecording,
      let refreshed = recordings.first(where: { $0.id == selected.id })
    {
      selectedRecording = refreshed
    } else if let recent = recordings.first {
      select(recent)
    }
  }
  func reveal(_ recording: LocalRecordingStore.Recording? = nil) {
    guard let store else { return }
    let url = recording.map { store.directory(for: $0) } ?? store.root
    NSWorkspace.shared.open(url)
  }

  func writeSmokeReport() {
    guard LocalLaunchOptions.smokeWorkspace != nil, let store else { return }
    struct Report: Encodable {
      let workspaceID: String
      let state: String
      let recording: Bool
      let busy: Bool
      let count: Int
      let hasCaptureService: Bool
    }
    do {
      let report = Report(
        workspaceID: store.workspaceID, state: state, recording: recording,
        busy: busy, count: recordings.count, hasCaptureService: microphone != nil || stopSystem != nil)
      try JSONEncoder().encode(report).write(
        to: store.root.appendingPathComponent("startup-smoke.json"), options: .atomic)
    } catch { self.error = "Startup check failed: \(error)" }
  }

  enum CaptureFailure: Error {
    case microphonePermissionDenied, systemAudioRequiresMacOS144, invalidFixture, emptyTranscript
  }
}

@MainActor
final class LocalAppDelegate: NSObject, NSApplicationDelegate {
  weak var controller: LocalRecordingController?
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let controller, !controller.busy else { return .terminateCancel }
    Task {
      await controller.stop()
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}

enum LocalLaunchOptions {
  static func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
  }
  static var smokeWorkspace: URL? {
    argument("--smoke-workspace").map { URL(fileURLWithPath: $0, isDirectory: true) }
  }
}

@main
struct LocalApplication: App {
  @NSApplicationDelegateAdaptor(LocalAppDelegate.self) private var delegate
  @StateObject private var controller = LocalRecordingController(
    root: LocalLaunchOptions.smokeWorkspace ?? LocalRecordingStore.defaultRoot)

  var body: some Scene {
    Window("Omi Local", id: "recordings") {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label(controller.state, systemImage: controller.recording ? "record.circle.fill" : "mic")
            .foregroundStyle(controller.recording ? .red : .primary)
          Spacer()
          Button("Open recordings folder") { controller.reveal() }
        }
        Text("Audio stays on this Mac. Recording starts only when you press Start.")
        HStack {
          Text(controller.modelStatus).font(.caption)
          if !controller.modelInstalled {
            Button("Download English model") { Task { await controller.downloadModel() } }
              .disabled(controller.busy)
          }
        }
        Toggle("Include system audio", isOn: $controller.includeSystemAudio)
          .disabled(controller.busy || controller.recording)
        HStack {
          Button("Start recording") { Task { await controller.start() } }.disabled(!controller.canStart)
          Button("Stop and save") { Task { await controller.stop() } }
            .disabled(controller.busy || !controller.recording)
        }
        if let error = controller.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        Text("Recordings").font(.headline)
        List(controller.recordings) { recording in
          HStack {
            VStack(alignment: .leading) {
              Text(recording.startedAt.formatted())
              Text("\(recording.status) · \(recording.systemAudio ? "Microphone + system" : "Microphone")")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Transcript") { controller.select(recording) }
            Button("Show files") { controller.reveal(recording) }
          }
        }
        if let selected = controller.selectedRecording {
          Text("Transcript · \(selected.startedAt.formatted())").font(.headline)
          if ["failed", "interrupted"].contains(selected.transcriptStatus) {
            Text("Transcript incomplete. The saved audio is retained.").foregroundStyle(.orange)
          }
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              if controller.transcript.isEmpty {
                Text(
                  selected.transcriptStatus == "not_requested"
                    ? "This audio-only recording has no transcript." : "No transcribed speech yet."
                ).foregroundStyle(.secondary)
              }
              ForEach(controller.transcript) { segment in
                Text(
                  "[\(Int(segment.start))s · \(segment.source == "microphone" ? "Microphone" : "System audio")] \(segment.text)"
                )
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
              }
            }
          }.frame(minHeight: 100, maxHeight: 200)
        }
        Text(
          "English transcription runs locally with Parakeet v2. Microphone/system labels identify audio sources, not individual speakers. Speaker separation and automatic triggers are still pending. Audio uses about 115 MB/hour per source and is retained until you delete it."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      .padding(24).frame(minWidth: 600, minHeight: 620)
      .onAppear {
        delegate.controller = controller
        controller.writeSmokeReport()
      }
      .task { await controller.runFixtureIfRequested() }
    }
    MenuBarExtra("Omi Local", systemImage: controller.recording ? "record.circle.fill" : "mic") {
      LocalStatusMenu(controller: controller)
    }
  }
}

@MainActor
private struct LocalStatusMenu: View {
  @ObservedObject var controller: LocalRecordingController
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Text(controller.state)
    Button("Show recordings") { openWindow(id: "recordings") }
    Button("Stop and save") { Task { await controller.stop() } }
      .disabled(controller.busy || !controller.recording)
    Divider()
    Button("Quit Omi Local") { NSApplication.shared.terminate(nil) }
  }
}
