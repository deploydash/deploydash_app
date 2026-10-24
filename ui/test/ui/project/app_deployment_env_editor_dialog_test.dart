import 'package:ui/ui/project/project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DialogHost extends StatefulWidget {
  const _DialogHost({required this.dialog, required this.resultNotifier});

  final AppDeploymentEnvEditorDialog dialog;
  final ValueNotifier<AppDeploymentEnvEditorDialogResult?> resultNotifier;

  @override
  State<_DialogHost> createState() => _DialogHostState();
}

class _DialogHostState extends State<_DialogHost> {
  Future<void> _openDialog() async {
    widget.resultNotifier.value =
        await showDialog<AppDeploymentEnvEditorDialogResult>(
          context: context,
          builder: (_) => widget.dialog,
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(onPressed: _openDialog, child: const Text('Open')),
      ),
    );
  }
}

Future<ValueNotifier<AppDeploymentEnvEditorDialogResult?>> _pumpDialog(
  WidgetTester tester, {
  List<AppDeploymentEnvEditorDialogRow> initialRows = const [],
  Map<String, String> lastDeployedSnapshot = const <String, String>{},
  bool canSaveAndRedeploy = true,
}) async {
  final resultNotifier = ValueNotifier<AppDeploymentEnvEditorDialogResult?>(
    null,
  );
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1440, 1600);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: _DialogHost(
        resultNotifier: resultNotifier,
        dialog: AppDeploymentEnvEditorDialog(
          initialRows: initialRows,
          lastDeployedSnapshot: lastDeployedSnapshot,
          canSaveAndRedeploy: canSaveAndRedeploy,
        ),
      ),
    ),
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Open'));
  await tester.pumpAndSettle();
  expect(find.text('Environment variables'), findsOneWidget);
  return resultNotifier;
}

Finder _rowEditor(int index) => find.byKey(ValueKey('env-row-$index'));

Finder _rowKeyField(int index) => find
    .descendant(of: _rowEditor(index), matching: find.byType(TextFormField))
    .at(0);

Finder _rowValueField(int index) => find
    .descendant(of: _rowEditor(index), matching: find.byType(TextFormField))
    .at(1);

Finder _rowSecretSwitch(int index) =>
    find.descendant(of: _rowEditor(index), matching: find.byType(Switch));

Finder _rowDeleteButton(int index) => find.descendant(
  of: _rowEditor(index),
  matching: find.byTooltip('Remove env key'),
);

void main() {
  test(
    'normalizeAppDeploymentEnvRows removes blank keys and keeps last duplicate',
    () {
      final normalized = normalizeAppDeploymentEnvRows([
        const AppDeploymentEnvEditorDialogRow(key: ' API_KEY ', value: 'first'),
        const AppDeploymentEnvEditorDialogRow(key: '', value: 'ignored'),
        const AppDeploymentEnvEditorDialogRow(
          key: 'API_KEY',
          value: 'second',
          secret: true,
          changedSinceLastDeploy: true,
        ),
        const AppDeploymentEnvEditorDialogRow(key: 'PORT', value: '3000'),
      ]);

      expect(normalized, hasLength(2));
      expect(normalized[0].key, 'API_KEY');
      expect(normalized[0].value, 'second');
      expect(normalized[0].secret, isTrue);
      expect(normalized[0].changedSinceLastDeploy, isTrue);
      expect(normalized[1].key, 'PORT');
    },
  );

  test(
    'parseBulkAppDeploymentEnvRows handles dotenv lines, comments, quotes, and duplicates',
    () {
      final parsed = parseBulkAppDeploymentEnvRows('''
# comment
 export APP_NAME = "Deploy Dash"
APP_ENV=production
TOKEN=abc=123
APP_NAME='Deploy Dash Cloud'
INVALID_LINE
''');

      expect(parsed, hasLength(3));
      expect(parsed[0].key, 'APP_NAME');
      expect(parsed[0].value, 'Deploy Dash Cloud');
      expect(parsed[0].secret, isFalse);
      expect(parsed[1].key, 'APP_ENV');
      expect(parsed[1].value, 'production');
      expect(parsed[2].key, 'TOKEN');
      expect(parsed[2].value, 'abc=123');
    },
  );

  testWidgets(
    'search filters rows and shows empty state when nothing matches',
    (WidgetTester tester) async {
      await _pumpDialog(
        tester,
        initialRows: const [
          AppDeploymentEnvEditorDialogRow(key: 'API_KEY', value: 'one'),
          AppDeploymentEnvEditorDialogRow(key: 'TOKEN', value: 'two'),
        ],
      );

      expect(find.byKey(const ValueKey('env-row-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('env-row-1')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('env-search-field')), 'zzz');
      await tester.pumpAndSettle();

      expect(find.text('No variables match this search yet.'), findsOneWidget);
      expect(find.byKey(const ValueKey('env-row-0')), findsNothing);

      await tester.enterText(find.byKey(const Key('env-search-field')), 'api');
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('env-row-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('env-row-1')), findsNothing);
    },
  );

  testWidgets('new variable controls stay on one compact row', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);

    expect(find.text('Sensitive value'), findsNothing);
    expect(find.text('Secret'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Add variable'), findsNothing);
    expect(find.byTooltip('Add variable'), findsOneWidget);

    final keyCenter = tester.getCenter(
      find.byKey(const Key('env-new-key-field')),
    );
    final valueCenter = tester.getCenter(
      find.byKey(const Key('env-new-value-field')),
    );
    final secretCenter = tester.getCenter(
      find.byKey(const Key('env-new-secret-switch')),
    );
    final addCenter = tester.getCenter(
      find.byKey(const Key('env-add-row-button')),
    );

    expect((keyCenter.dy - valueCenter.dy).abs(), lessThan(1));
    expect((keyCenter.dy - secretCenter.dy).abs(), lessThan(16));
    expect((keyCenter.dy - addCenter.dy).abs(), lessThan(16));
  });

  testWidgets('editing and deleting rows is reflected in save result', (
    WidgetTester tester,
  ) async {
    final resultNotifier = await _pumpDialog(
      tester,
      initialRows: const [
        AppDeploymentEnvEditorDialogRow(key: 'API_KEY', value: 'old'),
        AppDeploymentEnvEditorDialogRow(key: 'TOKEN', value: 'remove-me'),
      ],
      lastDeployedSnapshot: const {'API_KEY': 'old'},
    );

    await tester.enterText(_rowKeyField(0), 'APP_KEY');
    await tester.enterText(_rowValueField(0), 'new');
    await tester.tap(_rowSecretSwitch(0));
    await tester.pumpAndSettle();

    await tester.tap(_rowDeleteButton(1));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('env-save-button')));
    await tester.pumpAndSettle();

    final result = resultNotifier.value;
    expect(result, isNotNull);
    expect(result!.redeployRequested, isFalse);
    expect(result.rows, hasLength(1));
    expect(result.rows.single.key, 'APP_KEY');
    expect(result.rows.single.value, 'new');
    expect(result.rows.single.secret, isTrue);
    expect(result.rows.single.changedSinceLastDeploy, isTrue);
  });

  testWidgets(
    'deleting the first row keeps the remaining row controllers aligned',
    (WidgetTester tester) async {
      await _pumpDialog(
        tester,
        initialRows: const [
          AppDeploymentEnvEditorDialogRow(key: 'REMOVE_ME', value: 'old'),
          AppDeploymentEnvEditorDialogRow(key: 'KEEP_ME', value: 'current'),
        ],
      );

      await tester.tap(_rowDeleteButton(0));
      await tester.pumpAndSettle();

      expect(_textFormFieldValue(tester, _rowKeyField(0)), 'KEEP_ME');
      expect(_textFormFieldValue(tester, _rowValueField(0)), 'current');
    },
  );

  testWidgets(
    'secret rows can reveal their value without changing the secret',
    (WidgetTester tester) async {
      await _pumpDialog(
        tester,
        initialRows: const [
          AppDeploymentEnvEditorDialogRow(
            key: 'API_TOKEN',
            value: 'token-value',
            secret: true,
          ),
        ],
      );

      expect(find.byIcon(Icons.visibility), findsOneWidget);

      await tester.tap(find.byIcon(Icons.visibility));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.visibility_off), findsOneWidget);
      expect(tester.widget<Switch>(_rowSecretSwitch(0)).value, isTrue);
    },
  );

  testWidgets('adding a row can request redeploy and empty keys are ignored', (
    WidgetTester tester,
  ) async {
    final resultNotifier = await _pumpDialog(
      tester,
      initialRows: const [
        AppDeploymentEnvEditorDialogRow(key: 'API_KEY', value: 'stable'),
      ],
      lastDeployedSnapshot: const {'API_KEY': 'stable'},
    );

    await tester.tap(find.byKey(const Key('env-add-row-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('env-row-1')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('env-new-key-field')),
      ' DATABASE_URL ',
    );
    await tester.enterText(
      find.byKey(const Key('env-new-value-field')),
      'postgresql://localhost:5432/app',
    );
    await tester.tap(find.byKey(const Key('env-new-secret-switch')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('env-add-row-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('env-row-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('env-save-redeploy-button')));
    await tester.pumpAndSettle();

    final result = resultNotifier.value;
    expect(result, isNotNull);
    expect(result!.redeployRequested, isTrue);
    expect(result.rows, hasLength(2));
    expect(result.rows[1].key, 'DATABASE_URL');
    expect(result.rows[1].secret, isTrue);
    expect(result.rows[1].changedSinceLastDeploy, isTrue);
  });

  testWidgets('bulk add dialog opens and can be cancelled', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);

    await tester.tap(find.byKey(const Key('env-bulk-add-button')));
    await tester.pumpAndSettle();

    expect(find.text('Import variables in bulk'), findsOneWidget);
    expect(find.byKey(const Key('env-bulk-import-field')), findsOneWidget);

    await tester.tap(find.byKey(const Key('env-bulk-import-cancel-button')));
    await tester.pumpAndSettle();

    expect(find.text('Import variables in bulk'), findsNothing);
    expect(find.text('Environment variables'), findsOneWidget);
  });

  testWidgets(
    'bulk add imports rows, overwrites matches, and defaults to non-secret',
    (WidgetTester tester) async {
      final resultNotifier = await _pumpDialog(
        tester,
        initialRows: const [
          AppDeploymentEnvEditorDialogRow(
            key: 'APP_ENV',
            value: 'local',
            secret: true,
          ),
          AppDeploymentEnvEditorDialogRow(
            key: 'QUEUE_CONNECTION',
            value: 'sync',
          ),
        ],
        lastDeployedSnapshot: const {
          'APP_ENV': 'local',
          'QUEUE_CONNECTION': 'sync',
        },
      );

      await tester.tap(find.byKey(const Key('env-bulk-add-button')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('env-bulk-import-field')), '''
# deploy block
APP_ENV=production
APP_KEY="base64:abc123"
QUEUE_CONNECTION=redis
''');
      await tester.tap(find.byKey(const Key('env-bulk-import-apply-button')));
      await tester.pumpAndSettle();

      expect(find.text('Import variables in bulk'), findsNothing);
      expect(find.byKey(const ValueKey('env-row-2')), findsOneWidget);
      expect(tester.widget<Switch>(_rowSecretSwitch(0)).value, isFalse);
      expect(tester.widget<Switch>(_rowSecretSwitch(2)).value, isFalse);
      expect(_textFormFieldValue(tester, _rowValueField(0)), 'production');
      expect(_textFormFieldValue(tester, _rowValueField(1)), 'redis');
      expect(_textFormFieldValue(tester, _rowValueField(2)), 'base64:abc123');

      await tester.tap(find.byKey(const Key('env-save-button')));
      await tester.pumpAndSettle();

      final result = resultNotifier.value;
      expect(result, isNotNull);
      expect(result!.rows, hasLength(3));
      expect(result.rows[0].key, 'APP_ENV');
      expect(result.rows[0].value, 'production');
      expect(result.rows[0].secret, isFalse);
      expect(result.rows[0].changedSinceLastDeploy, isTrue);
      expect(result.rows[1].key, 'QUEUE_CONNECTION');
      expect(result.rows[1].value, 'redis');
      expect(result.rows[1].changedSinceLastDeploy, isTrue);
      expect(result.rows[2].key, 'APP_KEY');
      expect(result.rows[2].value, 'base64:abc123');
      expect(result.rows[2].secret, isFalse);
      expect(result.rows[2].changedSinceLastDeploy, isTrue);
    },
  );

  testWidgets('bulk add shows an error when no valid KEY=value lines exist', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);

    await tester.tap(find.byKey(const Key('env-bulk-add-button')));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('env-bulk-import-field')), '''
# comment only
INVALID_LINE
ALSO INVALID
''');
    await tester.tap(find.byKey(const Key('env-bulk-import-apply-button')));
    await tester.pumpAndSettle();

    expect(find.text('Import variables in bulk'), findsOneWidget);
    expect(
      find.text('Paste at least one valid KEY=value line.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('env-bulk-import-field')), findsOneWidget);
  });

  testWidgets(
    'bulk add keeps changedSinceLastDeploy false when imported value matches the last deployed snapshot',
    (WidgetTester tester) async {
      final resultNotifier = await _pumpDialog(
        tester,
        initialRows: const [
          AppDeploymentEnvEditorDialogRow(key: 'APP_ENV', value: 'local'),
        ],
        lastDeployedSnapshot: const {
          'APP_ENV': 'production',
          'QUEUE_CONNECTION': 'redis',
        },
      );

      await tester.tap(find.byKey(const Key('env-bulk-add-button')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('env-bulk-import-field')), '''
APP_ENV=production
QUEUE_CONNECTION=redis
''');
      await tester.tap(find.byKey(const Key('env-bulk-import-apply-button')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('env-save-button')));
      await tester.pumpAndSettle();

      final result = resultNotifier.value;
      expect(result, isNotNull);
      expect(result!.rows, hasLength(2));
      expect(result.rows[0].key, 'APP_ENV');
      expect(result.rows[0].value, 'production');
      expect(result.rows[0].changedSinceLastDeploy, isFalse);
      expect(result.rows[1].key, 'QUEUE_CONNECTION');
      expect(result.rows[1].value, 'redis');
      expect(result.rows[1].changedSinceLastDeploy, isFalse);
    },
  );

  testWidgets('cancel returns null and redeploy button can be disabled', (
    WidgetTester tester,
  ) async {
    final resultNotifier = await _pumpDialog(tester, canSaveAndRedeploy: false);

    final redeployButton = tester.widget<FilledButton>(
      find.byKey(const Key('env-save-redeploy-button')),
    );
    expect(redeployButton.onPressed, isNull);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(resultNotifier.value, isNull);
  });
}

String _textFormFieldValue(WidgetTester tester, Finder finder) {
  final field = tester.widget<TextFormField>(finder);
  return field.controller?.text ?? '';
}
