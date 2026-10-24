import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_checklist.dart';

/// Architecture invariant: one concept has one implementation.
///
/// Measurement: Dart source under `lib/` is scanned for private helper names
/// with divergent bodies and for duplicate type declarations. The scanner is
/// deliberately source-based: generated Drift output is part of the shipped
/// `lib/` surface, so a hand-written type cannot silently collide with it.

class _FunctionDefinition {
  const _FunctionDefinition({
    required this.name,
    required this.source,
    required this.body,
    this.lineCount = 0,
  });

  final String name;
  final String source;
  final String body;
  final int lineCount;
}

class _TypeDefinition {
  const _TypeDefinition({required this.name, required this.source});

  final String name;
  final String source;
}

class _NameExemption {
  const _NameExemption({required this.reason, required this.sourceCount});

  final String reason;
  final int sourceCount;
}

final _typeDeclaration = RegExp(
  r'^\s*(?:(?:abstract|base|final|interface|sealed|mixin)\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\b',
  multiLine: true,
);

// Flutter framework lifecycle hooks are intentionally polymorphic. The
// allowlist is named, not heuristic, so a small duplicated helper cannot hide
// behind a body-length cutoff.
const _polymorphicFunctionReasons = <String, String>{
  'build': 'Flutter widget render override.',
  'initState': 'Flutter lifecycle override.',
  'dispose': 'Flutter lifecycle override.',
  'createState': 'Flutter state-factory override.',
  'setState': 'Flutter state mutation API.',
};

// Every entry names the collision and fixes its observed source count. A new
// copy therefore fails instead of inheriting an open-ended exemption.
//
// NOTE (T-001): `_scopeKey` exists in 3 sources (backup, managed-database,
// app-release providers) but stays deliberately absent here: its bodies are
// byte-identical, so tests 1-2 cannot observe it (they require >= 2 distinct
// bodies), and the exact-set-equality assertion would fail if it were pinned.
// Dart has no identical-body check. D-85 owns the `_scopeKey` collapse.
const _sameNameBodyExemptions = <String, _NameExemption>{
  '_asInt': _NameExemption(
    reason: 'Repository-specific parsing boundaries.',
    sourceCount: 2,
  ),
  '_bindSelection': _NameExemption(
    reason: 'Each workspace tab owns its selection controller.',
    sourceCount: 4,
  ),
  '_buildConnectionPayload': _NameExemption(
    reason: 'Thin callers over the two shared payload builders.',
    sourceCount: 13,
  ),
  '_decodeJsonMap': _NameExemption(
    reason:
        'T-014 rollout: the four defs differ in nullability + exception '
        'behavior (backup non-null vs three nullable; catch-null vs '
        'propagate) — repository-specific persisted JSON shapes, kept.',
    sourceCount: 4,
  ),
  '_defaultSqliteVolumeName': _NameExemption(
    reason:
        'T-001 follow-up: project-only vs project+sqlite volume-name '
        'contracts share a name; the volume-name contract decision unifies '
        'or renames them.',
    sourceCount: 2,
  ),
  '_firstNonEmpty': _NameExemption(
    reason: 'Local precedence rules differ by call boundary.',
    sourceCount: 2,
  ),
  '_formatTimestamp': _NameExemption(
    reason: 'Workspace-specific timestamp presentation.',
    sourceCount: 2,
  ),
  '_isValidBranch': _NameExemption(
    reason: 'GitHub discovery and deploy validation have distinct contracts.',
    sourceCount: 3,
  ),
  '_isValidDomain': _NameExemption(
    reason: 'Each caller validates a different domain-input boundary.',
    sourceCount: 5,
  ),
  '_loadFromDatabase': _NameExemption(
    reason:
        'Providers own their distinct persistence hydration (D-24: the two '
        'preference notifiers collapsed into the shared base, leaving the '
        'server-list, project, and base defs).',
    sourceCount: 3,
  ),
  '_mapRow': _NameExemption(
    reason: 'Repositories map distinct Drift row types.',
    sourceCount: 5,
  ),
  '_normalizeAccessMode': _NameExemption(
    reason: 'Managed and shared database flows use distinct mode vocabularies.',
    sourceCount: 2,
  ),
  '_normalizeEngine': _NameExemption(
    reason: 'Managed and shared database flows use distinct engine inputs.',
    sourceCount: 2,
  ),
  '_normalizedAppSubdirectory': _NameExemption(
    reason: 'Project persistence and UI input boundaries remain separate.',
    sourceCount: 4,
  ),
  '_normalizedDomainConfig': _NameExemption(
    reason: 'D-22 folds the persistence/provider domain-config pair into one.',
    sourceCount: 2,
  ),
  '_normalizedDomainRoutingMode': _NameExemption(
    reason: 'Persistence and provider defaults remain separate pending T-3.1.',
    sourceCount: 2,
  ),
  '_normalizedSqliteFileName': _NameExemption(
    reason:
        'Persistence and deployment use different SQLite validation contexts.',
    sourceCount: 3,
  ),
  '_normalizedSqliteMountPath': _NameExemption(
    reason:
        'Persistence and deployment use different SQLite validation contexts.',
    sourceCount: 3,
  ),
  '_normalizedSqliteVolumeName': _NameExemption(
    reason:
        'Persistence and deployment use different SQLite validation contexts.',
    sourceCount: 3,
  ),
  '_normalizedTlsChallengeMode': _NameExemption(
    reason: 'Persistence and provider defaults remain separate pending T-3.1.',
    sourceCount: 2,
  ),
  '_requiredString': _NameExemption(
    reason: 'Desktop update and SQLite validation contexts differ.',
    sourceCount: 2,
  ),
  '_resolveEngineForServer': _NameExemption(
    reason: 'Backup and database tabs resolve their own supported engines.',
    sourceCount: 2,
  ),
  '_run': _NameExemption(
    reason:
        'T-001 follow-up: deletion-engine runner vs dashboard busy-guard '
        'runner share a generic name; the follow-up renames the dashboard '
        'site.',
    sourceCount: 2,
  ),
  '_runBackupNow': _NameExemption(
    reason:
        'T-001 follow-up: workspace managed-backup runner vs settings '
        'SQLite-backup runner share a name; the follow-up renames or '
        'extracts a shared runner.',
    sourceCount: 2,
  ),
  '_scheduleSelectionBind': _NameExemption(
    reason: 'Each workspace tab schedules its own selection binding.',
    sourceCount: 4,
  ),
};

const _duplicateTypeExemptions = <String, _NameExemption>{};

// T-2.6.8's first red run, 2026-09-03. Each entry names the task in
// docs/implementation-plans/duplication-collapse.md that removes it and is
// pinned to the member count observed then, so a new copy in an
// already-listed file still fails. The list may only shrink.
const _inFileNearDuplicateExemptions = <String, _NameExemption>{
  'lib/data/local/app_preferences_repository.dart': _NameExemption(
    reason: 'D-5 collapses the three single-field preference writers.',
    sourceCount: 3,
  ),
  'lib/domain/server.dart': _NameExemption(
    reason:
        'D-10 folds boolValue/parseBool into one coercion and gives toJsonMap '
        'a single owner.',
    sourceCount: 6,
  ),
  'lib/providers/project_managed_database_provider.dart': _NameExemption(
    reason:
        'D-7 decides whether the two deletes and the replace are one family '
        'or a coincidence of shape, and records the answer either way.',
    sourceCount: 3,
  ),
  'lib/providers/server_list_provider.dart': _NameExemption(
    reason:
        'D-1 collapses the updateSelectedServer* family -- 62% of the file, '
        'accreted over six commits and four months.',
    sourceCount: 5,
  ),
  'lib/services/concurrency_engine.dart': _NameExemption(
    reason: 'D-8 replaces the three enum parsers with one generic parser.',
    sourceCount: 3,
  ),
  'lib/ui/settings/app_settings_view.dart': _NameExemption(
    reason:
        'D-9 decides whether the three Agent Access delegates are worth '
        'collapsing, given the duplication is the test-injection seam itself.',
    sourceCount: 3,
  ),
};

// Pinned separately from _oneOwnerExemptionBaselineCount: this map keys on
// file rather than on a helper name, so a shared total would let a collapse
// here pay for a new exemption there.
const _inFileNearDuplicateBaselineCount = 6;

// T-2.6.5 records the full exception total after T-2.6.2. Each observed
// collision remains source-count-pinned; the aggregate may only decrease.
const _oneOwnerExemptionBaselineCount = 34;

Iterable<File> _dartSourceFiles(Directory libDirectory) sync* {
  for (final entity in libDirectory.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity;
    }
  }
}

String _removeWhitespaceAndComments(String body) {
  return body
      .replaceAll(RegExp(r'//[^\n]*'), '')
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
      .replaceAll(RegExp(r'\s+'), '');
}

int _matchingDelimiter(
  String source,
  int openIndex,
  String openChar,
  String closeChar,
) {
  var depth = 0;
  String? quote;
  var lineComment = false;
  var blockComment = false;
  var escaped = false;
  for (var index = openIndex; index < source.length; index += 1) {
    final character = source[index];
    if (lineComment) {
      if (character == '\n') {
        lineComment = false;
      }
      continue;
    }
    if (blockComment) {
      if (character == '*' &&
          index + 1 < source.length &&
          source[index + 1] == '/') {
        blockComment = false;
        index += 1;
      }
      continue;
    }
    if (quote != null) {
      if (quote.length == 3 && source.startsWith(quote, index)) {
        quote = null;
        index += 2;
      } else if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (quote.length == 1 && character == quote) {
        quote = null;
      }
      continue;
    }
    if (character == '/' && index + 1 < source.length) {
      final next = source[index + 1];
      if (next == '/') {
        lineComment = true;
        index += 1;
        continue;
      }
      if (next == '*') {
        blockComment = true;
        index += 1;
        continue;
      }
    }
    if ((character == "'" || character == '"') &&
        index + 2 < source.length &&
        source[index + 1] == character &&
        source[index + 2] == character) {
      quote = '$character$character$character';
      index += 2;
      continue;
    }
    if (character == "'" || character == '"') {
      quote = character;
      continue;
    }
    if (character == openChar) {
      depth += 1;
    } else if (character == closeChar) {
      depth -= 1;
      if (depth == 0) {
        return index;
      }
    }
  }
  return -1;
}

int _matchingBrace(String source, int openBrace) =>
    _matchingDelimiter(source, openBrace, '{', '}');

final _memberHeader = RegExp(
  r'(?:^|\n)\s*(?:(?:static|external)\s+)?(?:[A-Za-z0-9_<>,\s?\[\]]+?\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(',
);

Iterable<_FunctionDefinition> _allFunctionDefinitions(
  Directory libDirectory,
) sync* {
  for (final file in _dartSourceFiles(libDirectory)) {
    if (file.path.endsWith('.g.dart')) {
      continue;
    }
    final source = file.readAsStringSync();
    final relativeSource = file.path.substring(
      libDirectory.parent.path.length + 1,
    );
    for (final match in _memberHeader.allMatches(source)) {
      final name = match.group(1)!;
      if ({'if', 'while', 'for', 'switch', 'catch'}.contains(name)) {
        continue;
      }
      final parenOpen = match.end - 1;
      final parenClose = _matchingDelimiter(source, parenOpen, '(', ')');
      if (parenClose == -1) continue;

      var after = source
          .substring(parenClose + 1, min(parenClose + 100, source.length))
          .trimLeft();
      if (after.startsWith('async')) {
        after = after.substring(5).trimLeft();
      }
      if (after.startsWith('{')) {
        final braceOpen =
            parenClose +
            1 +
            (source
                    .substring(
                      parenClose + 1,
                      min(parenClose + 100, source.length),
                    )
                    .length -
                after.length);
        final braceClose = _matchingDelimiter(source, braceOpen, '{', '}');
        if (braceClose != -1) {
          final body = source.substring(braceOpen, braceClose + 1);
          final lines = body.split('\n').length;
          yield _FunctionDefinition(
            name: name,
            source: relativeSource,
            body: body,
            lineCount: lines,
          );
        }
      }
    }
  }
}

const _dartKeywords = <String>{
  'abstract',
  'as',
  'assert',
  'async',
  'await',
  'base',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'covariant',
  'default',
  'deferred',
  'do',
  'dynamic',
  'else',
  'enum',
  'export',
  'extends',
  'extension',
  'external',
  'factory',
  'false',
  'final',
  'finally',
  'for',
  'function',
  'get',
  'hide',
  'if',
  'implements',
  'import',
  'in',
  'interface',
  'is',
  'late',
  'library',
  'mixin',
  'new',
  'null',
  'of',
  'on',
  'operator',
  'part',
  'required',
  'rethrow',
  'return',
  'sealed',
  'set',
  'show',
  'static',
  'super',
  'switch',
  'sync',
  'this',
  'throw',
  'true',
  'try',
  'typedef',
  'var',
  'void',
  'when',
  'while',
  'with',
  'yield',
};

String _normaliseDart(String body) {
  var b = body.replaceAll(RegExp(r'//[^\n]*'), '');
  b = b.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final tokenRe = RegExp(
    r'[A-Za-z_][A-Za-z0-9_]*|"(?:\\.|[^"\\])*"|\x27(?:\\.|[^\x27\\])*\x27|\d+(?:\.\d+)?|[^\s\w]',
  );
  final tokens = tokenRe.allMatches(b).map((m) => m.group(0)!).toList();
  final names = <String, String>{};
  final literals = <String, String>{};
  final out = <String>[];
  for (final t in tokens) {
    if (_dartKeywords.contains(t) || !RegExp(r'^[A-Za-z_]').hasMatch(t)) {
      if (t.startsWith('"') ||
          t.startsWith("'") ||
          RegExp(r'^\d').hasMatch(t)) {
        out.add(literals.putIfAbsent(t, () => 'lit_${literals.length}'));
      } else {
        out.add(t);
      }
    } else {
      out.add(names.putIfAbsent(t, () => 'id_${names.length}'));
    }
  }
  return out.join(' ');
}

double _sequenceSimilarity(String a, String b) {
  if (a == b) return 1.0;
  if (a.isEmpty || b.isEmpty) return 0.0;
  final tokensA = a.split(' ');
  final tokensB = b.split(' ');
  final n = tokensA.length;
  final m = tokensB.length;
  if (n == 0 || m == 0) return 0.0;

  var prev = List<int>.filled(m + 1, 0);
  var curr = List<int>.filled(m + 1, 0);
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      if (tokensA[i - 1] == tokensB[j - 1]) {
        curr[j] = prev[j - 1] + 1;
      } else {
        curr[j] = max(prev[j], curr[j - 1]);
      }
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  final lcs = prev[m];
  return (2.0 * lcs) / (n + m);
}

// Why brace-matching here: the old `\([^;{}]*\)` parameter matcher could
// never match a declaration with named (`{...}`) parameters, so ~500 private
// `lib/` members were invisible to tests 1-2, including five genuine
// same-name/divergent-body collisions. Closing the parameter list with
// _matchingDelimiter mirrors _allFunctionDefinitions (plan
// docs/implementation-plans/duplication-collapse.md lines 33-111, T-001).
// Deliberately NOT skipping `.g.dart`: generated Drift output is part of the
// shipped `lib/` surface per the docstring above, and tests 1-3 have always
// policed it; _allFunctionDefinitions' skip stays local to test 4.
Iterable<_FunctionDefinition> _functionDefinitions(
  Directory libDirectory,
) sync* {
  for (final file in _dartSourceFiles(libDirectory)) {
    final source = file.readAsStringSync();
    final relativeSource = file.path.substring(
      libDirectory.parent.path.length + 1,
    );
    for (final match in _memberHeader.allMatches(source)) {
      final name = match.group(1)!;
      if ({'if', 'while', 'for', 'switch', 'catch'}.contains(name)) {
        continue;
      }
      if (!name.startsWith('_') &&
          !_polymorphicFunctionReasons.containsKey(name)) {
        continue;
      }
      final parenOpen = match.end - 1;
      final parenClose = _matchingDelimiter(source, parenOpen, '(', ')');
      if (parenClose == -1) continue;

      var after = source
          .substring(parenClose + 1, min(parenClose + 100, source.length))
          .trimLeft();
      if (after.startsWith('async')) {
        after = after.substring(5).trimLeft();
      }
      if (!after.startsWith('{')) {
        continue;
      }
      final braceOpen =
          parenClose +
          1 +
          (source
                  .substring(
                    parenClose + 1,
                    min(parenClose + 100, source.length),
                  )
                  .length -
              after.length);
      final braceClose = _matchingBrace(source, braceOpen);
      if (braceClose == -1) continue;
      yield _FunctionDefinition(
        name: name,
        source: relativeSource,
        body: _removeWhitespaceAndComments(
          source.substring(braceOpen, braceClose + 1),
        ),
      );
    }
  }
}

Iterable<_TypeDefinition> _typeDefinitions(Directory libDirectory) sync* {
  for (final file in _dartSourceFiles(libDirectory)) {
    final source = file.readAsStringSync();
    final relativeSource = file.path.substring(
      libDirectory.parent.path.length + 1,
    );
    for (final match in _typeDeclaration.allMatches(source)) {
      yield _TypeDefinition(name: match.group(1)!, source: relativeSource);
    }
  }
}

void main() {
  final root = findRepositoryRoot();
  final libDirectory = Directory('${root.path}/ui/lib');

  test(
    'one-owner exemptions are reasoned and match the observed collisions',
    () {
      final functionSources = <String, Set<String>>{};
      final functionBodies = <String, Set<String>>{};
      for (final definition in _functionDefinitions(libDirectory)) {
        if (!definition.name.startsWith('_')) {
          continue;
        }
        functionSources
            .putIfAbsent(definition.name, () => {})
            .add(definition.source);
        functionBodies
            .putIfAbsent(definition.name, () => {})
            .add(definition.body);
      }
      final observedFunctionExemptions = functionSources.entries
          .where(
            (entry) =>
                entry.value.length >= 2 &&
                functionBodies[entry.key]!.length >= 2,
          )
          .map((entry) => entry.key)
          .toSet();

      final typeSources = <String, Set<String>>{};
      for (final definition in _typeDefinitions(libDirectory)) {
        typeSources
            .putIfAbsent(definition.name, () => {})
            .add(definition.source);
      }
      final observedTypeExemptions = typeSources.entries
          .where((entry) => entry.value.length >= 2)
          .map((entry) => entry.key)
          .toSet();

      expect(_sameNameBodyExemptions.keys.toSet(), observedFunctionExemptions);
      expect(_duplicateTypeExemptions.keys.toSet(), observedTypeExemptions);
      for (final exemption in _sameNameBodyExemptions.values) {
        expect(exemption.reason.trim(), isNotEmpty);
      }
      for (final exemption in _duplicateTypeExemptions.values) {
        expect(exemption.reason.trim(), isNotEmpty);
      }
      for (final reason in _polymorphicFunctionReasons.values) {
        expect(reason.trim(), isNotEmpty);
      }
      for (final exemption in _inFileNearDuplicateExemptions.values) {
        expect(exemption.reason.trim(), isNotEmpty);
      }
      expect(
        _inFileNearDuplicateExemptions.length,
        lessThanOrEqualTo(_inFileNearDuplicateBaselineCount),
        reason:
            'In-file near-duplicate exemption count grew; collapse the family '
            'instead of pinning another file.',
      );
      expect(
        _sameNameBodyExemptions.length +
            _duplicateTypeExemptions.length +
            _polymorphicFunctionReasons.length,
        lessThanOrEqualTo(_oneOwnerExemptionBaselineCount),
        reason:
            'Dart one-owner exemption count grew; consolidate instead of '
            'normalising another duplicate.',
      );
    },
  );

  test('one private helper name has one body contract across lib', () {
    final byName = <String, List<_FunctionDefinition>>{};
    for (final definition in _functionDefinitions(libDirectory)) {
      byName.putIfAbsent(definition.name, () => []).add(definition);
    }

    final violations = <String>[];
    for (final entry in byName.entries) {
      final sources = entry.value
          .map((definition) => definition.source)
          .toSet();
      final bodies = entry.value.map((definition) => definition.body).toSet();
      if (sources.length < 2 || bodies.length < 2) {
        continue;
      }
      final exemption = _sameNameBodyExemptions[entry.key];
      if (_polymorphicFunctionReasons.containsKey(entry.key) ||
          (exemption != null && exemption.sourceCount == sources.length)) {
        continue;
      }
      violations.add('${entry.key}: ${sources.toList()..sort()}');
    }

    expect(
      violations,
      isEmpty,
      reason:
          'One-owner rule (same helper name, different bodies) failed: '
          '${violations..sort()}',
    );
  });

  test('one type name has one declaration across lib', () {
    final byName = <String, List<_TypeDefinition>>{};
    for (final definition in _typeDefinitions(libDirectory)) {
      byName.putIfAbsent(definition.name, () => []).add(definition);
    }

    final violations = <String>[];
    for (final entry in byName.entries) {
      final sources = entry.value
          .map((definition) => definition.source)
          .toSet();
      final exemption = _duplicateTypeExemptions[entry.key];
      if (sources.length < 2 ||
          (exemption != null && exemption.sourceCount == sources.length)) {
        continue;
      }
      violations.add('${entry.key}: ${sources.toList()..sort()}');
    }

    expect(
      violations,
      isEmpty,
      reason:
          'One-owner rule (type declared in multiple lib files) failed: '
          '${violations..sort()}',
    );
  });

  test('no file contains three or more near-duplicate member bodies', () {
    final byFile = <String, List<_FunctionDefinition>>{};
    for (final definition in _allFunctionDefinitions(libDirectory)) {
      if (definition.lineCount >= 8) {
        byFile.putIfAbsent(definition.source, () => []).add(definition);
      }
    }

    final violations = <String>[];
    for (final entry in byFile.entries) {
      final defs = entry.value;
      if (defs.length < 3) continue;

      final adj = List.generate(defs.length, (_) => <int>{});
      final normalised = defs.map((d) => _normaliseDart(d.body)).toList();
      for (var i = 0; i < defs.length; i++) {
        for (var j = i + 1; j < defs.length; j++) {
          final sim = _sequenceSimilarity(normalised[i], normalised[j]);
          if (sim >= 0.9) {
            adj[i].add(j);
            adj[j].add(i);
          }
        }
      }

      final visited = <int>{};
      final clusters = <List<String>>[];
      for (var i = 0; i < defs.length; i++) {
        if (!visited.contains(i) && adj[i].length >= 2) {
          final comp = <String>[];
          final queue = [i];
          visited.add(i);
          while (queue.isNotEmpty) {
            final curr = queue.removeAt(0);
            comp.add(defs[curr].name);
            for (final neighbor in adj[curr]) {
              if (!visited.contains(neighbor)) {
                visited.add(neighbor);
                queue.add(neighbor);
              }
            }
          }
          if (comp.length >= 3) {
            clusters.add(comp);
          }
        }
      }

      if (clusters.isEmpty) continue;

      final totalMembers = clusters.fold<int>(0, (sum, c) => sum + c.length);
      final exemption = _inFileNearDuplicateExemptions[entry.key];
      if (exemption == null || exemption.sourceCount != totalMembers) {
        final clusterDesc = clusters
            .map((c) => '[${(c.toSet().toList()..sort()).join(', ')}]')
            .join('; ');
        violations.add('${entry.key} ($totalMembers members): $clusterDesc');
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'One-owner rule (near-duplicate member bodies inside one file) failed: '
          '${(violations..sort()).join(' | ')}',
    );
  });
}
