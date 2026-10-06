#if os(macOS) && canImport(Sparkle)
import Sparkle

// Sparkle's updater already has every member the surfaces need. Pass
// `SPUStandardUpdaterController.updater` to `SurfaceUpdates(driver:)`.
extension SPUUpdater: SurfaceUpdateDriver {}
#endif
