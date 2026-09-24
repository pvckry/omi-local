/// Experimental build-time policy. Not a privacy guarantee for the whole app:
/// startup/auth, sync, telemetry and updater removal are still being ported.
/// Never enable this through a remotely managed flag or persisted preference.
enum LocalOnlyConfiguration {
  static var isEnabled: Bool {
    #if OMI_LOCAL_ONLY
      true
    #else
      false
    #endif
  }

  static func finalizationStrategy(usesLocalSTT: Bool) -> TranscriptionFinalizationStrategy {
    if isEnabled { return .deviceOnly }
    return usesLocalSTT ? .localSegments : .cloudReconcile
  }
}
