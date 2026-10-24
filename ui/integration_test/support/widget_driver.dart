part of '../e2e_checklist_test.dart';

Future<void> _tap(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  await _tapFinder(tester, finder, description: key.toString());
}

// env-edit-button opens the environment editor dialog via a plain
// showDialog call with no other confirmable state change first -- the same
// unconfirmed-tap shape as scheduler-add-task-button/workers-add-button.
// Confirm the editor actually opened and retry rather than trust one
// dispatched tap.
Future<void> _tapEnvEditAndConfirmOpened(WidgetTester tester) async {
  final editButton = find.byKey(const Key('env-edit-button'));
  final keyField = find.byKey(const Key('env-new-key-field'));
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(
      tester,
      editButton,
      description: 'edit environment variables',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (keyField.evaluate().isNotEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Tapping the environment editor button never opened the editor.');
}

Future<void> _confirmPostgresSqlRestore(
  WidgetTester tester, {
  required String description,
}) async {
  final dialog = find.byType(AppConfirmDialog);
  await _waitFor(
    tester,
    dialog,
    description: '$description restore confirmation',
  );
  await _tapFinder(
    tester,
    find.descendant(
      of: dialog,
      matching: find.widgetWithText(FilledButton, 'Restore'),
    ),
    description: 'confirm $description',
  );
}

Future<void> _confirmAppRollback(WidgetTester tester) async {
  final dialog = find.byType(AppConfirmDialog);
  await _waitFor(
    tester,
    dialog,
    description: 'application rollback confirmation',
  );
  final rollbackButton = find.descendant(
    of: dialog,
    matching: find.widgetWithText(FilledButton, 'Rollback'),
  );
  // Callers wait minutes afterward for github-status-text to become
  // 'Ready'; a missed tap here would leave the dialog open and burn that
  // whole wait for nothing. The dialog closing is a fast, purely
  // client-side signal, so confirm it and retry rather than trust one
  // dispatched tap.
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(
      tester,
      rollbackButton,
      description: 'confirm application rollback',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (dialog.evaluate().isEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail('Confirming the application rollback dialog never closed it.');
}

Future<void> _scrollUntilMounted(
  WidgetTester tester,
  Finder target, {
  required Finder within,
  required String description,
}) async {
  final scrollable = find
      .descendant(of: within, matching: find.byType(Scrollable))
      .first;
  await _waitFor(tester, scrollable, description: '$description scrollable');

  for (var attempt = 0; attempt < 30; attempt += 1) {
    if (target.evaluate().isNotEmpty) {
      return;
    }
    final state = tester.state<ScrollableState>(scrollable);
    final position = state.position;
    final nextOffset = (position.pixels + 320).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (nextOffset == position.pixels) {
      break;
    }
    position.jumpTo(nextOffset);
    await tester.pumpAndSettle();
  }

  fail('Could not reveal $description in its scrollable workspace.');
}

Future<void> _revealDatabaseServiceControl(
  WidgetTester tester, {
  required Finder servicesTab,
  required Finder databaseRow,
  required Finder enableButton,
}) async {
  final scrollable = find
      .descendant(of: servicesTab, matching: find.byType(Scrollable))
      .first;
  await _waitFor(tester, scrollable, description: 'server services scrollable');

  for (var attempt = 0; attempt < 30; attempt += 1) {
    if (databaseRow.evaluate().isNotEmpty ||
        enableButton.evaluate().isNotEmpty) {
      return;
    }
    final position = tester.state<ScrollableState>(scrollable).position;
    final nextOffset = (position.pixels + 320).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (nextOffset == position.pixels) {
      break;
    }
    position.jumpTo(nextOffset);
    await tester.pumpAndSettle();
  }

  fail('Could not reveal the PostgreSQL service controls.');
}

Future<void> _tapFinder(
  WidgetTester tester,
  Finder finder, {
  required String description,
}) async {
  await _waitFor(tester, finder, description: description);
  var hitTestableFinder = finder.hitTestable();
  if (hitTestableFinder.evaluate().isEmpty) {
    await tester.ensureVisible(finder);
    await tester.pump();
    hitTestableFinder = finder.hitTestable();
  }
  await _waitFor(
    tester,
    hitTestableFinder,
    description: '$description to become actionable',
  );
  await tester.tap(hitTestableFinder);
  await tester.pump();
}

Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  final visibleText = find
      .byType(Text)
      .evaluate()
      .map((element) {
        final widget = element.widget as Text;
        return widget.data ?? widget.textSpan?.toPlainText() ?? '';
      })
      .where((value) => value.trim().isNotEmpty)
      .take(80)
      .join(' | ');
  final mountedKeys = find
      .byWidgetPredicate((widget) => widget.key != null)
      .evaluate()
      .map((element) => element.widget.key.toString())
      .take(80)
      .join(' | ');
  fail(
    'Timed out waiting for $description.\n'
    'Visible text: ${redactE2eDiagnosticText(visibleText)}\n'
    'Mounted keys: $mountedKeys',
  );
}

Future<void> _waitForAbsent(
  WidgetTester tester,
  Finder finder, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('Timed out waiting for $description to finish.');
}

Future<void> _waitForEnabledFilledButton(
  WidgetTester tester,
  Key key, {
  required String blockingReasonKeyName,
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final finder = find.byKey(key);
  final blockingFinder = find.byKey(Key(blockingReasonKeyName));
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (blockingFinder.evaluate().isNotEmpty) {
      fail(_readWidgetText(tester, blockingReasonKeyName));
    }
    if (finder.evaluate().isNotEmpty) {
      final button = tester.widget<FilledButton>(finder);
      if (button.onPressed != null) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  if (blockingFinder.evaluate().isNotEmpty) {
    fail(_readWidgetText(tester, blockingReasonKeyName));
  }
  fail('Timed out waiting for $description.');
}

Future<void> _waitForEnabledButton(
  WidgetTester tester,
  Key key, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final finder = find.byKey(key);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty && _buttonIsEnabled(tester, finder)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('Timed out waiting for $description.');
}

Future<void> _waitForEnabledButtonByFinder(
  WidgetTester tester,
  Finder finder, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty && _buttonIsEnabled(tester, finder)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('Timed out waiting for $description.');
}

bool _buttonIsEnabled(WidgetTester tester, Finder finder) {
  final widget = tester.widget(finder);
  return switch (widget) {
    FilledButton(:final onPressed) => onPressed != null,
    OutlinedButton(:final onPressed) => onPressed != null,
    TextButton(:final onPressed) => onPressed != null,
    ElevatedButton(:final onPressed) => onPressed != null,
    IconButton(:final onPressed) => onPressed != null,
    _ => false,
  };
}

Future<void> _scrollProjectTabTo(WidgetTester tester, Key key) async {
  final target = find.byKey(key);
  final appScrollView = find.byKey(const Key('app-tab-scroll'));
  await _waitFor(tester, appScrollView, description: 'Web app scroll view');
  final scrollable = find
      .descendant(of: appScrollView, matching: find.byType(Scrollable))
      .first;
  await _scrollUntilMounted(
    tester,
    target,
    within: appScrollView,
    description: key.toString(),
  );

  // A lazy ListView can mount a target just inside its lower edge. Move it
  // close to the top of the visible workspace so an anchored terminal cannot
  // make the ExpansionTile header non-hit-testable.
  final scrollableTop = tester.getTopLeft(scrollable).dy;
  final targetTop = tester.getTopLeft(target).dy;
  final scrollState = tester.state<ScrollableState>(scrollable);
  final targetOffset =
      (scrollState.position.pixels + targetTop - scrollableTop - 24).clamp(
        scrollState.position.minScrollExtent,
        scrollState.position.maxScrollExtent,
      );
  scrollState.position.jumpTo(targetOffset);
  await tester.pumpAndSettle();
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 250));
}

// _scrollProjectTabTo (above) only scrolls forward via _scrollUntilMounted,
// so it cannot reveal a target above the current scroll position -- it
// just scrolls to the bottom and fails. Use this instead when the target
// (typically app-live-state-card near the top, e.g. github-status-text)
// may be above wherever an earlier step left the scroll position.
Future<void> _scrollProjectTabToTop(WidgetTester tester) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const Key('app-tab-scroll')),
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
}

Future<void> _expandProjectDisclosure(
  WidgetTester tester, {
  required Key disclosureKey,
  required Key contentKey,
}) async {
  await _minimizeTerminalIfExpanded(tester);
  await _scrollProjectTabTo(tester, disclosureKey);
  final disclosure = find.byKey(disclosureKey);
  final header = find
      .descendant(of: disclosure, matching: find.byType(ListTile))
      .first;
  await _waitFor(
    tester,
    header,
    description: '${disclosureKey.toString()} disclosure header',
  );
  await Scrollable.ensureVisible(
    tester.element(header),
    alignment: 0.15,
    duration: const Duration(milliseconds: 200),
  );
  await tester.pumpAndSettle();
  final content = find.byKey(contentKey);
  // LiveTestWidgetsFlutterBinding dispatches taps as real pointer events
  // against the live app process, and the header itself can still be
  // settling (scroll-into-view, terminal-panel resize above it, an
  // in-flight rebuild) right as this tap is computed. A miss here has shown
  // up as Flutter's own "Some possible finders" hit-test diagnostic naming
  // ExpansionTile/the disclosure's own key as the nearby candidates rather
  // than the intended ListTile -- confirm the section actually expanded and
  // retry the tap instead of trusting one dispatched event.
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(
      tester,
      // AppDisclosureSection delegates its interactive header to ListTile.
      // The ExpansionTile widget is only the state container, so using its
      // center can fail hit testing even when the visible header is on
      // screen.
      header,
      description: '${disclosureKey.toString()} disclosure',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (content.evaluate().isNotEmpty) {
        // Settle the expand transition before the caller interacts with
        // content mounted mid-animation.
        await tester.pumpAndSettle();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail(
    'Tapping the ${disclosureKey.toString()} disclosure header never '
    'expanded it.',
  );
}

Future<void> _minimizeTerminalIfExpanded(WidgetTester tester) async {
  final minimizeButton = find.byKey(const Key('terminal-minimize-button'));
  if (minimizeButton.evaluate().isEmpty) {
    return;
  }
  // TerminalBottomSheet re-expands itself (didUpdateWidget: expandForTask
  // flips true while collapsed) whenever a new background task starts
  // tracking, which can race a prior operation still winding down right
  // after minimizing. A single tap-and-confirm isn't reliable against that,
  // so retry until it is still collapsed after settling, not just collapsed
  // in the one frame we happened to check.
  //
  // Poll without throwing on each attempt: an earlier version of this loop
  // called a shared wait helper that itself called fail() on its own
  // internal timeout, which threw out of this function on the first missed
  // attempt -- the retry loop's second and third attempts never actually ran.
  for (var attempt = 0; attempt < 3; attempt += 1) {
    await _tapFinder(
      tester,
      minimizeButton,
      description: 'minimize advanced activity before opening project details',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      if (minimizeButton.evaluate().isNotEmpty &&
          tester.widget<IconButton>(minimizeButton).tooltip ==
              'Open advanced activity') {
        await tester.pumpAndSettle();
        if (minimizeButton.evaluate().isNotEmpty &&
            tester.widget<IconButton>(minimizeButton).tooltip ==
                'Open advanced activity') {
          return;
        }
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  fail(
    'The advanced activity panel kept re-expanding itself instead of '
    'staying minimized.',
  );
}

Future<void> _waitForStatusText(
  WidgetTester tester,
  Key key,
  String expected, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) {
  return _waitForKeyTextContains(
    tester,
    key,
    expected,
    description: description,
    timeout: timeout,
  );
}

Future<void> _waitForKeyTextContains(
  WidgetTester tester,
  Key key,
  String expected, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final normalizedExpected = expected.toLowerCase();
  final finder = find.byKey(key);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) {
      final text = _readVisibleText(tester, finder).toLowerCase();
      if (text.contains(normalizedExpected)) {
        return;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  final visible = finder.evaluate().isEmpty
      ? '<not visible>'
      : _readVisibleText(tester, finder);
  fail('Timed out waiting for $description. Last visible text: $visible');
}

String _readVisibleText(WidgetTester tester, Finder finder) {
  final texts = tester
      .widgetList<Widget>(
        find.descendant(of: finder, matching: find.byType(Text)),
      )
      .whereType<Text>()
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
      .where((value) => value.trim().isNotEmpty)
      .join('\n');
  if (texts.trim().isNotEmpty) {
    return texts;
  }
  final selectables = tester
      .widgetList<Widget>(
        find.descendant(of: finder, matching: find.byType(SelectableText)),
      )
      .whereType<SelectableText>()
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '')
      .where((value) => value.trim().isNotEmpty)
      .join('\n');
  if (selectables.trim().isNotEmpty) {
    return selectables;
  }
  final widget = tester.widget(finder);
  if (widget is Text) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
  if (widget is SelectableText) {
    return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
  return widget.toStringShort();
}

bool _switchListTileValue(WidgetTester tester, Key key) {
  return tester.widget<SwitchListTile>(find.byKey(key)).value;
}

Future<void> _waitForSwitchListTileValue(
  WidgetTester tester,
  Key key,
  bool expected, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final finder = find.byKey(key);
    if (finder.evaluate().isNotEmpty &&
        tester.widget<SwitchListTile>(finder).value == expected) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('Timed out waiting for $description.');
}

// This used to read the URL back from the OS clipboard after tapping
// github-copy-oauth-url-button (Clipboard.setData/getData, a real
// platform-channel round trip to GTK on this engine). A poll-and-retry
// version of that (10s x 3 attempts) still failed on a live VM run with the
// exact same "not available" error, which rules out a plain timing race --
// something about this environment's GTK/portal clipboard path (see the
// "Failed to read XDG desktop portal settings" warnings every run prints at
// launch) never completes the round trip at all. Read the URL directly from
// GitHubIntegrationNotifier's state instead, the same
// ProviderScope.containerOf(tester.element(...), listen: false) pattern
// ux_audit.dart and project_deletion_recovery.dart already use elsewhere in
// this suite. This is strictly safe: app_deployment_methods.dart only renders
// github-copy-oauth-url-button when `authorizationUrl != null &&
// authorizationUrl.isNotEmpty` (canCopyUrl), so the state is guaranteed
// present the moment the button is. The button itself is not tapped, since
// no checklist row exercises copy-to-clipboard specifically and doing so
// would re-invoke the same stalled platform channel for no benefit.
Future<String> _tapCopyOauthUrlAndConfirmCopied(WidgetTester tester) async {
  final copyButton = find.byKey(const Key('github-copy-oauth-url-button'));
  await _waitFor(
    tester,
    copyButton,
    description: 'GitHub authorization URL copy button',
    timeout: const Duration(seconds: 45),
  );
  final container = ProviderScope.containerOf(
    tester.element(copyButton),
    listen: false,
  );
  final authUrl =
      container.read(gitHubIntegrationProvider).authorizationUrl?.trim() ?? '';
  if (!authUrl.startsWith('https://github.com/login/oauth/authorize')) {
    fail('GitHub authorization URL was not available from the app.');
  }
  return authUrl;
}

/// Completes GitHub OAuth through an operator-run relay instead of a browser.
///
/// The sandboxed test host cannot spawn browser automation, so when
/// `DEPLOYDASH_E2E_CALLBACK_RELAY` is set (a relay URL this host can reach
/// over HTTPS), the test publishes the authorization URL to stdout and waits
/// for the callback URL an external operator flow posts back. The wait is
/// two-phase (see [waitForRelayCallback]): a dead operator fails fast within
/// 10s instead of burning the whole callback window in silence.
/// Returns the `deploydash://callback?` URL or fails on timeout.
Future<String> _runGitHubRelayLogin(String authUrl) async {
  final relayUrl = Platform.environment['DEPLOYDASH_E2E_CALLBACK_RELAY']
      ?.trim();
  if (relayUrl == null || relayUrl.isEmpty) {
    return _runGitHubBrowserLogin(authUrl);
  }
  stdout.writeln('DEPLOYDASH_E2E_GITHUB_AUTH_URL=$authUrl');
  return waitForRelayCallback(relayBase: Uri.parse(relayUrl), authUrl: authUrl);
}

Future<String> _runGitHubBrowserLogin(String authUrl) async {
  final root = findRepositoryRoot();
  final helper = '${root.path}/qa/e2e/runners/github_browser_login.sh';
  final result = await Process.run(
    helper,
    const <String>[],
    environment: <String, String>{
      ...Platform.environment,
      'DEPLOYDASH_E2E_GITHUB_AUTH_URL': authUrl,
    },
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(const Duration(minutes: 3));
  if (result.exitCode != 0) {
    fail(
      'GitHub browser login failed.\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }

  final lines = (result.stdout as String)
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.startsWith('deploydash://callback?'))
      .toList(growable: false);
  if (lines.isEmpty) {
    fail('GitHub browser login did not print a callback URL.');
  }
  return lines.last;
}

Future<String> _waitForAny(
  WidgetTester tester,
  Map<String, Finder> finders, {
  required String description,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    for (final entry in finders.entries) {
      if (entry.value.evaluate().isNotEmpty) {
        return entry.key;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  fail('Timed out waiting for $description.');
}

/// Whether a Flutter error is the known RawScrollbar test-drive noise.
///
/// Debug-only scrollbar assertions fire spuriously when test-driven scrolling
/// (ensureVisible jumps) races scrollbar fade timers. They never fire in
/// release builds and carry no signal about the app, but flutter_test collects
/// them as unexpected async exceptions and fails otherwise-green runs. Match
/// the assertion text exactly; everything else stays fatal.
bool isScrollbarTestNoise(String message) {
  return message.contains('ScrollController has no ScrollPosition attached');
}

String _readWidgetText(WidgetTester tester, String key) {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    return 'Expected failure details were not visible.';
  }
  final texts = find
      .descendant(of: finder, matching: find.byType(SelectableText))
      .evaluate()
      .map((element) => (element.widget as SelectableText).data ?? '')
      .where((value) => value.trim().isNotEmpty)
      .toList();
  if (texts.isNotEmpty) {
    return texts.join('\n');
  }
  final plain = find
      .descendant(of: finder, matching: find.byType(Text))
      .evaluate()
      .map(
        (element) =>
            (element.widget as Text).data ??
            (element.widget as Text).textSpan?.toPlainText() ??
            '',
      )
      .where((value) => value.trim().isNotEmpty)
      .toList();
  if (plain.isNotEmpty) {
    return plain.join('\n');
  }
  final widget = tester.widget(finder);
  if (widget is SelectableText) {
    return widget.data ?? 'Setup failed, but no details were available.';
  }
  if (widget is Text) {
    return widget.data ??
        widget.textSpan?.toPlainText() ??
        'Visible text was empty.';
  }
  return widget.toStringShort();
}

/// Reads the setup failure summary plus the recent setup activity events.
///
/// The activity tile (`server-setup-current-activity`) stays expanded while
/// setup runs, so its [SelectableText] rows carry the engine events that led
/// to the failure. Surfacing them here is what makes a red E2E run
/// diagnosable without rerunning it.
String _readSetupFailureDetails(WidgetTester tester) {
  final summary = _readWidgetText(tester, 'server-setup-failure-message');
  final activityFinder = find.byKey(const Key('server-setup-current-activity'));
  if (activityFinder.evaluate().isEmpty) {
    return summary;
  }
  final events = find
      .descendant(of: activityFinder, matching: find.byType(SelectableText))
      .evaluate()
      .map((element) => (element.widget as SelectableText).data ?? '')
      .where((value) => value.trim().isNotEmpty)
      .toList();
  if (events.isEmpty) {
    return summary;
  }
  return '$summary\nRecent setup activity:\n${events.join('\n')}';
}

void _pass(
  String surfaceKey, [
  String message = 'Passed by live E2E flow.',
  Map<String, Object?> evidence = const <String, Object?>{},
]) {
  final result = E2eRunResult(
    surfaceKey: surfaceKey,
    status: 'passed',
    message: message,
    scenarioId: _productionSafetyScenarioForKey(surfaceKey),
    evidence: evidence,
  );
  final existingIndex = _runResults.indexWhere(
    (existing) => existing.surfaceKey == surfaceKey,
  );
  if (existingIndex == -1) {
    _runResults.add(result);
  } else {
    _runResults[existingIndex] = result;
  }
}

/// Fail the run when a slim macOS leg recorded checklist surfaces outside
/// [slimMacOsChecklistKeys]. A wider flow must extend the pinned set (and its
/// guard test) deliberately, never by accident.
void _validateSlimMacOsResults() {
  final unexpected = slimMacOsUnexpectedKeys(
    _runResults.map((result) => result.surfaceKey),
  );
  if (unexpected.isNotEmpty) {
    fail(
      'Slim macOS run recorded checklist keys outside the pinned slim set: '
      '${unexpected.join(', ')}.',
    );
  }
}

String? _productionSafetyScenarioForKey(String surfaceKey) {
  for (final scenario in productionSafetyScenarios) {
    if (scenario.requiredChecklistKeys.contains(surfaceKey)) {
      return scenario.id;
    }
  }
  return null;
}

String _e2eProjectSlug(String value) {
  final slug = value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isEmpty) {
    fail('The E2E project name did not produce a valid server slug.');
  }
  return slug;
}
