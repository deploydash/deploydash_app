import Cocoa

/// Builds the macOS accessibility tree without requiring VoiceOver.
///
/// The Flutter macOS embedder only enables semantics on VoiceOver's private
/// on/off notification, unlike Windows (arms on first client query) and Linux
/// (always on). Forcing it here makes automation and assistive tools work with
/// VoiceOver off; VoiceOver users are unaffected (they already get the tree).
/// Uses the internal setter until upstream exposes it publicly; see
/// https://github.com/flutter/flutter/issues/191503. Falls back to stock
/// behavior if the setter is ever gone. Call after the engine is running
/// (e.g. applicationDidFinishLaunching); earlier calls lose the update.
func deploydash_enableSemantics(_ engine: NSObject) {
  let selector = Selector("setSemanticsEnabled:")
  guard engine.responds(to: selector) else {
    NSLog("DeployDash: FlutterEngine lost setSemanticsEnabled; accessibility tree stays VoiceOver-gated")
    return
  }
  engine.setValue(true, forKey: "semanticsEnabled")
}
