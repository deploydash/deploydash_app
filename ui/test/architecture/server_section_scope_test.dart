import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture invariant: a Server Management section shows one server.
///
/// Switching servers must never leave the previous machine's data on screen
/// under a different server's name. Two mechanisms achieve that, and the
/// repository uses both deliberately:
///
///  * `didUpdateWidget` compares `oldWidget.server` and clears the cached
///    fields — what `overview_tab`, `firewall_tab`, `services_tab`,
///    `system_tab` and `updates_tab` do; or
///  * the construction site gives the widget a key derived from the server
///    id, so a changed server replaces the element instead of updating it and
///    the state starts empty — what `system_tab.dart` does for
///    `_DockerStorageSection`.
///
/// The second is why G-33's premise was wrong: the section has no
/// `didUpdateWidget` and never needed one. This guard therefore accepts either
/// mechanism and fails only on a section that has neither. Requiring
/// `didUpdateWidget` from all of them would push dead code into the keyed one,
/// because a changed key means `didUpdateWidget` can never fire.
void main() {
  test('every server management section is scoped to one server', () {
    final directory = Directory('lib/ui/server/management');
    expect(
      directory.existsSync(),
      isTrue,
      reason:
          'the measured directory must exist for this guard to mean '
          'anything; if it moved, update this test rather than deleting it',
    );

    final dartFiles = [
      ...directory.listSync().whereType<File>(),
      File('lib/ui/server/server_management_view.dart'),
    ].where((file) => file.path.endsWith('.dart')).toList(growable: false);
    final allSources = {
      for (final file in dartFiles) file.path: file.readAsStringSync(),
    };

    final sectionFilePattern = RegExp(r'_(tab|section)\.dart$');
    final widgetClassPattern = RegExp(
      r'class\s+(\w+)\s+extends\s+(?:Consumer)?StatefulWidget',
    );

    final offenders = <String>[];
    var sectionsChecked = 0;

    for (final entry in allSources.entries) {
      if (!sectionFilePattern.hasMatch(entry.key)) {
        continue;
      }
      final source = entry.value;
      if (!source.contains('extends ConsumerState<') &&
          !source.contains('extends State<')) {
        continue;
      }
      sectionsChecked += 1;
      final name = Uri.file(entry.key).pathSegments.last;

      final rebindsOnUpdate =
          source.contains('void didUpdateWidget') &&
          source.contains('oldWidget.server');
      if (rebindsOnUpdate) {
        continue;
      }

      // Otherwise some construction site must key it by the server id.
      final widgetClass = widgetClassPattern.firstMatch(source)?.group(1);
      if (widgetClass == null) {
        offenders.add('$name: no didUpdateWidget and no widget class found');
        continue;
      }
      final constructionPattern = RegExp(
        '$widgetClass\\('
        r'[\s\S]{0,400}?key:[\s\S]{0,200}?server\??\.id',
      );
      final keyedByServer = allSources.values.any(
        (candidate) => constructionPattern.hasMatch(candidate),
      );
      if (!keyedByServer) {
        offenders.add(
          '$name: neither rebinds in didUpdateWidget nor is constructed with '
          'a key derived from the server id',
        );
      }
    }

    expect(
      sectionsChecked,
      greaterThanOrEqualTo(6),
      reason:
          'the scan found fewer stateful sections than exist; a renamed '
          'suffix would make this guard silently measure nothing',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'each of these renders one server and must not carry another '
          "server's data across a selection change (G-33)",
    );
  });
}
