# Local-only macOS fork

## Scope

Use current Omi's Swift app, capture services, Always/Only Meetings controls, microphone recovery and Parakeet pipeline. Retain SQLite/GRDB. Borrow selected local speaker and API concepts from Infinite Recall after reviewing compatibility; do not replace current Omi with the older fork.

The user's fork requirements supersede upstream assumptions that Firebase, server-owned conversations, telemetry and paid entitlements must exist. Upstream rules protecting data, code signing and existing production apps still apply.

## First implementation: device-owned conversation completion

- Persist a distinct `device_only` strategy using the existing finalization column, with a stable client conversation ID.
- Complete the recording transactionally in the existing database, retaining transcript rows and captured timestamps. Never manufacture a server ID or set `backendSynced`.
- Route this strategy before cloud uploads, meeting-context sync, screenshot processing and completion notifications that rely on backend data.
- Include completed device-only rows in local conversation list/count/detail projections.
- Add an experimental compile-time `OMI_LOCAL_ONLY` recording policy that selects this strategy, bypasses the capture paywall/subscription fetch, requires Apple Silicon and stops when Parakeet cannot load instead of falling back to cloud STT.
- Keep the flag off for now. It does not isolate app startup, login, WAL/audio uploads, other sync tasks or UI mutations. The normal app still behaves like upstream.

`LocalCore` is a small GRDB leaf package used by the app. It neither opens another database nor starts another process. Its executable check harness permits database verification on Macs that have Command Line Tools but no XCTest framework.

## Remaining milestones

1. **Local identity and startup:** replace account gating with a local workspace; remove Firebase/OAuth and account recovery; create a separate bundle, storage root and Keychain namespace. Do not seed credentials, preferences or recordings from installed Omi. Ensure first launch never starts recording before an explicit user action and permissions.
2. **Service removal:** remove PostHog/Sentry and reporting, subscription/billing/entitlement services, Sparkle/updater/forced-update policies, remote flags and related UI. Remove dependencies and bundled service configuration, not only buttons. Keep local diagnostic logs. Inherited GitHub Actions are disabled on this fork.
3. **Offline recording flow:** audit every microphone/system/WAL path, rotations, sleep/wake and retry for uploads. Make detail, rename, delete and speaker edits use local storage. Add durable local search and optional local summary generation. Establish explicit audio-file retention separately from transcript retention.
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

No production Omi app or user recording has been modified by this work.
