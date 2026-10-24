import 'package:ui/providers/github_integration_provider.dart';
import 'package:ui/ui/project/project_workspace.dart';
import 'package:ui/ui/system/app_forms.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DialogHost extends StatefulWidget {
  const _DialogHost({required this.dialog, required this.resultNotifier});

  final AppDeploymentSettingsDialog dialog;
  final ValueNotifier<AppDeploymentSettingsDialogResult?> resultNotifier;

  @override
  State<_DialogHost> createState() => _DialogHostState();
}

class _DialogHostState extends State<_DialogHost> {
  Future<void> _openDialog() async {
    widget.resultNotifier.value =
        await showDialog<AppDeploymentSettingsDialogResult>(
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

Future<ValueNotifier<AppDeploymentSettingsDialogResult?>> _pumpDialog(
  WidgetTester tester, {
  String? initialRepository = 'deploydash/deploydash-agent-access',
  String initialPrimaryDomain = 'www.deploydash.com',
  String initialDomainRoutingMode = 'single_host',
  String initialBranch = 'main',
  String initialPortText = '3000',
  String initialRuntimeSelectionId = 'node',
  String initialBuildCommand = 'npm run build',
  String initialRunCommand = 'npm run start',
  String initialAppSubdirectory = '',
  List<AppDeploymentDnsProviderSpec> availableDnsProviderSpecs = const [],
  AppDeploymentTlsChallengeMode initialTlsChallengeMode =
      AppDeploymentTlsChallengeMode.http,
  String? initialDnsProvider,
  Map<String, String> initialDnsCredentials = const <String, String>{},
  bool initialPublicHealthCheckEnabled = true,
  String initialPublicHealthCheckPath = '/',
}) async {
  final resultNotifier = ValueNotifier<AppDeploymentSettingsDialogResult?>(
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
        dialog: AppDeploymentSettingsDialog(
          repositories: const [
            GitHubRepository(
              name: 'deploydash-agent-access',
              fullName: 'deploydash/deploydash-agent-access',
              isPrivate: false,
            ),
            GitHubRepository(
              name: 'laravel-example-app',
              fullName: 'deploydash/laravel-example-app',
              isPrivate: true,
            ),
          ],
          initialRepository: initialRepository,
          initialPrimaryDomain: initialPrimaryDomain,
          initialDomainRoutingMode: initialDomainRoutingMode,
          initialBranch: initialBranch,
          initialPortText: initialPortText,
          initialRuntimeSelectionId: initialRuntimeSelectionId,
          initialBuildCommand: initialBuildCommand,
          initialRunCommand: initialRunCommand,
          initialAppSubdirectory: initialAppSubdirectory,
          availableDnsProviderSpecs: availableDnsProviderSpecs,
          initialTlsChallengeMode: initialTlsChallengeMode,
          initialDnsProvider: initialDnsProvider,
          initialDnsCredentials: initialDnsCredentials,
          initialPublicHealthCheckEnabled: initialPublicHealthCheckEnabled,
          initialPublicHealthCheckPath: initialPublicHealthCheckPath,
        ),
      ),
    ),
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Open'));
  await tester.pumpAndSettle();
  expect(find.text('Review deployment settings'), findsOneWidget);
  return resultNotifier;
}

String _textFieldValue(WidgetTester tester, Key key) {
  final field = tester.widget<Widget>(find.byKey(key));
  return switch (field) {
    AppTextFormField(:final controller) => controller?.text ?? '',
    AppPasswordFormField(:final controller) => controller?.text ?? '',
    AppNumberFormField(:final controller) => controller?.text ?? '',
    TextFormField(:final controller) => controller?.text ?? '',
    _ => '',
  };
}

void main() {
  testWidgets('footer actions stay visible while long settings body scrolls', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();

    final saveButton = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Save'),
    );
    expect(saveButton, findsOneWidget);
    final initialSaveTop = tester.getTopLeft(saveButton).dy;

    await tester.drag(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(SingleChildScrollView),
      ),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();

    expect(saveButton, findsOneWidget);
    expect(tester.getTopLeft(saveButton).dy, initialSaveTop);
  });

  testWidgets('runtime switch updates default commands and port', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();

    expect(
      _textFieldValue(tester, const Key('deploy-build-command-field')),
      'npm run build',
    );
    expect(
      _textFieldValue(tester, const Key('deploy-run-command-field')),
      'npm run start',
    );
    expect(_textFieldValue(tester, const Key('deploy-app-port-field')), '3000');

    await tester.ensureVisible(find.byKey(const Key('deploy-runtime-field')));
    await tester.tap(find.byKey(const Key('deploy-runtime-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Python').last);
    await tester.pumpAndSettle();

    expect(
      _textFieldValue(tester, const Key('deploy-build-command-field')),
      '',
    );
    expect(_textFieldValue(tester, const Key('deploy-run-command-field')), '');
    expect(_textFieldValue(tester, const Key('deploy-app-port-field')), '8000');
  });

  testWidgets('runtime switch preserves custom commands and port', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('deploy-build-command-field')),
      'bin/custom-build',
    );
    await tester.enterText(
      find.byKey(const Key('deploy-run-command-field')),
      'bin/custom-start',
    );
    await tester.enterText(
      find.byKey(const Key('deploy-app-port-field')),
      '4567',
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('deploy-runtime-field')));
    await tester.tap(find.byKey(const Key('deploy-runtime-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Python').last);
    await tester.pumpAndSettle();

    expect(
      _textFieldValue(tester, const Key('deploy-build-command-field')),
      'bin/custom-build',
    );
    expect(
      _textFieldValue(tester, const Key('deploy-run-command-field')),
      'bin/custom-start',
    );
    expect(_textFieldValue(tester, const Key('deploy-app-port-field')), '4567');
  });

  testWidgets('dns challenge validates provider credentials and saves result', (
    WidgetTester tester,
  ) async {
    final resultNotifier = await _pumpDialog(
      tester,
      availableDnsProviderSpecs: const [
        AppDeploymentDnsProviderSpec(
          id: 'cloudflare',
          label: 'Cloudflare',
          description: 'Cloudflare DNS challenge',
          fields: [
            AppDeploymentDnsProviderFieldSpec(
              key: 'api_token',
              label: 'API token',
              hintText: 'Cloudflare API token',
            ),
          ],
        ),
      ],
    );

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('DNS challenge'));
    await tester.tap(find.text('DNS challenge'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a DNS provider.'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('deploy-dns-provider-field')),
    );
    await tester.tap(find.byKey(const Key('deploy-dns-provider-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cloudflare').last);
    await tester.pumpAndSettle();

    expect(find.text('API token is required.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('deploy-dns-cloudflare-api_token-field')),
      'cf-token',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(resultNotifier.value, isNotNull);
    expect(resultNotifier.value!.tlsChallengeMode, 'dns');
    expect(resultNotifier.value!.tlsDnsProvider, 'cloudflare');
    expect(resultNotifier.value!.tlsDnsCredentials, {'api_token': 'cf-token'});
  });

  testWidgets(
    'cloudns requires auth id or sub-auth id and cancel returns null',
    (WidgetTester tester) async {
      final resultNotifier = await _pumpDialog(
        tester,
        availableDnsProviderSpecs: const [
          AppDeploymentDnsProviderSpec(
            id: 'cloudns',
            label: 'ClouDNS',
            description: 'ClouDNS DNS challenge',
            fields: [
              AppDeploymentDnsProviderFieldSpec(
                key: 'auth_password',
                label: 'Auth password',
                hintText: 'ClouDNS auth password',
              ),
              AppDeploymentDnsProviderFieldSpec(
                key: 'auth_id',
                label: 'Auth ID (optional)',
                required: false,
                secret: false,
                hintText: 'ClouDNS auth ID',
              ),
              AppDeploymentDnsProviderFieldSpec(
                key: 'sub_auth_id',
                label: 'Sub-auth ID (optional)',
                required: false,
                secret: false,
                hintText: 'ClouDNS sub-auth ID',
              ),
            ],
          ),
        ],
      );

      await tester.tap(find.text('Advanced settings'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('DNS challenge'));
      await tester.tap(find.text('DNS challenge'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('deploy-dns-provider-field')),
      );
      await tester.tap(find.byKey(const Key('deploy-dns-provider-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ClouDNS').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('deploy-dns-cloudns-auth_password-field')),
        'cloudns-secret',
      );
      await tester.pumpAndSettle();

      expect(find.text('Provide Auth ID or Sub-auth ID.'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(resultNotifier.value, isNull);
    },
  );

  testWidgets('repository, domain, and branch changes are captured on save', (
    WidgetTester tester,
  ) async {
    final resultNotifier = await _pumpDialog(
      tester,
      initialRepository: null,
      initialPrimaryDomain: 'www.deploydash.com',
      initialBranch: 'main',
    );

    await tester.ensureVisible(find.byKey(const Key('github-repo-dropdown')));
    await tester.tap(find.byKey(const Key('github-repo-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('deploydash/laravel-example-app (private)').last,
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('deploy-primary-domain-field')),
      'api.deploydash.com',
    );
    await tester.enterText(
      find.byKey(const Key('deploy-branch-field')),
      'release/2026',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(resultNotifier.value, isNotNull);
    expect(
      resultNotifier.value!.repositoryFullName,
      'deploydash/laravel-example-app',
    );
    expect(resultNotifier.value!.primaryDomain, 'api.deploydash.com');
    expect(resultNotifier.value!.deployBranch, 'release/2026');
  });

  testWidgets('save normalizes routing and app subdirectory values', (
    WidgetTester tester,
  ) async {
    final resultNotifier = await _pumpDialog(
      tester,
      initialPrimaryDomain: 'www.example.com',
      initialDomainRoutingMode: 'single_host',
      initialAppSubdirectory: '',
    );

    await tester.tap(find.byKey(const Key('deploy-routing-apex-to-www')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('deploy-app-subdirectory-field')),
      '/website/',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(resultNotifier.value, isNotNull);
    expect(resultNotifier.value!.primaryDomain, 'example.com');
    expect(resultNotifier.value!.domainRoutingMode, 'redirect_apex_to_www');
    expect(resultNotifier.value!.canonicalDomain, 'www.example.com');
    expect(resultNotifier.value!.appSubdirectory, 'website');
  });

  testWidgets('public health path validates and is captured on save', (
    WidgetTester tester,
  ) async {
    final resultNotifier = await _pumpDialog(
      tester,
      initialPublicHealthCheckPath: '/up',
    );

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();
    const pathFieldKey = Key('deploy-public-health-path-field');
    final pathField = find.byKey(pathFieldKey);
    await tester.ensureVisible(pathField);
    expect(_textFieldValue(tester, pathFieldKey), '/up');

    await tester.enterText(pathField, 'health');
    await tester.pumpAndSettle();
    expect(
      find.text('Use a path that starts with "/", such as "/" or "/health".'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );

    await tester.enterText(pathField, '/health');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(resultNotifier.value?.publicHealthCheckEnabled, isTrue);
    expect(resultNotifier.value?.publicHealthCheckPath, '/health');
  });

  testWidgets('public health check can be explicitly disabled', (
    WidgetTester tester,
  ) async {
    final resultNotifier = await _pumpDialog(
      tester,
      initialPublicHealthCheckPath: 'invalid-path',
    );

    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('deploy-public-health-enabled-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('deploy-public-health-path-field')),
      findsNothing,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(resultNotifier.value?.publicHealthCheckEnabled, isFalse);
    expect(resultNotifier.value?.publicHealthCheckPath, '/');
  });

  testWidgets('dialog explains canonical redirects are enforced by Caddy', (
    WidgetTester tester,
  ) async {
    await _pumpDialog(tester);

    expect(find.text('Hostname behavior'), findsOneWidget);
    expect(
      find.text(
        'Choose whether visitors stay on one address or are redirected between www and non-www.',
      ),
      findsOneWidget,
    );
    expect(find.text('One hostname only'), findsOneWidget);
    expect(find.text('Main address without www'), findsOneWidget);
    expect(find.text('Main address with www'), findsOneWidget);
  });
}
