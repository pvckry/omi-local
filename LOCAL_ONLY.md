# Local-only macOS fork

## Scope

Use current Omi's Swift app, capture services, Always/Only Meetings controls, microphone recovery and Parakeet pipeline. Retain SQLite/GRDB. Borrow selected local speaker and API concepts from Infinite Recall after reviewing compatibility; do not replace current Omi with the older fork.

The user's fork requirements supersede upstream assumptions that Firebase, server-owned conversations, telemetry and paid entitlements must exist. Upstream rules protecting data, code signing and existing production apps still apply.

## Local executable: startup and persistent audio

The new `OmiLocal` executable is a small native SwiftUI recording shell that compiles the current Omi `AudioCaptureService` and `SystemAudioCaptureService` directly. It does not initialize the upstream `OMIApp`, `AuthState`, or cloud-backed home screen. The local build's dependency graph contains `LocalCore`, GRDB and the same pinned FluidAudio revision used by upstream Omi: Firebase/OAuth, PostHog, Sentry, subscription services, Sparkle, remote flags and service configuration are excluded from this executable.

Implemented:

- An independently signed `com.omi.omi-local` development bundle, without authentication/settings seeding or a backend process.
- A stable local workspace ID and SQLite index under `~/Library/Application Support/Omi Local`, separated from installed Omi. A workspace lock prevents a second process from recovering files while capture is active; symlink workspace roots are refused.
- Explicit Start/Stop, optional system audio (macOS 14.4+), a recording list and a menu-bar status/Stop control. Launch/relaunch starts stopped; no permission request occurs until Start.
- Separate microphone/system mono 16 kHz PCM WAV files, rotated every minute. Capture buffers are limited to 256 KB per source, with disk writes off the audio callback. Write failures/overflow stop capture visibly instead of silently dropping audio. Stop drains accepted data before closing files.
- Interrupted-session recovery repairs WAV lengths from stored bytes and marks the session interrupted. Audio is never uploaded or automatically deleted. Files are owner-readable/writable inside a private workspace. Storage is roughly 115 MB/hour per source.

The local app now transcribes both audio sources using **Omi's existing local Parakeet v2 pipeline (English)**. A setup button explicitly downloads weights from Hugging Face (about 451 MB on disk in this build). Recording loads those files directly through CoreML without a downloader or cloud fallback. Models are prepared before opening the microphone and released when the session's services are retired. Transcript segments, source labels and offsets persist in SQLite and are readable in the app after reopening. Existing audio-only recordings are preserved by migration and are not automatically retranscribed.

Stop waits for in-flight inference and drains every remaining bounded window before marking the transcript complete. The ASR queue has a 30-second cap per source. Inference/persistence errors stop the session visibly; audio and partial transcripts remain local. Restart marks unfinished transcripts interrupted instead of presenting them as complete. Source offsets use the first received audio callback to account approximately for microphone/system startup delays; this is not sample-accurate synchronization.

The app does not yet expose the full Omi interface, model-based speaker separation, search, meeting/Wi-Fi/location triggers, local APIs or MCP. Microphone/system source labels are not diarization. Sleep/wake, unplug/replug, disk-full and long-duration hardware behavior still need qualification. Corrupt audio that cannot be repaired causes an explicit startup error; it is not discarded. There is no encryption at rest implemented by the app itself.

Build the local executable (Command Line Tools are sufficient):

```sh
OMI_LOCAL_BUILD=1 xcrun swift build --package-path desktop/macos/Desktop \
  --scratch-path desktop/macos/Desktop/.build-local --product OmiLocal
```

For a signed development bundle use the dedicated runner, which preserves the upstream dependency lockfile. Supply an installed signing identity; ad-hoc signing is refused. It builds inside the checkout and does not install or replace anything in `/Applications`:

```sh
OMI_LOCAL_SIGN_IDENTITY='Apple Development: YOUR IDENTITY' \
  desktop/macos/run-local.sh --build-only
# Replace --build-only with --launch to open it. Recording still requires Start.
```

Do not use upstream `run.sh` for this build: it seeds account data and starts cloud-connected services. `OMI_LOCAL_BUILD=1` selects the isolated executable; the older `OMI_LOCAL_ONLY` compile-time flag below only changes the upstream recording policy and does not make the upstream executable offline.

Verification performed on the development Mac:

- Native executable compiled and signed with a real Apple Development identity; bundle signature verified.
- Fresh signed-app startup reported zero recordings, stopped state and no capture services; visible UI showed no account gate.
- A microphone + system session was stopped and saved through the UI. Both WAV headers matched their file lengths, with owner-only file permissions. Relaunch retained the same workspace identity and the saved row, with capture stopped and no capture services. Audio contents were not listened to or uploaded.
- Eleven portable behavior groups exercise workspace identity/reopen, exclusive ownership, byte-exact rotation/source separation, interrupted header repair, invalid input, bounded-buffer overflow/tail draining, transcript ordering/reopen/interruption, preservation of the prior audio-only schema, and the earlier device-only finalizer checks.
- Real Parakeet inference passed a synthetic English speech fixture through both source pipelines. A 17-second fixture also passed under `sandbox-exec` with all networking denied, producing multiple windows and retaining the final phrase for both sources. The same in-process check verifies missing-model refusal and ASR buffer overflow. No microphone capture was started for these transcription checks.
- The signed app was reopened on the resulting workspace: all four transcript segments remained visible, identity was unchanged, and startup reported no capture services. Test workspaces/fixtures should be placed outside macOS-protected Documents folders to avoid file-access prompts for the independent app.
- The development runner refuses to replace its bundle while it is running, including direct launches with a relative executable path.

## First implementation: device-owned conversation completion

- Persist a distinct `device_only` strategy using the existing finalization column, with a stable client conversation ID.
- Complete the recording transactionally in the existing database, retaining transcript rows and captured timestamps. Never manufacture a server ID or set `backendSynced`.
- Route this strategy before cloud uploads, meeting-context sync, screenshot processing and completion notifications that rely on backend data.
- Include completed device-only rows in local conversation list/count/detail projections.
- Add an experimental compile-time `OMI_LOCAL_ONLY` recording policy that selects this strategy, bypasses the capture paywall/subscription fetch, requires Apple Silicon and stops when Parakeet cannot load instead of falling back to cloud STT.
- Keep the flag off for now. It does not isolate app startup, login, WAL/audio uploads, other sync tasks or UI mutations. The normal app still behaves like upstream.

`LocalCore` is a small GRDB leaf package. Its original completion function operates on the caller's database; the isolated local executable additionally uses its new workspace/recording store. It starts no daemon. Its executable check harness permits database verification on Macs that have Command Line Tools but no XCTest framework.

## Remaining milestones

1. **Local identity and startup:** implemented in the isolated local executable. Continue porting useful upstream interface components without importing account-backed singletons. The local app does not need a Keychain namespace yet because it stores no credentials.
2. **Service removal:** these services/dependencies are excluded from the local executable; upstream source remains for reference and incremental porting. Verify outbound behavior over a longer run and keep auditing each added component. Inherited GitHub Actions remain disabled on this fork.
3. **Offline recording flow:** microphone/system capture and English Parakeet transcription are connected in the local executable. Qualify long runs, rotations, sleep/wake and device changes. Make detail, rename, delete and speaker edits use local storage. Add durable local search and optional local summary generation. Establish explicit audio-file retention separately from transcript retention.
4. **CLI/API/MCP:** extend Omi's authenticated loopback API and `omi local` with conversation list/detail/search and recording controls. Preserve local token protection without requiring an account. Adapt its MCP server to these endpoints. Audit existing local tool handlers for cloud calls. Avoid a second daemon unless an independent-lifetime requirement justifies it.
5. **Diarization:** evaluate a model-based local SpeakerKit/pyannote or FluidAudio path. Preserve per-source timing, stabilize speaker IDs across chunks, support user corrections and distinguish anonymous speaker separation from named voice identification. Measure M1 Pro CPU, memory, thermal and battery impact; no quality or performance claims yet.
6. **Automation:** support explicit rules for work Wi-Fi and meeting/microphone detection, with visible capture status and pause. Location can follow if useful.

## Verification

Run the portable database checks:

```sh
xcrun swift run --package-path desktop/macos/LocalCore LocalCoreChecks
```

On a Mac with full Xcode selected, also run the real-schema integration test:

```sh
xcrun swift test --package-path desktop/macos/Desktop --filter DeviceOnlyTranscriptionTests
```

Before enabling/distributing the fork: verify a fresh launch without credentials; microphone/system capture; stop, reopen and retrieval through the CLI; crash/rotation/sleep/wake recovery; explicit model-failure handling; local deletion; and outbound connections with remote traffic blocked after model provisioning. Verify no telemetry, billing, OAuth, updater, transcript, screen or audio upload attempts. Keep model downloads explicit and separate from ongoing processing.

No production Omi app, credentials, settings or existing recordings have been modified. The new development session is retained separately in its explicitly selected test workspace.
