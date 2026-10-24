import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_checklist.dart';

/// Architecture invariant: an icon-only control carries a label, and the list
/// of ones that do not may only shrink.
///
/// `AGENTS.md` makes icon-only the strict default for row-level actions, so
/// these are the controls most likely to reach a user with nothing to announce
/// but "button". The E2E driver finds elements by `Key`, type and text, so
/// every existing gate passes whether or not a label exists — the
/// accessibility coverage was an illusion, which is what T-3.7.5 says.
///
/// A **tooltip is not a label.** Flutter puts it in
/// `SemanticsProperties.tooltip`; the label is the field assistive technology
/// reads first. `icon_control_semantics_test.dart` proves the shared
/// primitives are labelled by walking the semantics tree; this scans the
/// source, because the remaining sites are spread across screens that would
/// each need their own pump.
///
/// T-3.7.5 labelled 37 of the 55 sites by copying the literal tooltip each
/// already had. The 18 below have a computed tooltip or none, so each needs a
/// human decision about the wording rather than a copy.
const _unlabelledBaseline = <String, int>{
  'lib/ui/layout/app_navigation_rail.dart': 1,
  'lib/ui/project/workspace/app/app_deployment_models.dart': 1,
  'lib/ui/project/workspace/app/app_deployment_tab.dart': 2,
  'lib/ui/project/workspace/logs/log_tab.dart': 2,
  'lib/ui/project/workspace/scheduler/scheduler_tab.dart': 1,
  'lib/ui/server/management/docker_storage_section.dart': 1,
  'lib/ui/server/management/overview_tab.dart': 1,
  'lib/ui/server/management/services_postgres_remote_access_footer.dart': 1,
  'lib/ui/server/management/system_tab.dart': 1,
  'lib/ui/server/management/updates_tab.dart': 1,
  'lib/ui/startup/database_unlock_gate.dart': 1,
  'lib/ui/terminal/terminal_bottom_sheet.dart': 5,
};

/// Index just past the `)` matching the `(` that opens at [start].
int _balanced(String source, int start) {
  var index = start;
  var depth = 1;
  while (index < source.length && depth > 0) {
    final char = source[index];
    if (char == '(') depth += 1;
    if (char == ')') depth -= 1;
    index += 1;
  }
  return index;
}

Map<String, int> _unlabelledIconButtons(Directory libDirectory, String root) {
  final counts = <String, int>{};
  final files =
      libDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'))
          .where(
            (file) =>
                !file.path.endsWith('.g.dart') &&
                !file.path.endsWith('.freezed.dart'),
          )
          .toList()
        ..sort((left, right) => left.path.compareTo(right.path));

  for (final file in files) {
    final source = file.readAsStringSync();
    var searchFrom = 0;
    while (true) {
      final open = source.indexOf('IconButton(', searchFrom);
      if (open < 0) break;
      final argsStart = open + 'IconButton('.length;
      final argsEnd = _balanced(source, argsStart);
      final body = source.substring(argsStart, argsEnd - 1);
      if (!body.contains('semanticLabel')) {
        final relative = file.path
            .substring(root.length + 1)
            .replaceAll('\\', '/');
        counts[relative] = (counts[relative] ?? 0) + 1;
      }
      searchFrom = argsEnd;
    }
  }
  return counts;
}

void main() {
  test('the set of unlabelled icon buttons only shrinks', () {
    final root = findRepositoryRoot();
    final desktop = '${root.path}/ui';
    final counts = _unlabelledIconButtons(Directory('$desktop/lib'), desktop);

    final grown = <String>[
      for (final entry in counts.entries)
        if (entry.value > (_unlabelledBaseline[entry.key] ?? 0))
          '${entry.key}: ${entry.value} '
              '(baseline ${_unlabelledBaseline[entry.key] ?? 0})',
    ]..sort();
    expect(
      grown,
      isEmpty,
      reason:
          'A new icon-only button has no semantic label. Give its Icon a '
          'semanticLabel carrying the same verb its tooltip does:\n'
          '${grown.join('\n')}',
    );

    final stale = <String>[
      for (final entry in _unlabelledBaseline.entries)
        if ((counts[entry.key] ?? 0) < entry.value) entry.key,
    ]..sort();
    expect(
      stale,
      isEmpty,
      reason:
          'These now have fewer unlabelled buttons than the baseline claims. '
          'Lower it in the same commit, or the ratchet stops ratcheting:\n'
          '${stale.join('\n')}',
    );
  });

  test('the scan can see an unlabelled button', () {
    // A green run means something only if the scan matches a known-bad shape.
    const withLabel = 'IconButton(icon: Icon(Icons.add, semanticLabel: "Add"))';
    const without = 'IconButton(icon: Icon(Icons.add), tooltip: "Add")';
    expect(withLabel.contains('semanticLabel'), isTrue);
    expect(without.contains('semanticLabel'), isFalse);
    expect(_balanced('foo(bar(baz))x', 4), 13);
  });
}
