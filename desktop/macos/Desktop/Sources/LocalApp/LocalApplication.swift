import AppKit
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

  var canStart: Bool { store != nil && !busy && !recording }

  func start() async {
    guard canStart, let store else { return }
    busy = true
    state = "Starting"
    captureFailure = nil
    error = nil
    defer { busy = false }
    do {
      guard await AudioCaptureService.requestPermission() else {
        throw CaptureFailure.microphonePermissionDenied
      }
      let session = try store.start(systemAudio: includeSystemAudio)
      current = session
      let micWriter = try PCMRecordingWriter(directory: store.directory(for: session), source: .microphone)
      let micBuffer = BufferedPCMRecorder(writer: micWriter) { [weak self] error in
        Task { @MainActor in await self?.captureFailed(error) }
      }
      writers.append(micBuffer)
      let mic = AudioCaptureService()
      microphone = mic
      try await mic.startCapture { [weak self] data in
        do { try micBuffer.append(data) } catch { Task { @MainActor in await self?.captureFailed(error) } }
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
            do { try systemBuffer.append(data) } catch { Task { @MainActor in await self?.captureFailed(error) } }
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
    error = "Audio could not be saved: \(failure)"
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

  private func refresh() throws { recordings = try store?.list() ?? [] }
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
    case microphonePermissionDenied, systemAudioRequiresMacOS144
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
  static var smokeWorkspace: URL? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--smoke-workspace"), args.indices.contains(index + 1) else { return nil }
    return URL(fileURLWithPath: args[index + 1], isDirectory: true)
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
            Button("Show files") { controller.reveal(recording) }
          }
        }
        Text(
          "Development build: audio capture only. Transcription, speaker separation and automatic triggers are not connected yet. WAV files use about 115 MB per hour per source; there is no automatic deletion."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      .padding(24).frame(minWidth: 600, minHeight: 440)
      .onAppear {
        delegate.controller = controller
        controller.writeSmokeReport()
      }
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
