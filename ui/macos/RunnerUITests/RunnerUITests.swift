import AppKit
import CryptoKit
import XCTest

/// UI-test boundary shell for the macOS E2E track (P2).
///
/// Drives the built Deploy Dash app from outside the process, which is what
/// retires the in-process WidgetTester limitations one by one:
///
/// - Deterministic foreground: launch/activate/terminate keeps the app
///   frontmost, killing the occlusion and background-throttling stalls the
///   WidgetTester loop hits when the window loses focus.
/// - Per-phase screenshot attachments (lifetime `.keepAlways`) on every test;
///   screen recording is not a macOS XCTest API, so motion evidence comes
///   from the `xcodebuild test -resultBundlePath` result bundle, not from
///   code here.
/// - Safari GitHub OAuth: typing the test credentials from the environment
///   and approving in Safari, then relying on the OS to deliver the
///   `deploydash://callback` redirect through the app's registered protocol
///   handler (`ProtocolRelayCoordinator`). No relay process, no watcher, no
///   token or state-matching sidecar, no manual dialog.
///
/// What this file deliberately does not do (P3): dismiss keychain or
/// file-access prompts. Those live in secure sessions XCUITest cannot click
/// by platform design, so the run preamble pre-approves them with
/// `security set-key-partition-list` and the credential-helper setup. A run
/// on a virgin keychain blocks without that preamble.
///
/// Control lookup uses the native AX tree, armed by real VoiceOver on
/// the Mac (muted is fine) — the app ships no arming hooks since the
/// 142d886 spike was retired for poisoning the bridge the way
/// ensureE2eSemantics did (b9c9127). One engine gap remains: macOS
/// drops our P1 `identifier`s, so queries use the same visible copy
/// the WidgetTester flow asserts on (labels, titles) plus
/// frame-ordered field indexes — never OCR.
///
/// Secrets discipline: credentials arrive only through the scheme/Xcodebuild
/// environment (`E2E_GITHUB_USERNAME`, `E2E_GITHUB_PASSWORD`) and are masked
/// in CI before use. They are never logged, never baked into the bundle,
/// and never written to disk by this target.
final class RunnerUITests: XCTestCase {
  private var app: XCUIApplication!
  private var launchPID: pid_t = -1

  override func setUpWithError() throws {
    continueAfterFailure = false
    // DMG-target mode (TEMPORARY validation track): attach to the running
    // installed app instead of launching the xcodebuild host. The
    // notarized DMG ships no test hooks, so the Mac must have VoiceOver
    // on (muted is fine) — that is what populates Flutter's AX tree.
    // Enabled with DEPLOYDASH_XCUITEST_DMG_TARGET=1; every helper below
    // operates on `app`, so legs run unchanged once attached. Pinned by
    // bundle URL, never by id alone: the DerivedData twin shares this
    // bundle id, and id resolution once launched the adhoc twin
    // side-by-side with the DMG copy (duplicate Dock icons plus a
    // Gatekeeper "differs from previously opened versions" prompt).
    if ProcessInfo.processInfo.environment[
      "DEPLOYDASH_XCUITEST_DMG_TARGET"
    ] == "1" {
      app = XCUIApplication(
        url: URL(fileURLWithPath: "/Applications/Deploy Dash.app")
      )
      return
    }
    app = XCUIApplication()
    // No launch-environment arming markers: the app under test ships no
    // hooks, so nothing here may pretend to arm the bridge — VoiceOver
    // on the Mac is the only arming path (see file header).
    // Fresh-profile discipline (owner decision): the binary carries no
    // profile-reset flag, so determinism comes from the world, not the
    // app — a manually wiped container (Finder delete) on desk, a virgin
    // hosted runner in CI. Every journey below asserts the onboarding
    // intro first (and no passphrase gate), so a stale profile fails
    // loud there instead of onboarding onto dirty state; the passphrase
    // fields appear only on the review screen.
    //
    // Iteration escape hatch (TEMPORARY, delete at stitch time): with
    // DEPLOYDASH_XCUITEST_REUSE_PROFILE=1 the run targets a manually
    // preserved profile instead — same binary, same droplet, no
    // re-onboarding. The first reuse run still onboards from scratch
    // (empty container); later runs land on the unlock gate. Console
    // output of `env` never prints this; TEST_RUNNER_ forwarding
    // carries it like every other E2E variable.
  }

  override func tearDownWithError() throws {
    if let app {
      let screenshot = app.screenshot()
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.lifetime = .keepAlways
      attachment.name = "teardown-\(name)"
      add(attachment)
      app.terminate()
    }
    app = nil
  }

  /// Unlocks a reuse-profile database with the harness passphrase.
  ///
  /// TEMPORARY iteration helper (see setUp): the first reuse run creates
  /// the database with this same constant, so every later reuse run
  /// unlocks with it. One field, autofocused; the submit button reads
  /// 'Unlock app' outside create/restore modes.
  private func unlockDatabase(
    passphrase: String = "eeeeeeeeeeee",
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    _ = axScreen("Unlock", timeout: 120, file: file, line: line)
    _ = waitForExactTextInputs(1, timeout: 60, file: file, line: line)
    fillSecureInput(at: 0, with: passphrase, file: file, line: line)
    axButton("Unlock app", timeout: 30, file: file, line: line).tap()
  }

  /// Opens a project from Home by row name (reuse-profile navigation).
  ///
  /// TEMPORARY iteration helper (see setUp): relaunches land with no
  /// server selected (session state), so select the server row first,
  /// then the project row. Both resolve by visible name; the workspace
  /// nav proves arrival.
  /// First hittable element whose label, title, or value contains
  /// `fragment`, tapped by the caller.
  ///
  /// StaticTexts carry copy as *value*, which label/title predicates
  /// miss (run43: the rail recent exists yet never matched), so match
  /// in Swift over a snapshot instead. Hittable-only: fused card copy
  /// and log lines match by text but swallow taps (run42).
  private func tapFirstContaining(
    _ fragment: String,
    timeout: TimeInterval = 60,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      let hit = app.descendants(matching: .any).allElementsBoundByIndex
        .first(where: { element in
          guard element.isHittable else {
            return false
          }
          let lowered = fragment.lowercased()
          if element.label.lowercased().contains(lowered) {
            return true
          }
          if element.title.lowercased().contains(lowered) {
            return true
          }
          if let value = element.value as? String,
            value.lowercased().contains(lowered)
          {
            return true
          }
          return false
        })
      if let hit {
        hit.tap()
        return
      }
      Thread.sleep(forTimeInterval: 1)
    }
    dumpAxHierarchy()
    XCTFail(
      "Nothing hittable containing '\(fragment)' appeared.",
      file: file, line: line
    )
  }

  private func openProjectFromHome(
    project: String,
    server: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    axButton("Home", timeout: 60, file: file, line: line).tap()
    // Relaunches land unselected (session state), but assert both
    // states like Leg 1 so a behavior change fails loudly here.
    let selectedHome = app.windows["Deploy Dash - Home - Server selected"]
    let bareHome = app.windows["Deploy Dash - Home - No server yet"]
    let homeDeadline = Date(timeIntervalSinceNow: 120)
    while !selectedHome.exists && !bareHome.exists
      && Date() < homeDeadline
    {
      Thread.sleep(forTimeInterval: 1)
    }
    if !selectedHome.exists && !bareHome.exists {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      selectedHome.exists || bareHome.exists,
      "Home never appeared in either selection state.",
      file: file, line: line
    )
    // Server rows fuse into the card node; tapping fused copy hits
    // static text, so select through the row's Manage action instead:
    // it selects as a side effect before opening Server management.
    if !selectedHome.exists {
      axButton("Manage server", timeout: 60, file: file, line: line).tap()
      _ = axScreen(
        "Server management - Overview", timeout: 120, file: file, line: line
      )
      axButton("Home", timeout: 60, file: file, line: line).tap()
      _ = axScreen(
        "Home - Server selected", timeout: 120, file: file, line: line
      )
    }
    tapFirstContaining(project, timeout: 120, file: file, line: line)
    _ = axContaining("Web app", timeout: 120, file: file, line: line)
  }

  /// Launches the app and holds it in the foreground.
  ///
  /// The foreground wait is the whole point of this shell: every later
  /// query assumes AX resolution is unthrottled, which only holds while the
  /// app is frontmost.
  private func launchForeground(
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    // DMG-target mode: the installed app is already running (opened from
    // /Applications); attach by activation, never by launch. A missing
    // first surface here almost always means VoiceOver is off — the
    // stripped DMG has no arming hook, so an unarmed tree is empty.
    if ProcessInfo.processInfo.environment[
      "DEPLOYDASH_XCUITEST_DMG_TARGET"
    ] == "1" {
      app.activate()
      XCTAssertTrue(
        app.wait(for: .runningForeground, timeout: 60),
        "Installed Deploy Dash never reached the foreground. Open "
          + "/Applications/Deploy Dash.app and enable VoiceOver (Cmd+F5), "
          + "then rerun.",
        file: file,
        line: line
      )
      launchPID = appPID()
      return
    }
    app.launch()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 60),
      "Deploy Dash never reached the foreground.",
      file: file,
      line: line
    )
    launchPID = appPID()
    app.activate()
  }

  /// Attaches a keep-alive screenshot under a phase name.
  private func capture(
    phase: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.lifetime = .keepAlways
    attachment.name = phase
    add(attachment)
  }

  /// Runner-visible hierarchy, printed when a lookup fails.
  ///
  /// Names the screen the app is actually on (via the window title) so a
  /// failed wait reads as missed-tap versus wrong-query-string without
  /// another full run to distinguish them.
  private func dumpAxHierarchy() {
    print("AX DUMP BEGIN")
    print(app.debugDescription)
    print("AX DUMP END")
  }

  /// Native AX element by visible copy, waited for.
  ///
  /// VoiceOver arms the bridge (see file header); macOS drops our P1
  /// identifiers, so queries use the same visible copy the WidgetTester
  /// flow asserts on. Fails the test (never throws) naming the guilty
  /// string, so a missing surface reads as its own diagnosis.
  private func ax(
    _ query: String,
    timeout: TimeInterval = 120,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let element = app.descendants(matching: .any)[query]
    if !element.waitForExistence(timeout: timeout) {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      element.exists,
      "AX '\(query)' never appeared.",
      file: file,
      line: line
    )
    return element
  }

  /// Waits for the app window to carry the given screen title.
  ///
  /// Window titles are set exactly by AppWindowTitle per screen, unlike
  /// section titles, which concatenate title and subtitle into one node
  /// (seen live: 'Server details\nEnter the details…'). Screen
  /// transitions assert through this, never through section copy.
  private func axScreen(
    _ title: String,
    timeout: TimeInterval = 120,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let window = app.windows["Deploy Dash - \(title)"]
    if !window.waitForExistence(timeout: timeout) {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      window.exists,
      "AX screen 'Deploy Dash - \(title)' never appeared.",
      file: file,
      line: line
    )
    return window
  }

  /// Native AX element whose label or title contains `fragment`.
  ///
  /// Exact matching fails where Flutter fuses copy into one node:
  /// section titles concatenate subtitle (runs 18/32) and nav buttons
  /// double their label ('Web app\nWeb app', run34 dump). Predicates on
  /// label/title only — value can be numeric, which CONTAINS chokes on.
  private func axContaining(
    _ fragment: String,
    timeout: TimeInterval = 120,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let element = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "label CONTAINS[c] %@ OR title CONTAINS[c] %@",
        fragment,
        fragment
      )
    ).firstMatch
    if !element.waitForExistence(timeout: timeout) {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      element.exists,
      "AX containing '\(fragment)' never appeared.",
      file: file,
      line: line
    )
    return element
  }

  /// Native AX button by visible label, waited for.
  private func axButton(
    _ label: String,
    timeout: TimeInterval = 120,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let element = app.buttons[label]
    if !element.waitForExistence(timeout: timeout) {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      element.exists,
      "AX button '\(label)' never appeared.",
      file: file,
      line: line
    )
    return element
  }

  /// Text inputs in layout order: top to bottom, left to right.
  ///
  /// Roles vary (Flutter exposes obscured fields as plain text fields on
  /// macOS — seen live in the probe dump) and empty fields carry no
  /// label, so collection is by role plus frame sort: no identifiers,
  /// no OCR, no traversal assumptions.
  private func textInputs() -> [XCUIElement] {
    let fields = app.textFields.allElementsBoundByIndex
      + app.secureTextFields.allElementsBoundByIndex
    return fields.sorted {
      ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
    }
  }

  /// Polls until exactly `count` text inputs exist, in layout order.
  ///
  /// Exactness is load-bearing: the Server details screen holds six
  /// inputs (sidebar search plus five form fields — seen live), and an
  /// at-least wait once mapped every fill one field down the form while
  /// the real password field sat untouched (run19 dump). A layout change
  /// fails here loudly instead of mashing values across fields.
  private func waitForExactTextInputs(
    _ count: Int,
    timeout: TimeInterval = 120,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> [XCUIElement] {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var inputs = textInputs()
    while inputs.count != count && Date() < deadline {
      Thread.sleep(forTimeInterval: 1)
      inputs = textInputs()
    }
    if inputs.count != count {
      dumpAxHierarchy()
    }
    XCTAssertEqual(
      inputs.count,
      count,
      "Expected \(count) text inputs.",
      file: file,
      line: line
    )
    return inputs
  }

  /// Fresh text input at `index`, resolved on every call.
  ///
  /// AX element references go stale when Flutter rebuilds the fields
  /// (every keystroke revalidates): a stored reference then reads nil
  /// forever, which once masqueraded as an empty prefilled value
  /// (run25). Index into a fresh frame-ordered snapshot instead; the
  /// layout — and therefore the order — is stable per screen.
  private func input(
    at index: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let inputs = textInputs()
    XCTAssertLessThan(
      index,
      inputs.count,
      "No text input at index \(index).",
      file: file,
      line: line
    )
    return inputs[min(index, inputs.count - 1)]
  }

  /// Polls until the input's AX value equals the typed expectation.
  ///
  /// Resolves fresh every pass (see `input(at:)`): the semantics stream
  /// lags keystrokes and rebuilds stale references, so a single stored
  /// read would flake either way. A miss fails at the guilty field
  /// instead of poisoning Check connection minutes later.
  private func expectInputValue(
    at index: Int,
    equals expected: String,
    timeout: TimeInterval = 15,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var current: String? = nil
    while current != expected && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      current = input(at: index, file: file, line: line).value as? String
    }
    XCTAssertEqual(
      current,
      expected,
      "Field value mismatch.",
      file: file,
      line: line
    )
  }

  /// Polls until a secure input holds any value. Dots prove presence;
  /// correctness surfaces at Check connection, diagnosably. Resolves
  /// fresh every pass (see `input(at:)`).
  private func expectSecureInputValue(
    at index: Int,
    timeout: TimeInterval = 15,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var empty = true
    while empty && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      empty = (input(at: index, file: file, line: line).value as? String)?
        .isEmpty ?? true
    }
    XCTAssertFalse(
      empty,
      "Secure field stayed empty.",
      file: file,
      line: line
    )
  }

  /// Replaces a prefilled default via documented backspace deletes.
  ///
  /// Clearing matrix (run47, all soft-asserted in one run): element
  /// Cmd+A, double-tap, coordinate triple-tap, and menu Select All all
  /// appended; \b and DEL loops both cleared, so the documented
  /// constant (XCUIKeyboardKey.delete) wins. The delete count is
  /// max(read, desired) + 2: a stale-empty AX read still clears via the
  /// desired length, and a longer-than-expected prefill still clears via
  /// the read. The focus gate above covers the live miss (deletes sent
  /// to an unfocused field on a release build); the empty-verify below
  /// stays the real proof.
  private func replaceInput(
    at index: Int,
    with value: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    // Tap-to-type is racy: Flutter rebuilds the field between tap and
    // keystrokes (release reshuffles worse than debug), and deletes sent
    // to an unfocused field vanish while the value poll then convicts
    // the field instead of the missed tap. One bounded re-tap absorbs
    // the transient; a persistent miss still fails loud naming the field.
    // Delete budget covers the prefill even when the AX stream lags it:
    // max(read, desired) + 2 beats both a stale-empty read and a longer
    // prefill.
    var cleared = false
    for _ in 0..<2 where !cleared {
      input(at: index, file: file, line: line).tap()
      let readBack =
        input(at: index, file: file, line: line).value as? String ?? ""
      let deletes = max(readBack.count, value.count) + 2
      app.typeText(String(repeating: "\u{8}", count: deletes))
      let deadline = Date(timeIntervalSinceNow: 10)
      while !cleared && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.5)
        cleared = (input(at: index, file: file, line: line).value as? String ?? "")
          .isEmpty
      }
    }
    if !cleared {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      cleared,
      "Prefilled field would not clear.",
      file: file, line: line
    )
    app.typeText(value)
    expectInputValue(at: index, equals: value, file: file, line: line)
  }

  /// Types into the nth text input, resolving fresh for every touch.
  ///
  /// The native tap focuses exactly, so the OCR era's miss-and-mash
  /// class cannot occur; the value poll is the per-field proof. Every
  /// touch re-resolves (see `input(at:)`) because rebuilds stale
  /// references between keystrokes.
  private func fillInput(
    at index: Int,
    with value: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    input(at: index, file: file, line: line).tap()
    app.typeText(value)
    expectInputValue(at: index, equals: value, file: file, line: line)
  }

  /// Types only when the input reads empty; prefilled defaults stay.
  ///
  /// Same unreadable-prefill rule as the server form: typing into a
  /// non-empty default appends, so a present value is left alone and a
  /// wrong one fails loudly at the caller, never silently.
  private func fillInputIfEmpty(
    at index: Int,
    with value: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let current = input(at: index, file: file, line: line).value as? String
      ?? ""
    if current.isEmpty {
      fillInput(at: index, with: value, file: file, line: line)
    } else {
      print("AX KEEP: '\(current)' already present, not typing '\(value)'")
    }
  }

  /// First https URL shown anywhere in the tree, host part only.
  ///
  /// The URL row shows the live URL after deploy; reading it back keeps
  /// the Caddy proof free of slug-algorithm duplication.
  private func liveUrlHost(
    timeout: TimeInterval = 120,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> String {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      let texts = app.staticTexts.allElementsBoundByIndex
      for text in texts {
        let value = text.value as? String ?? text.label
        if value.hasPrefix("https://"),
          let host = URL(string: value)?.host,
          !host.isEmpty
        {
          return host
        }
      }
      Thread.sleep(forTimeInterval: 2)
    }
    dumpAxHierarchy()
    XCTFail("No live https URL appeared.", file: file, line: line)
    return ""
  }

  /// Types into the nth obscured input, verifying presence only.
  private func fillSecureInput(
    at index: Int,
    with value: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    input(at: index, file: file, line: line).tap()
    app.typeText(value)
    expectSecureInputValue(at: index, file: file, line: line)
  }

  /// Logs the post-fill AX values of the named inputs.
  ///
  /// Values only — indexes would rot beside the call sites. Passwords
  /// never pass through here (secure fields stream dots at best and
  /// plaintext at worst; neither belongs in a log).
  private func logInputValues(at indexes: [Int], tag: String) {
    let inputs = textInputs()
    let values = indexes.map { index -> String in
      guard index < inputs.count else { return "<missing>" }
      return (inputs[index].value as? String) ?? "<nil>"
    }
    print("AX VALUES [\(tag)]: " + values.joined(separator: " | "))
  }

  /// Swipes the workspace tab scroll until visible copy `query` exists.
  ///
  /// Cards below the fold (env editor, settings) never enter the tree
  /// until scrolled to; the swipe budget bounds the hunt, then the miss
  /// fails loud with a dump.
  private func scrollToAx(
    _ query: String,
    timeout: TimeInterval = 60,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let deadline = Date(timeIntervalSinceNow: timeout)
    let scroll = app.scrollViews.firstMatch
    while Date() < deadline {
      let element = app.descendants(matching: .any)[query]
      if element.exists {
        return element
      }
      if scroll.exists {
        scroll.swipeUp()
      } else {
        Thread.sleep(forTimeInterval: 1)
      }
    }
    dumpAxHierarchy()
    XCTFail(
      "AX '\(query)' never appeared, even scrolled to.",
      file: file, line: line
    )
    return app.descendants(matching: .any)[query]
  }

  /// Tallest text input currently in the tree.
  ///
  /// Dialogs overlay without removing the background tree, so frame
  /// indexes cannot address dialog fields; the bulk-import field spans
  /// 10-14 lines against single-line (~46px) fields, making height the
  /// robust selector. Restored for the clearing matrix after premature
  /// deletion; fails loud past the timeout.
  private func tallestTextInput(
    timeout: TimeInterval = 60,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var best: XCUIElement?
    var bestHeight = 100.0
    while Date() < deadline {
      let all = app.textFields.allElementsBoundByIndex
        + app.textViews.allElementsBoundByIndex
        + app.secureTextFields.allElementsBoundByIndex
      for element in all where element.frame.height > bestHeight {
        bestHeight = element.frame.height
        best = element
      }
      if best != nil {
        return best!
      }
      Thread.sleep(forTimeInterval: 1)
    }
    dumpAxHierarchy()
    XCTFail("No tall text input appeared.", file: file, line: line)
    return app.textFields.firstMatch
  }

  /// Taps a dialog-closing button until it leaves the tree (max 3).
  ///
  /// Taps landing mid-transition hit the backdrop (run36: Save raced
  /// the bulk pop; run38: Save raced the same way despite the absent
  /// wait — the button vanishes at animation start, before the layer
  /// accepts taps). Retrying is idempotent-safe here: a closed dialog
  /// leaves no same-labeled button behind in these flows, so a stray
  /// extra tap has nothing to hit.
  private func tapToClose(
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for _ in 0..<3 {
      let button = app.buttons[label]
      if !button.exists {
        return
      }
      button.tap()
      Thread.sleep(forTimeInterval: 2)
    }
    if app.buttons[label].exists {
      dumpAxHierarchy()
    }
    XCTAssertFalse(
      app.buttons[label].exists,
      "'\(label)' never closed its dialog.",
      file: file, line: line
    )
  }

  /// HTTP status through Caddy from the Mac, outside path first.
  ///
  /// Mirrors the CI verify job's external check: loopback-only asserts
  /// can never see firewall or routing regressions. Accepts 2xx/3xx;
  /// anything else (including curl itself failing) fails the assertion
  /// at the call site.
  private func curlHttpStatus(
    host: String,
    ip: String,
    timeoutSeconds: Int = 30
  ) -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
      "-sS", "-o", "/dev/null", "-w", "%{http_code}",
      "--max-time", "\(timeoutSeconds)",
      "--resolve", "\(host):80:\(ip)",
      "http://\(host)/",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else {
      return -1
    }
    process.waitUntilExit()
    let out =
      String(
        data: pipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
      ) ?? ""
    return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
  }

  /// Launches the app and reaches the onboarding intro, by native AX.
  ///
  /// The profile was wiped before the run (manual Finder delete on desk,
  /// virgin hosted runner in CI), so a virgin intro is deterministic: no
  /// Home branch, no unlock branch, and no passphrase gate before the
  /// user has entered a server and passed checks. The intro proves the
  /// AX tree is live; only then are the gate absences evidence.
  func testLaunchReachesFirstSurface() throws {
    try launchForeground()
    _ = ax("Get started", timeout: 120)
    XCTAssertFalse(
      app.descendants(matching: .any)["Protect this app"].exists,
      "Fresh launch showed the passphrase gate before onboarding."
    )
    XCTAssertFalse(
      app.descendants(matching: .any)["Finish setup"].exists,
      "Fresh launch offered Finish setup before any server was entered."
    )
    capture(phase: "launch-first-surface")
  }

  /// Shared enrollment flow, used by the full-flow test.
  ///
  /// Separated so the slim journey is written once: Finish setup only
  /// opens the create-password modal, so tap it first, fill both modal
  /// fields, and the modal's own action enrolls and provisions.
  @discardableResult
  func enrollAtFinish(passphrase: String) -> XCUIElement {
    // No heading wait: static headings don't reliably enter the AX
    // stream (proven live). The two modal fields are the readiness gate.
    axButton("Finish setup", timeout: 30).tap()
    _ = waitForExactTextInputs(2, timeout: 60)
    fillSecureInput(at: 0, with: passphrase)
    fillSecureInput(at: 1, with: passphrase)
    axButton("Create password", timeout: 30).tap()
    return axScreen("Setting up server", timeout: 120)
  }

  /// Leg 1 — project creation: Home, select server if needed, new
  /// project form, PHP runtime, submit, workspace arrival. Called by
  /// the stitched flow and the iteration harness alike.
  private func legProject() {
    // Home first (the journey lands on Server management Overview).
    // Home arrives selected or not — select our server when needed,
    // since New project stays disabled until selectedServer != null. A
    // disabled tap fails loudly, proving the selection model wrong
    // instead of hanging.
    axButton("Home", timeout: 60).tap()
    let selectedHome = app.windows["Deploy Dash - Home - Server selected"]
    let bareHome = app.windows["Deploy Dash - Home - No server yet"]
    let homeDeadline = Date(timeIntervalSinceNow: 120)
    while !selectedHome.exists && !bareHome.exists
      && Date() < homeDeadline
    {
      Thread.sleep(forTimeInterval: 1)
    }
    if !selectedHome.exists && !bareHome.exists {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      selectedHome.exists || bareHome.exists,
      "Home never appeared in either selection state."
    )
    if bareHome.exists && !selectedHome.exists {
      axButton("E2E slim macOS", timeout: 60).tap()
      _ = axScreen("Home - Server selected", timeout: 120)
    }
    axButton("New project", timeout: 60).tap()
    // The focused flow carries no window title and its heading
    // concatenates subtitle (runs 18/32), so arrival is the exact
    // submit-button label; the form holds one text field with the
    // sidebar search at slot 0, as on the credentials form.
    axButton("Create project", timeout: 60)
    _ = waitForExactTextInputs(2, timeout: 60)
    fillInput(at: 1, with: "E2E Slim")
    // Runtime picker exposes as a Button; the menu offers labels.
    axButton("Runtime", timeout: 30).tap()
    // Flutter dropdowns expose options as labeled Buttons inside a
    // 'Popup menu' group (run33 dump), not MenuItems — one pattern for
    // every picker on this journey.
    axButton("PHP", timeout: 30).tap()
    axButton("Create project", timeout: 60).tap()
    // The new project opens on its Web app tab. The nav button fuses
    // its label ('Web app\nWeb app'), so arrival asserts by fragment;
    // the exact-label rule stays for real buttons.
    _ = axContaining("Web app", timeout: 120)
    capture(phase: "fullflow-project-workspace")
  }

  /// Pastes `text` through Edit > Paste (clipboard round-trip).
  ///
  /// Synthetic shifted keystrokes never arrive (run44: ':' typed into
  /// the APP_KEY field vanished while every unshifted char landed), so
  /// values containing ':' go through the clipboard instead of
  /// typeText. The field must already be focused; AppKit menu dispatch
  /// is a different path from synthetic key events.
  /// Add-row fields, re-resolved on every call: the two text inputs
  /// directly below the 'Add a variable' header, key left of value.
  ///
  /// Geometric because the dialog overlays without removing the
  /// background tree (frame indexes are meaningless) and the fields
  /// carry no labels (only placeholders). Fresh snapshot per call:
  /// dialog rebuilds stale references between touches (run45), and a
  /// stale read once convicted an innocent paste.
  private func envRowFields(
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> [XCUIElement] {
    let header = ax(
      "Add a variable", timeout: 60, file: file, line: line
    )
    let rowFields = textInputs().filter {
      $0.frame.minY >= header.frame.maxY
        && $0.frame.minY <= header.frame.maxY + 200
    }.sorted {
      $0.frame.minX < $1.frame.minX
    }
    if rowFields.count < 2 {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      rowFields.count >= 2,
      "Add-row fields missing below the section header.",
      file: file, line: line
    )
    return rowFields
  }

  /// Pastes `text` through Edit > Paste (clipboard round-trip).
  ///
  /// Shifted keystrokes never arrive via typeText (run46: ':' missing
  /// across fresh polls while every unshifted char verified), so
  /// colon-bearing values go through the clipboard. Staging is
  /// read-back asserted; delivery is proven by the value poll in the
  /// caller.
  private func pasteText(
    _ text: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let board = NSPasteboard.general
    board.clearContents()
    XCTAssertTrue(
      board.setString(text, forType: .string),
      "Could not stage clipboard text.",
      file: file, line: line
    )
    let staged = board.string(forType: .string) ?? "<nil>"
    XCTAssertEqual(
      staged, text,
      "Clipboard staged '\(staged.prefix(24))', not the value.",
      file: file, line: line
    )
    app.menuBars.menuBarItems["Edit"].click()
    app.menuItems["Paste"].click()
  }

  /// Types into one add-row field: gate, tap, input, verify.
  ///
  /// Stability-gates first (two consecutive snapshots must agree
  /// frame-for-frame: dialog scroll/rebuilds shift frames under
  /// fingers, and run47 proved snapshot taps/reads hit stale frames
  /// showing fragments like "A"), asserts emptiness before typing
  /// (catches leaked state instantly — controllers clear after each
  /// add, so non-empty is always a bug), then taps and inputs with no
  /// sleep between (every pause is drift window), verifying through
  /// fresh resolves only.
  private func fillEnvField(
    at index: Int,
    with value: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    var stable: [XCUIElement] = []
    let stableDeadline = Date(timeIntervalSinceNow: 15)
    while Date() < stableDeadline {
      let first = envRowFields(file: file, line: line)
      Thread.sleep(forTimeInterval: 0.5)
      let second = envRowFields(file: file, line: line)
      if first.count == second.count && first.count > index
        && zip(first, second).allSatisfy({ $0.frame == $1.frame })
      {
        stable = second
        break
      }
    }
    if stable.count <= index {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      stable.count > index,
      "Add-row fields never stabilized.",
      file: file, line: line
    )
    let preValue = stable[index].value as? String ?? ""
    if !preValue.isEmpty {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      preValue.isEmpty,
      "Add-row field not empty before typing: '\(preValue)'.",
      file: file, line: line
    )
    stable[index].tap()
    if value.contains(":") {
      pasteText(value, file: file, line: line)
    } else {
      app.typeText(value)
    }
    let deadline = Date(timeIntervalSinceNow: 15)
    var current: String? = nil
    while current != value && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.5)
      let fresh = envRowFields(file: file, line: line)
      current = index < fresh.count
        ? fresh[index].value as? String
        : nil
    }
    if current != value {
      dumpAxHierarchy()
    }
    XCTAssertEqual(
      current,
      value,
      "Env field value mismatch.",
      file: file, line: line
    )
  }

  /// Adds one env row: key, value, Add — each touch freshly resolved.
  private func addEnvRow(
    key: String,
    value: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    fillEnvField(at: 0, with: key, file: file, line: line)
    fillEnvField(at: 1, with: value, file: file, line: line)
    axButton("Add variable", timeout: 30, file: file, line: line).tap()
  }

  /// Leg 2 — env editor, per-row like the WidgetTester leg.
  ///
  /// Bulk import died on dialog mechanics (run40: its Save taps never
  /// registered despite verified paste), while the per-row path needs
  /// no nested modal and Save lands on a long-stable dialog. Row
  /// tokens prove persistence.
  private func legEnv() {
    guardAppAlive()
    scrollToAx("Edit environment variables", timeout: 120).tap()
    _ = axButton("Import in bulk", timeout: 60)
    addEnvRow(key: "E2E_FLAG", value: "true")
    addEnvRow(
      key: "APP_KEY",
      value: "base64:ZGVwbG95ZGFzaC1lMmUta2V5LTEyMzQ1Njc4OTAxMjM="
    )
    tapToClose("Save")
    _ = ax("E2E_FLAG", timeout: 60)
    capture(phase: "fullflow-env-saved")
  }

  /// PID of the app under test, resolved outside XCTest.
  ///
  /// XCUIApplication exposes no process identifier, so this goes through
  /// NSRunningApplication pinned to the installed path — never by bundle
  /// id, which the DerivedData twin shares. -1 means "never recorded".
  private func appPID() -> pid_t {
    NSRunningApplication.runningApplications(
      withBundleIdentifier: "com.deploydash.desktop"
    ).first(where: {
      $0.bundleURL?.path == "/Applications/Deploy Dash.app"
    })?.processIdentifier ?? -1
  }

  /// Fails when the app under test restarted mid-flow.
  ///
  /// A relaunch drops in-memory OAuth and repo state while the windows
  /// look identical, which once masqueraded as missed taps for an hour;
  /// a PID change fails loud at the leg boundary instead.
  private func guardAppAlive(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(
      appPID(),
      launchPID,
      "Deploy Dash restarted mid-flow; only persisted state survived. "
        + "Resume from a clean profile.",
      file: file,
      line: line
    )
  }

  /// Quits Safari so the OAuth tab opens alone.
  ///
  /// Stray tabs hijack AX wholesale: a background authorize tab once
  /// swallowed the Authorize tap while every address-bar read returned
  /// a different tab's URL. Cookies persist in the profile; only the
  /// windows die.
  private func closeSafariForOAuth() {
    XCUIApplication(bundleIdentifier: "com.apple.Safari").terminate()
  }

  /// Fails unless Safari handles https links.
  ///
  /// The app opens the authorize URL in the default browser, and a
  /// stray default sends the whole OAuth leg somewhere the harness
  /// never looks (a Chrome detour cost a full run). Read-only: parses
  /// the LaunchServices plist, changes nothing.
  private func assertSafariIsDefaultBrowser(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = [
      "read",
      "com.apple.LaunchServices/com.apple.launchservices.secure",
      "LSHandlers",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    var handler: String? = nil
    if (try? process.run()) != nil {
      process.waitUntilExit()
      if process.terminationStatus == 0 {
        let out = String(
          data: pipe.fileHandleForReading.readDataToEndOfFile(),
          encoding: .utf8
        ) ?? ""
        if let dictRange = out.range(
          of: "\\{[^{}]*LSHandlerURLScheme = https;[^{}]*\\}",
          options: .regularExpression
        ) {
          let dict = String(out[dictRange])
          if let handlerRange = dict.range(
            of: "LSHandlerRoleAll = \"([^\"]+)\"",
            options: .regularExpression
          ) {
            handler = String(dict[handlerRange])
              .replacingOccurrences(of: "LSHandlerRoleAll = \"", with: "")
              .replacingOccurrences(of: "\"", with: "")
          }
        }
      }
    }
    XCTAssertEqual(
      handler,
      "com.apple.safari",
      "Default https handler is '\(handler ?? "<unreadable>")', not "
        + "Safari. Restore it (Safari Settings > General > Set Default) "
        + "and rerun.",
      file: file,
      line: line
    )
  }

  /// Fails when the authorize URL lacks the expected OAuth client_id.
  ///
  /// The URL carries the compiled-in client_id in the clear, so this
  /// convicts a wrong-ID build at the browser, not hours later at code
  /// exchange (a mismatched pair once burned a full OAuth dance). An
  /// unset DEPLOYDASH_GITHUB_CLIENT_ID skips: the exchange outcome
  /// downstream stays the real proof. Only the URL prefix is logged;
  /// the state token never is.
  private func assertAuthorizeUrlClientId(
    safari: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard
      let expected = ProcessInfo.processInfo.environment[
        "DEPLOYDASH_GITHUB_CLIENT_ID"
      ], !expected.isEmpty
    else {
      return
    }
    let bar = safari.windows.firstMatch.toolbars.textFields.firstMatch
    XCTAssertTrue(
      bar.waitForExistence(timeout: 30),
      "Safari address bar never appeared.",
      file: file,
      line: line
    )
    let url = (bar.value as? String) ?? ""
    XCTAssertTrue(
      url.contains("client_id=\(expected)"),
      "Authorize URL lacks expected client_id; prefix "
        + "'\(url.prefix(120))'. Rebuild with the matching OAuth pair.",
      file: file,
      line: line
    )
  }

  /// Base32 decode for TOTP secrets (no stdlib exists on this toolchain).
  ///
  /// Nil on any out-of-alphabet character so a mangled secret fails at
  /// generation, never as a wrong code at GitHub.
  private func base32Decode(_ input: String) -> Data? {
    let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    var bits = 0
    var accumulator = 0
    var output = Data()
    for character in input.uppercased() {
      if character == "=" || character == " " {
        continue
      }
      guard let index = alphabet.firstIndex(of: character) else {
        return nil
      }
      accumulator =
        (accumulator << 5)
        | alphabet.distance(from: alphabet.startIndex, to: index)
      bits += 5
      if bits >= 8 {
        bits -= 8
        output.append(UInt8((accumulator >> bits) & 0xFF))
      }
    }
    return output
  }

  /// RFC 6238 TOTP (SHA-1, 30s step, 6 digits) with window offset.
  ///
  /// Mirrors qa/e2e/lib/totp.py, whose RFC vectors pin the dynamic
  /// truncation: a shortcut truncation here once generated
  /// plausible-but-rejected codes that GitHub reported only as sudo
  /// failure. Nil means the secret itself is malformed.
  private func totpCode(
    secret: String,
    date: Date = Date(),
    windowOffset: Int = 0
  ) -> String? {
    guard let keyData = base32Decode(secret) else {
      return nil
    }
    let step = Int64(date.timeIntervalSince1970) / 30 + Int64(windowOffset)
    guard step >= 0 else {
      return nil
    }
    var bigEndian = UInt64(step).bigEndian
    let counter = withUnsafeBytes(of: &bigEndian) { Data($0) }
    let mac = HMAC<Insecure.SHA1>.authenticationCode(
      for: counter,
      using: SymmetricKey(data: keyData)
    )
    let bytes = Data(mac)
    let offset = Int(bytes[bytes.count - 1] & 0x0F)
    let code =
      (UInt32(bytes[offset] & 0x7F) << 24 | UInt32(bytes[offset + 1]) << 16
      | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
      % 1_000_000
    return String(format: "%06d", code)
  }

  /// Submits the sudo-mode TOTP code when GitHub gates the authorize.
  ///
  /// Fast path first: if the callback already foregrounded the app
  /// there is no gate. Otherwise a verification/sudo marker on the
  /// page selects the TOTP path, and a missing E2E_GITHUB_TOTP_SECRET
  /// fails naming it instead of burning the callback wait. Codes span
  /// three windows so a 30s rollover mid-submit retries.
  private func submitSudoCodeIfNeeded(
    safari: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    if app.wait(for: .runningForeground, timeout: 20) {
      return
    }
    var gated = false
    for marker in ["verification", "sudo", "Confirm access", "two-factor"] {
      let hit = safari.staticTexts.matching(
        NSPredicate(format: "label CONTAINS[c] %@", marker)
      ).firstMatch
      if hit.waitForExistence(timeout: 8) {
        gated = true
        break
      }
    }
    if !gated {
      return
    }
    guard
      let secret = ProcessInfo.processInfo.environment[
        "E2E_GITHUB_TOTP_SECRET"
      ], !secret.isEmpty
    else {
      XCTFail(
        "GitHub sudo gate is up but E2E_GITHUB_TOTP_SECRET is not set.",
        file: file,
        line: line
      )
      return
    }
    for offset in [-1, 0, 1] {
      guard let code = totpCode(secret: secret, windowOffset: offset) else {
        XCTFail(
          "E2E_GITHUB_TOTP_SECRET is not valid base32.",
          file: file,
          line: line
        )
        return
      }
      let field = safari.textFields.firstMatch
      XCTAssertTrue(
        field.waitForExistence(timeout: 30),
        "Sudo verification field never appeared.",
        file: file,
        line: line
      )
      field.click()
      field.typeText(code + "\n")
      if app.wait(for: .runningForeground, timeout: 45) {
        return
      }
    }
    XCTFail(
      "Sudo codes exhausted and the callback never arrived.",
      file: file,
      line: line
    )
  }

  /// Leg 4 — GitHub Safari OAuth plus repository selection. Settings
  /// and deploy both need the repo, so OAuth runs before them.
  private func legOAuth() throws {
    guardAppAlive()
    let env = ProcessInfo.processInfo.environment
    guard let ghUser = env["E2E_GITHUB_USERNAME"], !ghUser.isEmpty,
      let ghPassword = env["E2E_GITHUB_PASSWORD"], !ghPassword.isEmpty
    else {
      throw XCTSkip("OAuth leg needs E2E_GITHUB_USERNAME/PASSWORD.")
    }
    let repository =
      env["E2E_GITHUB_REPOSITORY"] ?? "deploydash-test/laravel-example-app"
    closeSafariForOAuth()
    assertSafariIsDefaultBrowser()
    // Tapping Connect opens the authorize URL in Safari; after approval
    // the OS routes deploydash://callback back into the app, which
    // exchanges the code (client secret rides the build, never the log)
    // and lists repos.
    axButton("Connect GitHub", timeout: 60).tap()
    capture(phase: "fullflow-oauth-browser")
    let safari = XCUIApplication(bundleIdentifier: "com.apple.Safari")
    XCTAssertTrue(
      safari.wait(for: .runningForeground, timeout: 60),
      "Safari never reached the foreground."
    )
    assertAuthorizeUrlClientId(safari: safari)
    // Authenticated sessions skip the login form; pick the account when
    // GitHub asks (select_account), then sign in only when asked.
    let pickAccount = safari.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] 'Continue as'")
    ).firstMatch
    if pickAccount.waitForExistence(timeout: 60) {
      pickAccount.click()
    }
    let safariLogin = safari.textFields.firstMatch
    if safariLogin.waitForExistence(timeout: 30) {
      safariLogin.click()
      safariLogin.typeText(ghUser)
      let safariPassword = safari.secureTextFields.firstMatch
      XCTAssertTrue(
        safariPassword.waitForExistence(timeout: 60),
        "GitHub password field never appeared in Safari."
      )
      safariPassword.click()
      safariPassword.typeText(ghPassword + "\n")
    }
    // Approve when asked; pre-approved accounts skip straight to the
    // callback, so absence is not failure.
    let authorize = safari.buttons.matching(
      NSPredicate(format: "label CONTAINS[c] 'uthorize'")
    ).firstMatch
    if authorize.waitForExistence(timeout: 90) {
      authorize.click()
    }
    // Sudo-mode TOTP may gate the authorize on sessions GitHub
    // distrusts; without it the leg burns the callback wait instead of
    // failing fast.
    submitSudoCodeIfNeeded(safari: safari)
    capture(phase: "fullflow-oauth-approve")
    app.activate()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 60),
      "Deploy Dash never returned to the foreground after Safari."
    )
    // Back in app: the repo dropdown appears once repos load; picking
    // swaps it for the deploy button on the same rebuild.
    ax("Select a repository", timeout: 180).tap()
    axButton(repository, timeout: 60).tap()
    _ = ax(repository, timeout: 120)
    capture(phase: "fullflow-repo-selected")
  }

  /// Leg 3 — deployment settings. Save gates on a selected repo, so
  /// this runs post-OAuth (same order as the WidgetTester legs).
  private func legSettings() {
    guardAppAlive()
    // The test chooses its own domain (no slug algorithm to
    // duplicate); branch fills only when empty, port and runtime ride
    // their creation defaults untouched, routing is idempotent. Save
    // enables only when everything validates, so its enabled state is
    // the mapping oracle: a wrong field index fails here with a dump,
    // not pages later at deploy.
    scrollToAx("Change settings", timeout: 120).tap()
    _ = axButton("Cancel", timeout: 60)
    fillInputIfEmpty(at: 1, with: "e2e-slim.localhost")
    fillInputIfEmpty(at: 2, with: "main")
    ax("One hostname only", timeout: 30).tap()
    ax("Advanced settings", timeout: 30).tap()
    let settingsSave = axButton("Save", timeout: 60)
    let saveDeadline = Date(timeIntervalSinceNow: 60)
    while !settingsSave.isEnabled && Date() < saveDeadline {
      Thread.sleep(forTimeInterval: 1)
    }
    if !settingsSave.isEnabled {
      dumpAxHierarchy()
    }
    XCTAssertTrue(
      settingsSave.isEnabled,
      "Settings Save stayed disabled: validation still blocks."
    )
    settingsSave.tap()
    Thread.sleep(forTimeInterval: 2)
    tapToClose("Save")
    capture(phase: "fullflow-settings-saved")

    // Preflight runs before every deploy in the WidgetTester legs.
    // Its report lines carry timestamps, so no exact query can assert
    // them and fragment matching skips StaticText values by design:
    // tap and move on. A missed tap is harmless (preflight is
    // advisory); the deploy leg's enabled-assert and Ready wait are
    // the real proofs downstream.
    scrollToAx("Check settings", timeout: 120).tap()
    capture(phase: "fullflow-preflight")
  }

  /// Leg 5 — deploy through the Ready status.
  private func legDeploy() {
    guardAppAlive()
    // A disabled button means validation still blocks; fail fast
    // naming it instead of tapping dead air. The status chip leaving
    // 'Not deployed' proves the tap landed before committing to the
    // long Ready wait. Host-key trust appears on first GitHub SSH
    // contact; approve and continue.
    scrollToAx("Deploy", timeout: 120)
    let deploy = axButton("Deploy", timeout: 60)
    XCTAssertTrue(
      deploy.isEnabled,
      "Deploy stayed disabled: validation still blocks."
    )
    deploy.tap()
    // Tap-landed proof: the status chip leaves 'Not deployed'. Without
    // this, a missed tap burns the full 20-minute Ready wait instead of
    // failing fast with a clear diagnosis.
    let landedDeadline = Date(timeIntervalSinceNow: 120)
    var landed = false
    while !landed && Date() < landedDeadline {
      Thread.sleep(forTimeInterval: 2)
      landed = !app.descendants(matching: .any)["Not deployed"].exists
    }
    if !landed {
      dumpAxHierarchy()
    }
    XCTAssertTrue(landed, "Deploy tap never left 'Not deployed'.")
    let trust = app.buttons["Trust and retry"]
    if trust.waitForExistence(timeout: 90) {
      trust.tap()
    }
    _ = ax("Ready", timeout: 1200)
    capture(phase: "fullflow-deploy-ready")
  }

  /// Leg 6 — Caddy proof from the Mac.
  private func legCaddy() {
    guardAppAlive()
    // The URL row shows the live https URL; curl its host over http (no
    // CA issues) with resolving pinned to the droplet, exactly like
    // the CI verify job's external check. 2xx/3xx pass; anything else
    // (including curl itself failing) fails here with the code.
    // vmHost comes from the environment like every other leg input.
    guard let droplet = ProcessInfo.processInfo.environment[
      "DEPLOYDASH_E2E_VM_HOST"
    ], !droplet.isEmpty else {
      XCTFail("Caddy leg needs DEPLOYDASH_E2E_VM_HOST.")
      return
    }
    let caddyHost = liveUrlHost(timeout: 180)
    let httpCode = curlHttpStatus(
      host: caddyHost,
      ip: droplet,
      timeoutSeconds: 30
    )
    XCTAssertTrue(
      (200..<400).contains(httpCode),
      "Caddy proof failed for '\(caddyHost)': HTTP \(httpCode)."
    )
    capture(phase: "fullflow-caddy-verified")
  }

  /// Slim full flow: onboarding, project, env, GitHub, deploy, verify.
  ///
  /// Staged: needs a live Ubuntu target plus GitHub credentials, i.e.
  /// DEPLOYDASH_XCUITEST_FULLFLOW=1 with E2E_VM_HOST (and friends) and
  /// E2E_GITHUB_USERNAME/PASSWORD in the environment — the same contract
  /// the CI provision job supplies. Without them this skips loudly instead
  /// of failing opaquely. Tonight: launch plus database creation run for
  /// real; onboarding onward lands step by step against a live target,
  /// each verified before the next is written. Server-side truth stays
  /// with SSH checks outside XCTest, mirroring the WidgetTester split.
  func testSlimFullFlow() throws {
    let env = ProcessInfo.processInfo.environment
    guard env["DEPLOYDASH_XCUITEST_FULLFLOW"] == "1",
      let host = env["DEPLOYDASH_E2E_VM_HOST"], !host.trimmingCharacters(in: .whitespaces).isEmpty,
      let user = env["E2E_GITHUB_USERNAME"], !user.isEmpty,
      let password = env["E2E_GITHUB_PASSWORD"], !password.isEmpty
    else {
      throw XCTSkip(
        "Requires DEPLOYDASH_XCUITEST_FULLFLOW=1 with DEPLOYDASH_E2E_VM_HOST "
          + "and GitHub credentials. The launch test covers "
          + "the fresh-profile path."
      )
    }
    let vmHost = host.trimmingCharacters(in: .whitespaces)
    let vmPort = env["DEPLOYDASH_E2E_VM_PORT"]?.trimmingCharacters(in: .whitespaces)
      .isEmpty == false ? env["DEPLOYDASH_E2E_VM_PORT"]! : "22"
    let vmUser = env["DEPLOYDASH_E2E_VM_USER"]?.trimmingCharacters(in: .whitespaces)
      .isEmpty == false ? env["DEPLOYDASH_E2E_VM_USER"]! : "ubuntu"
    let vmPassword = env["DEPLOYDASH_E2E_VM_PASSWORD"] ?? "test1234"
    _ = user
    try launchForeground()
    _ = ax("Get started", timeout: 120)
    capture(phase: "fullflow-onboarding-intro")

    // Server details via native AX. Six inputs in frame order: sidebar
    // search plus name, address, port, user, password (port sits left of
    // user on their shared row). The sidebar slot is asserted empty
    // before and after, so a layout change fails here instead of
    // shifting every fill one field down (run19). Prefilled port/user
    // are accepted without touch: their values never stream (run27)
    // and every clearing path appends (runs 20-23); the env guard keeps
    // non-default targets out, and Check connection proves the values.
    // The password is tapped directly (its label is shared with the
    // auth segment, so label lookup cannot address it). Every touch
    // re-resolves by index because stored references stale out across
    // rebuilds (run25), and every typed value is verified through the
    // AX stream right after typing.
    axButton("Get started", timeout: 60).tap()
    _ = axScreen("Server details", timeout: 120)
    _ = waitForExactTextInputs(5, timeout: 60)
    // First-run frame order: the pre-enrollment startup shell carries
    // no sidebar, so name, address, port, user, password sit at 0-4.
    // Every helper below re-resolves by these indexes (stored references
    // stale out across rebuilds — run25).
    fillInput(at: 0, with: "E2E slim macOS")
    fillInput(at: 1, with: vmHost)
    replaceInput(at: 2, with: vmPort)
    replaceInput(at: 3, with: vmUser)
    fillSecureInput(at: 4, with: vmPassword)
    logInputValues(at: [0, 1, 2, 3], tag: "server-details")
    axButton("Check connection", timeout: 60).tap()

    // Compatibility review, then finish setup into the long baseline run.
    // Timeouts mirror the WidgetTester legs (review 4min, setup 45min);
    // the xcodebuild allowance flag covers the test process itself.
    _ = axScreen("Review server", timeout: 240)
    capture(phase: "fullflow-compatibility-review")
    _ = enrollAtFinish(passphrase: "eeeeeeeeeeee")
    capture(phase: "fullflow-setup-progress")
    _ = axScreen("Choose services", timeout: 2700)
    capture(phase: "fullflow-service-selection")
    axButton("Continue", timeout: 120).tap()
    // The journey ends at Server management Overview, not Home: the
    // window title is exact, and our onboarded server name in the
    // sidebar plus live metric values prove the managed connection
    // works end to end (run28 dump).
    _ = axScreen("Server management - Overview", timeout: 300)
    _ = ax("E2E slim macOS", timeout: 120)
    capture(phase: "fullflow-server-overview")

    legProject()
    legEnv()

    try legOAuth()

    legSettings()

    legDeploy()
    legCaddy()
  }

  /// TEMPORARY micro-harness: clearing variants matrix (DELETE AFTER).
  ///
  /// Research (Apple docs + community patterns) surfaced untried
  /// documented paths after four empirical selection mechanisms
  /// appended. One run tries six variants against the bulk field
  /// (tallest-selector proven 3x; Cancel discards everything, so no
  /// state persists): element-level Cmd+A, double-tap, triple-tap,
  /// press-then-context-menu, \b loop, \u{7F} loop (control — suspects
  /// my hardcoded delete char vs XCUIKeyboardKey.delete). Soft asserts
  /// print a PASS/FAIL matrix; the run fails only if all six fail.
  func testClearVariants() throws {
    guard ProcessInfo.processInfo.environment[
      "DEPLOYDASH_XCUITEST_REUSE_PROFILE"
    ] == "1" else {
      throw XCTSkip("Micro-harness needs reuse profile.")
    }
    try launchForeground()
    unlockDatabase()
    openProjectFromHome(project: "E2E Slim", server: "E2E slim macOS")
    scrollToAx("Edit environment variables", timeout: 120).tap()
    axButton("Import in bulk", timeout: 60).tap()
    let bulk = tallestTextInput(timeout: 60)
    bulk.tap()
    var failures: [String] = []
    func check(_ name: String, _ actual: String?, _ want: String) {
      if actual == want {
        print("AX CLEAR-MATRIX \(name): PASS")
      } else {
        print(
          "AX CLEAR-MATRIX \(name): FAIL (got '\(actual ?? "<nil>")')"
        )
        failures.append(name)
      }
    }
    func bulkValue() -> String? {
      tallestTextInput(timeout: 10).value as? String
    }
    func refill() {
      bulk.tap()
      app.typeText("hello")
    }
    // V1: element-level Cmd+A via the fully-qualified flags type.
    // (Bare `.command` does not infer on this toolchain although the
    // ObjC API exists; the apinotes nest the type. Run20's app-level
    // attempt is a separate, already-failed data point.)
    refill()
    bulk.typeKey("a", modifierFlags: XCUIElement.KeyModifierFlags.command)
    app.typeText("V1")
    check("V1-element-cmd-a", bulkValue(), "V1")
    // V2: double-tap selects the word; typing replaces.
    refill()
    bulk.doubleTap()
    app.typeText("V2")
    check("V2-double-tap", bulkValue(), "V2")
    // V3: three rapid coordinate taps — tap(withNumberOfTaps:) is a
    // touch API unavailable on macOS, but AppKit may still coalesce
    // rapid clicks by timing (triple-click selects a single-line
    // field's full contents).
    refill()
    let triple = bulk.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
    )
    triple.tap()
    triple.tap()
    triple.tap()
    app.typeText("V3")
    check("V3-triple-tap", bulkValue(), "V3")
    // V4: long-press context menu Select All; typing replaces.
    refill()
    bulk.press(forDuration: 1.0)
    let selectAll = app.menuItems["Select All"]
    if selectAll.waitForExistence(timeout: 5) {
      selectAll.tap()
    }
    app.typeText("V4")
    check("V4-press-menu", bulkValue(), "V4")
    // V5: documented \b loop, one per current char.
    refill()
    bulk.tap()
    let v5len = (bulkValue() ?? "").count
    app.typeText(String(repeating: "\u{8}", count: v5len))
    app.typeText("V5")
    check("V5-backspace-loop", bulkValue(), "V5")
    // V6 (control): raw DEL loop as previously attempted.
    refill()
    bulk.tap()
    let v6len = (bulkValue() ?? "").count
    app.typeText(String(repeating: "\u{7F}", count: v6len))
    app.typeText("V6")
    check("V6-del-loop", bulkValue(), "V6")
    // V8: the colon question, isolated. Run44 convicted ':' on stale
    // reads; if plain typing verifies here, every colon workaround
    // (including paste) was fixing a measurement artifact.
    bulk.tap()
    let v8len = (bulkValue() ?? "").count
    app.typeText(String(repeating: "\u{8}", count: v8len + 5))
    bulk.tap()
    app.typeText("a:b")
    check("V8-colon-type", bulkValue(), "a:b")
    // V7: the replaceInput pattern end to end (clear-then-type with
    // empty-verify between): the exact sequence the server form now
    // uses for prefilled defaults.
    refill()
    bulk.tap()
    let v7len = (bulkValue() ?? "").count
    app.typeText(String(repeating: "\u{8}", count: v7len))
    bulk.tap()
    app.typeText("V7")
    check("V7-clear-then-type", bulkValue(), "V7")
    axButton("Cancel", timeout: 30).tap()
    XCTAssertTrue(
      failures.isEmpty,
      "Clearing variants failed: \(failures.joined(separator: ", "))."
    )
  }

  /// TEMPORARY iteration harness: post-onboarding legs against a reused
  /// profile (see setUp). DELETE AT STITCH TIME along with the reuse
  /// flag, unlockDatabase, and openProjectFromHome — the stitched
  /// testSlimFullFlow above is the single journey owner; this exists
  /// only to iterate OAuth/deploy without re-onboarding every cycle.
  /// DEPLOYDASH_XCUITEST_ITERATE_LEG selects the last leg to run
  /// (env|oauth|settings|deploy|caddy); earlier post-onboarding legs
  /// always run since each needs the previous one's state.
  func testIteratePostOnboardingLegs() throws {
    guard ProcessInfo.processInfo.environment[
      "DEPLOYDASH_XCUITEST_REUSE_PROFILE"
    ] == "1" else {
      throw XCTSkip("Iteration harness needs reuse profile.")
    }
    let stopAfter =
      ProcessInfo.processInfo.environment["DEPLOYDASH_XCUITEST_ITERATE_LEG"]
      ?? "caddy"
    try launchForeground()
    unlockDatabase()
    openProjectFromHome(project: "E2E Slim", server: "E2E slim macOS")
    legEnv()
    if stopAfter == "env" {
      return
    }
    try legOAuth()
    if stopAfter == "oauth" {
      return
    }
    legSettings()
    if stopAfter == "settings" {
      return
    }
    legDeploy()
    if stopAfter == "deploy" {
      return
    }
    legCaddy()
  }

  /// Completes GitHub OAuth in Safari and deploys, by native AX throughout.
  ///
  /// Staged: runs only with DEPLOYDASH_XCUITEST_FULLFLOW=1, which marks an
  /// onboarded profile with a project waiting at the Web app tab. Fresh
  /// launches have no project, so without the flag this skips loudly
  /// instead of failing opaquely. Safari steps keep native AX queries
  /// (AppKit publishes a real tree); every Deploy Dash surface below is
  /// native AX too, armed through VoiceOver (see file header).
  ///
  /// Flow: open the Web app tab, tap `Connect GitHub` (the app opens the
  /// authorization URL in the default browser itself, exactly as it does
  /// for a human), sign in with the environment credentials in Safari,
  /// approve, wait for the OS to route `deploydash://callback` back into
  /// the app, select the repository, deploy, and assert the ready status —
  /// all against the one build under test, end to end.
  ///
  /// Safari assumptions, stated so a page redesign fails loudly instead of
  /// silently: GitHub's login form exposes its username/password fields and
  /// sign-in button to AX (they do today); the OAuth authorize page exposes
  /// an Authorize control.
  func testGitHubOAuthViaSafari() throws {
    guard ProcessInfo.processInfo.environment["DEPLOYDASH_XCUITEST_FULLFLOW"]
      == "1"
    else {
      throw XCTSkip(
        "Requires an onboarded profile with a project at the Web app tab. "
          + "Launch and database-creation tests cover the fresh-profile path."
      )
    }
    let username =
      ProcessInfo.processInfo.environment["E2E_GITHUB_USERNAME"] ?? ""
    let password =
      ProcessInfo.processInfo.environment["E2E_GITHUB_PASSWORD"] ?? ""
    let repository =
      ProcessInfo.processInfo.environment["E2E_GITHUB_REPOSITORY"]
      ?? "deploydash-test/laravel-example-app"
    XCTAssertFalse(username.isEmpty, "E2E_GITHUB_USERNAME is not set.")
    XCTAssertFalse(password.isEmpty, "E2E_GITHUB_PASSWORD is not set.")

    try launchForeground()

    // Reach the Web app tab (fused nav label — fragment match).
    axContaining("Web app", timeout: 60).tap()
    capture(phase: "oauth-web-app-tab")

    // Connect when needed; an already-connected profile skips Safari.
    if app.descendants(matching: .any)["Connect GitHub"]
      .waitForExistence(timeout: 30)
    {
      // The app opens the authorization URL in the default browser; the
      // test never handles the URL itself, so there is no relay, no
      // watcher, and no clipboard involved.
      axButton("Connect GitHub").tap()
      capture(phase: "oauth-handed-to-browser")

      let safari = XCUIApplication(bundleIdentifier: "com.apple.Safari")
      XCTAssertTrue(
        safari.wait(for: .runningForeground, timeout: 60),
        "Safari never reached the foreground."
      )

      let loginField = safari.textFields.firstMatch
      XCTAssertTrue(
        loginField.waitForExistence(timeout: 30),
        "GitHub login field never appeared in Safari."
      )
      loginField.click()
      loginField.typeText(username)
      let passwordField = safari.secureTextFields.firstMatch
      XCTAssertTrue(
        passwordField.waitForExistence(timeout: 30),
        "GitHub password field never appeared in Safari."
      )
      passwordField.click()
      passwordField.typeText(password + "\n")

      // Approve on the OAuth authorize page when it appears. The exact
      // control name follows GitHub's page; match loosely and fail loudly.
      let authorize = safari.buttons.matching(
        NSPredicate(format: "label CONTAINS[c] 'uthorize'")
      ).firstMatch
      if authorize.waitForExistence(timeout: 60) {
        authorize.click()
      }
      capture(phase: "oauth-safari-approve")

      // Return focus to the app: the OS delivers deploydash://callback
      // through the registered scheme handler once GitHub redirects.
      app.activate()
      XCTAssertTrue(
        app.wait(for: .runningForeground, timeout: 30),
        "Deploy Dash never returned to the foreground after Safari."
      )
    }

    // Select the repository through its visible rows.
    ax("Select a repository", timeout: 120).tap()
    ax(repository, timeout: 60).tap()
    _ = ax(repository, timeout: 120)
    capture(phase: "oauth-repository-selected")

    // Deploy and assert the ready status text. Mirrors the WidgetTester
    // deploy wait; a release build under test behaves the same.
    axButton("Deploy", timeout: 120).tap()
    _ = ax("Ready", timeout: 720)
    capture(phase: "oauth-deploy-ready")
  }
}
