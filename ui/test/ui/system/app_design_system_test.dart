import 'dart:ui' show Tristate;

import 'package:ui/ui/system/app_actions.dart';
import 'package:ui/ui/system/app_context_navigation.dart';
import 'package:ui/ui/system/app_dialogs.dart';
import 'package:ui/ui/system/app_forms.dart';
import 'package:ui/ui/system/app_sections.dart';
import 'package:ui/ui/system/app_state_views.dart';
import 'package:ui/ui/system/app_theme.dart';
import 'package:ui/ui/system/app_workspace.dart';
import 'package:ui/ui/system/container_runtime_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

Widget _wrap(Widget child, {Brightness brightness = Brightness.light}) {
  final baseTheme = brightness == Brightness.light
      ? ThemeData.light()
      : ThemeData.dark();
  return MaterialApp(
    theme: buildDeployDashTheme(baseTheme),
    home: Scaffold(body: child),
  );
}

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  test('AppThemeTokens copyWith and lerp keep expected values', () {
    const tokens = AppThemeTokens.desktop();
    final copied = tokens.copyWith(spaceMd: 18, radiusLg: 20);
    final copiedDefaults = tokens.copyWith();
    final lerped = tokens.lerp(
      const AppThemeTokens.desktop().copyWith(spaceMd: 20),
      0.5,
    );

    expect(copied.spaceMd, 18);
    expect(copied.radiusLg, 20);
    expect(copiedDefaults.spaceMd, tokens.spaceMd);
    expect(lerped.spaceMd, 18);
    expect(tokens.lerp(null, 0.5), same(tokens));
  });

  test('Deploy Dash theme helpers resolve both light and dark palettes', () {
    final lightTheme = buildDeployDashTheme(ThemeData.light());
    final darkTheme = buildDeployDashTheme(ThemeData.dark());

    expect(appSidebarColor(lightTheme), const Color(0xFFF2F3F5));
    expect(appSidebarColor(darkTheme), const Color(0xFF1E2024));
    expect(appSidebarForegroundColor(lightTheme), const Color(0xFF202227));
    expect(appSidebarForegroundColor(darkTheme), Colors.white);
    expect(appSidebarMutedForegroundColor(lightTheme), const Color(0xFF5E6470));
    expect(appSidebarMutedForegroundColor(darkTheme), Colors.white70);
    expect(lightTheme.extension<AppThemeTokens>(), isNotNull);
    expect(lightTheme.cardTheme.shape, isNotNull);
    expect(lightTheme.dialogTheme.shape, isNotNull);
    expect(lightTheme.inputDecorationTheme.filled, isTrue);
    expect(lightTheme.snackBarTheme.behavior, SnackBarBehavior.floating);
    expect(lightTheme.tabBarTheme.dividerColor, isNotNull);
    expect(appSurfaceColor(lightTheme), isNot(lightTheme.colorScheme.surface));
    expect(appBorderColor(lightTheme), isNot(Colors.transparent));

    GoogleFonts.config.allowRuntimeFetching = true;
    final noFetchTheme = buildDeployDashTheme(
      ThemeData.light(),
      googleSansTextThemeBuilder: (baseTheme) => baseTheme,
    );
    GoogleFonts.config.allowRuntimeFetching = false;
    expect(noFetchTheme.textTheme.bodyMedium, isNotNull);
  });

  testWidgets('Section card renders header, action, and content', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppSectionCard(
          title: 'Servers',
          subtitle: 'Manage your infrastructure',
          icon: Icons.storage_rounded,
          headerAction: TextButton(
            onPressed: () {},
            child: const Text('Refresh'),
          ),
          child: const Text('Body content'),
        ),
      ),
    );

    expect(find.text('Servers'), findsOneWidget);
    expect(find.text('Manage your infrastructure'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Body content'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(
        const AppSectionCard(title: 'System', child: Text('Plain section')),
      ),
    );

    expect(find.text('System'), findsOneWidget);
    expect(find.text('Plain section'), findsOneWidget);
  });

  testWidgets('Section card can keep primary action before long content', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        SingleChildScrollView(
          child: AppSectionCard(
            title: 'Review',
            primaryActionPanel: AppPrimaryActionPanel(
              currentState: 'Ready to continue',
              description: 'The next action stays visible before details.',
              primaryAction: FilledButton(
                key: const Key('primary-action'),
                onPressed: () {},
                child: const Text('Continue'),
              ),
              blockingReason: 'Fix the hostname before continuing.',
              blockingReasonKey: const Key('primary-action-blocked-reason'),
            ),
            child: Column(
              children: List.generate(20, (index) => Text('Detail row $index')),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('primary-action')), findsOneWidget);
    expect(
      find.byKey(const Key('primary-action-blocked-reason')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('primary-action'))).dy,
      lessThan(tester.getTopLeft(find.text('Detail row 0')).dy),
    );
  });

  testWidgets('Section footers render below the body on both section kinds', (
    WidgetTester tester,
  ) async {
    // `footer` was reachable but unexercised: both call sites read it through
    // a `!`, which kept its line marked covered whether or not a footer was
    // ever supplied. Hoisting the field for T-3.7.3 made the gap visible.
    await tester.pumpWidget(
      _wrap(
        const Column(
          children: [
            AppSectionCard(
              title: 'Card',
              footer: Text('Card footer'),
              child: Text('Card body'),
            ),
            AppWorkspaceSection(
              title: 'Workspace',
              footer: Text('Workspace footer'),
              child: Text('Workspace body'),
            ),
          ],
        ),
      ),
    );

    expect(find.text('Card footer'), findsOneWidget);
    expect(find.text('Workspace footer'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Card footer')).dy,
      greaterThan(tester.getTopLeft(find.text('Card body')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Workspace footer')).dy,
      greaterThan(tester.getTopLeft(find.text('Workspace body')).dy),
    );
  });

  testWidgets('Toggle and checkbox fields render their subtitle', (
    WidgetTester tester,
  ) async {
    // Same gap as the section footers: `AppCheckboxField` was only ever
    // rendered without a subtitle, and reading the field through a `!` kept
    // the line looking covered.
    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            AppToggleField(
              value: true,
              title: 'Automatic updates',
              subtitle: 'Security patches install without asking.',
              onChanged: (_) {},
            ),
            AppCheckboxField(
              value: false,
              title: 'I understand',
              subtitle: 'The local project record is deleted permanently.',
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    );

    expect(
      find.text('Security patches install without asking.'),
      findsOneWidget,
    );
    expect(
      find.text('The local project record is deleted permanently.'),
      findsOneWidget,
    );
  });

  testWidgets('Primary action panel stacks actions in compact layouts', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 400,
          child: AppPrimaryActionPanel(
            currentState: 'Ready to deploy',
            description: 'The compact layout keeps the next step clear.',
            primaryAction: FilledButton(
              onPressed: () {},
              child: const Text('Deploy'),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Ready to deploy'), findsOneWidget);
    expect(find.text('Deploy'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Deploy')).dy,
      greaterThan(tester.getTopLeft(find.text('Ready to deploy')).dy),
    );
  });

  testWidgets('Workspace section renders an unframed heading and content', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppWorkspaceSection(
          title: 'Projects',
          subtitle: 'Two projects',
          icon: Icons.folder_outlined,
          headerAction: IconButton(
            tooltip: 'Refresh projects',
            onPressed: () {},
            icon: const Icon(Icons.refresh),
          ),
          child: const Text('Project list'),
        ),
      ),
    );

    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Two projects'), findsOneWidget);
    expect(find.byTooltip('Refresh projects'), findsOneWidget);
    expect(find.text('Project list'), findsOneWidget);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('Context navigation supports vertical and compact selection', (
    WidgetTester tester,
  ) async {
    final firstItemId = 'web-app';
    final items = [
      AppContextNavigationItem(
        id: firstItemId,
        label: 'Web app',
        icon: Icons.web_outlined,
      ),
      AppContextNavigationItem(
        id: 'database',
        label: 'Database',
        icon: Icons.storage_outlined,
      ),
    ];
    var selectedIndex = -1;

    await tester.pumpWidget(
      _wrap(
        AppContextNavigation(
          items: items,
          selectedIndex: 0,
          onSelected: (value) => selectedIndex = value,
          axis: Axis.vertical,
          keyNamespace: 'test-context',
        ),
      ),
    );

    expect(
      find.byKey(const Key('app-context-navigation-test-context-vertical')),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('test-context-nav-web-app')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    final selectedSurface = tester.widget<Material>(
      find.byKey(const Key('test-context-nav-web-app-surface')),
    );
    final selectedShape = selectedSurface.shape! as RoundedRectangleBorder;
    expect(selectedSurface.color, isNot(Colors.transparent));
    expect(selectedShape.side.color, isNot(Colors.transparent));
    final selectedMarker = tester.widget<Container>(
      find.byKey(const Key('test-context-nav-web-app-selection-marker')),
    );
    final selectedMarkerDecoration =
        selectedMarker.decoration! as BoxDecoration;
    expect(selectedMarkerDecoration.color, isNot(Colors.transparent));
    await tester.tap(find.byKey(const Key('test-context-nav-database')));
    expect(selectedIndex, 1);

    await tester.pumpWidget(
      _wrap(
        AppContextNavigation(
          items: items,
          selectedIndex: 1,
          onSelected: (value) => selectedIndex = value,
          axis: Axis.horizontal,
          keyNamespace: 'test-context',
        ),
      ),
    );
    expect(
      find.byKey(const Key('app-context-navigation-test-context-horizontal')),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('test-context-nav-database')))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(
      tester
          .widget<Material>(
            find.byKey(const Key('test-context-nav-database-surface')),
          )
          .color,
      isNot(Colors.transparent),
    );
    await tester.tap(find.widgetWithText(Tab, 'Web app'));
    expect(selectedIndex, 0);
  });

  testWidgets('Workspace scaffold adapts navigation and bounds content', (
    WidgetTester tester,
  ) async {
    const destinations = [
      AppContextNavigationItem(
        id: 'overview',
        label: 'Overview',
        icon: Icons.dashboard_outlined,
      ),
      AppContextNavigationItem(
        id: 'services',
        label: 'Services',
        icon: Icons.dns_outlined,
      ),
    ];
    var selectedIndex = -1;

    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _wrap(
        AppWorkspaceScaffold(
          destinations: destinations,
          selectedIndex: 0,
          onSelected: (value) => selectedIndex = value,
          navigationKeyNamespace: 'workspace-test',
          maxContentWidth: 500,
          banner: const Text('Workspace notice'),
          child: Container(key: const Key('bounded-workspace-content')),
        ),
      ),
    );

    expect(find.text('Workspace notice'), findsOneWidget);
    expect(
      find.byKey(const Key('app-context-navigation-workspace-test-vertical')),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const Key('bounded-workspace-content'))).width,
      500,
    );
    await tester.tap(find.byKey(const Key('workspace-test-nav-services')));
    expect(selectedIndex, 1);

    tester.view.physicalSize = const Size(799, 700);
    await tester.pumpWidget(
      _wrap(
        AppWorkspaceScaffold(
          destinations: destinations,
          selectedIndex: 1,
          onSelected: (value) => selectedIndex = value,
          navigationKeyNamespace: 'workspace-test',
          fullWidth: true,
          contentPadding: EdgeInsets.zero,
          child: Container(key: const Key('full-width-workspace-content')),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('app-context-navigation-workspace-test-horizontal')),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.byKey(const Key('full-width-workspace-content')))
          .width,
      799,
    );
  });

  testWidgets('Workspace breakpoints switch at exact contract boundaries', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget responsiveBody() {
      return _wrap(
        Column(
          children: [
            AppWorkspaceHeader(
              title: 'Header title',
              actions: [
                FilledButton(
                  key: const Key('header-action'),
                  onPressed: () {},
                  child: const Text('Continue'),
                ),
              ],
            ),
            AppMasterDetail(
              master: Container(
                key: const Key('master-pane'),
                height: 40,
                color: Colors.red,
              ),
              detail: Container(
                key: const Key('detail-pane'),
                height: 40,
                color: Colors.blue,
              ),
            ),
          ],
        ),
      );
    }

    tester.view.physicalSize = const Size(519, 500);
    await tester.pumpWidget(responsiveBody());
    expect(
      tester.getTopLeft(find.byKey(const Key('header-action'))).dy,
      greaterThan(tester.getTopLeft(find.text('Header title')).dy),
    );

    tester.view.physicalSize = const Size(520, 500);
    await tester.pumpWidget(responsiveBody());
    expect(
      tester.getTopLeft(find.byKey(const Key('header-action'))).dx,
      greaterThan(tester.getTopLeft(find.text('Header title')).dx),
    );

    tester.view.physicalSize = const Size(959, 500);
    await tester.pumpWidget(responsiveBody());
    expect(
      tester.getTopLeft(find.byKey(const Key('detail-pane'))).dy,
      greaterThan(tester.getTopLeft(find.byKey(const Key('master-pane'))).dy),
    );

    tester.view.physicalSize = const Size(960, 500);
    await tester.pumpWidget(responsiveBody());
    expect(
      tester.getTopLeft(find.byKey(const Key('detail-pane'))).dx,
      greaterThan(tester.getTopLeft(find.byKey(const Key('master-pane'))).dx),
    );
  });

  testWidgets('Context navigation switches at 799 and 800 pixels', (
    WidgetTester tester,
  ) async {
    const destinations = [
      AppContextNavigationItem(
        id: 'overview',
        label: 'Overview',
        icon: Icons.dashboard_outlined,
      ),
    ];
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Widget scaffold() => _wrap(
      AppWorkspaceScaffold(
        destinations: destinations,
        selectedIndex: 0,
        onSelected: (_) {},
        navigationKeyNamespace: 'boundary',
        child: const SizedBox.shrink(),
      ),
    );

    tester.view.physicalSize = const Size(799, 500);
    await tester.pumpWidget(scaffold());
    expect(
      find.byKey(const Key('app-context-navigation-boundary-horizontal')),
      findsOneWidget,
    );

    tester.view.physicalSize = const Size(800, 500);
    await tester.pumpWidget(scaffold());
    expect(
      find.byKey(const Key('app-context-navigation-boundary-vertical')),
      findsOneWidget,
    );
  });

  testWidgets('Status badges cover every shared semantic tone', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        Wrap(
          children: [
            const AppStatusBadge(label: 'Neutral'),
            const AppStatusBadge(
              label: 'Information',
              tone: AppStatusTone.info,
            ),
            const AppStatusBadge(
              label: 'Ready',
              tone: AppStatusTone.positive,
              icon: Icons.check,
            ),
            const AppStatusBadge(label: 'Warning', tone: AppStatusTone.warning),
            const AppStatusBadge(label: 'Failed', tone: AppStatusTone.negative),
            AppStatusBadge(
              label: 'Working',
              leading: const SizedBox.square(dimension: 10),
            ),
          ],
        ),
      ),
    );

    for (final label in [
      'Neutral',
      'Information',
      'Ready',
      'Warning',
      'Failed',
      'Working',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  test('Container runtime states use one shared status-tone mapping', () {
    expect(
      appContainerRuntimeStatusTone(ContainerRuntimeEffectiveStatus.ready),
      AppStatusTone.positive,
    );
    for (final status in [
      ContainerRuntimeEffectiveStatus.starting,
      ContainerRuntimeEffectiveStatus.provisioning,
    ]) {
      expect(appContainerRuntimeStatusTone(status), AppStatusTone.info);
    }
    for (final status in [
      ContainerRuntimeEffectiveStatus.restarting,
      ContainerRuntimeEffectiveStatus.stopped,
    ]) {
      expect(appContainerRuntimeStatusTone(status), AppStatusTone.warning);
    }
    expect(
      appContainerRuntimeStatusTone(ContainerRuntimeEffectiveStatus.unhealthy),
      AppStatusTone.negative,
    );
    for (final status in [
      ContainerRuntimeEffectiveStatus.missing,
      ContainerRuntimeEffectiveStatus.notConfigured,
      ContainerRuntimeEffectiveStatus.unknown,
    ]) {
      expect(appContainerRuntimeStatusTone(status), AppStatusTone.neutral);
    }
  });

  testWidgets('Focused flow keeps its action footer fixed', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(700, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _wrap(
        AppFocusedFlowScaffold(
          productName: 'Deploy Dash',
          title: 'Create a project',
          subtitle: 'Complete the fields below.',
          icon: Icons.add,
          actions: [
            FilledButton(
              key: const Key('focused-flow-action'),
              onPressed: () {},
              child: const Text('Create'),
            ),
          ],
          child: Column(
            children: List.generate(30, (index) => Text('Field $index')),
          ),
        ),
      ),
    );

    final action = find.byKey(const Key('focused-flow-action'));
    final initialTop = tester.getTopLeft(action).dy;
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(action).dy, initialTop);
    expect(find.text('Deploy Dash'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets(
    'Compact navigation keeps selection visible and keyboard usable',
    (WidgetTester tester) async {
      var selected = 11;
      final items = List.generate(
        12,
        (index) => AppContextNavigationItem(
          id: 'item-$index',
          label: 'Destination $index',
          icon: Icons.circle_outlined,
        ),
      );
      tester.view.physicalSize = const Size(320, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _wrap(
          AppContextNavigation(
            items: items,
            selectedIndex: selected,
            onSelected: (value) => selected = value,
            axis: Axis.horizontal,
            keyNamespace: 'many-items',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final selectedRect = tester.getRect(
        find.byKey(const Key('many-items-nav-item-11')),
      );
      expect(selectedRect.left, greaterThanOrEqualTo(0));
      expect(selectedRect.right, lessThanOrEqualTo(320));
      expect(
        find.byKey(const Key('app-context-navigation-many-items-previous')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('app-context-navigation-many-items-next')),
        findsOneWidget,
      );
      final previousButton = tester.widget<IconButton>(
        find.byKey(const Key('app-context-navigation-many-items-previous')),
      );
      expect(previousButton.onPressed, isNotNull);
      await tester.tap(
        find.byKey(const Key('app-context-navigation-many-items-previous')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('app-context-navigation-many-items-next')),
            )
            .onPressed,
        isNotNull,
      );

      selected = -1;
      await tester.pumpWidget(
        _wrap(
          AppContextNavigation(
            items: items.take(2).toList(growable: false),
            selectedIndex: 0,
            onSelected: (value) => selected = value,
            axis: Axis.horizontal,
            keyNamespace: 'keyboard-items',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(selected, 0);
    },
  );

  testWidgets('Workspace presentation primitives keep actions responsive', (
    WidgetTester tester,
  ) async {
    var resourceTapped = false;
    final detailTitle = 'Worker details';
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _wrap(
        ListView(
          children: [
            AppWorkspaceHeader(
              title: 'Web app',
              subtitle: 'Production deployment',
              status: const Text('Ready'),
              actions: [
                FilledButton(onPressed: () {}, child: const Text('Deploy')),
              ],
            ),
            const AppWorkspaceHeader(title: 'Overview'),
            AppWorkspaceToolbar(
              trailing: [
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: () {},
                  icon: const Icon(Icons.refresh),
                ),
              ],
              children: const [Text('Filter')],
            ),
            AppResourceRow(
              title: 'worker-default',
              subtitle: 'Queue worker',
              leading: const Icon(Icons.work_outline),
              status: const Text('Ready'),
              selected: true,
              onTap: () => resourceTapped = true,
              actions: [
                IconButton(
                  tooltip: 'Restart worker',
                  onPressed: () {},
                  icon: const Icon(Icons.restart_alt),
                ),
              ],
            ),
            const AppResourceRow(title: 'worker-secondary'),
            AppDetailPane(
              title: detailTitle,
              subtitle: 'Last checked now',
              actions: Text('Edit'),
              child: Text('Worker configuration'),
            ),
            const AppTechnicalDetails(child: Text('Collapsed detail')),
            const AppTechnicalDetails(
              title: 'Open details',
              subtitle: 'Available now',
              initiallyExpanded: true,
              child: Text('Expanded detail'),
            ),
            const AppDisclosureSection(
              icon: Icons.build_outlined,
              title: 'Maintenance tools',
              subtitle: 'Available for live apps',
              child: Text('Run maintenance command'),
            ),
          ],
        ),
      ),
    );

    expect(find.text('Production deployment'), findsOneWidget);
    expect(find.text('Deploy'), findsOneWidget);
    expect(find.text('Filter'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
    expect(find.byTooltip('Restart worker'), findsOneWidget);
    expect(find.text('Worker configuration'), findsOneWidget);
    expect(find.text('Available now'), findsOneWidget);
    expect(find.text('Expanded detail'), findsOneWidget);
    expect(find.byIcon(Icons.build_outlined), findsOneWidget);
    expect(find.text('Available for live apps'), findsOneWidget);
    expect(find.text('Run maintenance command'), findsNothing);
    await tester.tap(find.text('worker-default'));
    expect(resourceTapped, isTrue);
    expect(find.text('Collapsed detail'), findsNothing);
    await tester.tap(find.text('Technical details'));
    await tester.pumpAndSettle();
    expect(find.text('Collapsed detail'), findsOneWidget);
    await tester.tap(find.text('Maintenance tools'));
    await tester.pumpAndSettle();
    expect(find.text('Run maintenance command'), findsOneWidget);

    tester.view.physicalSize = const Size(500, 900);
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('Deploy')).dy,
      greaterThan(tester.getTopLeft(find.text('Web app')).dy),
    );
  });

  testWidgets('Context navigation refreshes item keys after data changes', (
    WidgetTester tester,
  ) async {
    var items = const [
      AppContextNavigationItem(
        id: 'one',
        label: 'One',
        icon: Icons.looks_one_outlined,
      ),
    ];
    late StateSetter update;
    await tester.pumpWidget(
      _wrap(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return AppContextNavigation(
              items: items,
              selectedIndex: 4,
              onSelected: (_) {},
              axis: Axis.horizontal,
              keyNamespace: items.length == 1 ? 'first' : 'second',
            );
          },
        ),
      ),
    );
    expect(find.byKey(const Key('first-nav-one')), findsOneWidget);

    update(() {
      items = const [
        AppContextNavigationItem(
          id: 'one',
          label: 'One',
          icon: Icons.looks_one_outlined,
        ),
        AppContextNavigationItem(
          id: 'two',
          label: 'Two',
          icon: Icons.looks_two_outlined,
        ),
      ];
    });
    await tester.pump();
    expect(find.byKey(const Key('second-nav-two')), findsOneWidget);
  });

  testWidgets('Review workflow section renders action before details', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppReviewWorkflowSection(
          summary: const Text('Current state'),
          primaryActionPanel: AppPrimaryActionPanel(
            currentState: 'Ready',
            primaryAction: FilledButton(
              key: const Key('workflow-primary-action'),
              onPressed: () {},
              child: const Text('Start'),
            ),
          ),
          details: const [
            ExpansionTile(
              key: Key('workflow-details'),
              title: Text('Technical details'),
              children: [Text('Hidden detail')],
            ),
          ],
        ),
      ),
    );

    expect(find.text('Current state'), findsOneWidget);
    expect(find.byKey(const Key('workflow-primary-action')), findsOneWidget);
    expect(find.byKey(const Key('workflow-details')), findsOneWidget);
    expect(find.text('Hidden detail'), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const Key('workflow-primary-action'))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('workflow-details'))).dy),
    );
  });

  testWidgets('Rail action button renders extended and collapsed modes', (
    WidgetTester tester,
  ) async {
    var tapCount = 0;
    await tester.pumpWidget(
      _wrap(
        Column(
          children: [
            AppRailActionButton(
              key: const Key('extended-action'),
              extended: true,
              icon: Icons.home_outlined,
              label: 'Home',
              onPressed: () => tapCount += 1,
            ),
            AppRailActionButton(
              key: const Key('collapsed-action'),
              extended: false,
              icon: Icons.settings_outlined,
              label: 'Settings',
              tooltip: 'Settings',
              selected: true,
              onPressed: () => tapCount += 1,
            ),
          ],
        ),
        brightness: Brightness.dark,
      ),
    );

    expect(find.widgetWithText(OutlinedButton, 'Home'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);

    await tester.tap(find.byKey(const Key('extended-action')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('collapsed-action')));
    await tester.pump();

    expect(tapCount, 2);
  });

  testWidgets('Collapsed rail action keeps at least a 44 pixel hit target', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AppRailActionButton(
          extended: false,
          icon: Icons.home_outlined,
          label: 'Home',
        ),
      ),
    );

    final hitTarget = tester.getSize(find.byType(IconButton));
    expect(hitTarget.width, greaterThanOrEqualTo(44));
    expect(hitTarget.height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dialog and state views render and confirm actions fire', (
    WidgetTester tester,
  ) async {
    var confirmCount = 0;
    var destructiveConfirmed = false;
    final textController = TextEditingController(text: 'postgres');
    final passwordController = TextEditingController(text: 'secret123');
    final numberController = TextEditingController(text: '5432');
    String? selectedValue = 'postgres';
    var toggleValue = true;
    var checkboxValue = false;
    final loadingLabel = 'Loading metrics';
    final destructiveTitle = 'Delete database';

    await tester.pumpWidget(
      _wrap(
        SingleChildScrollView(
          child: Column(
            children: [
              AppLoadingStateView(label: loadingLabel),
              const AppEmptyStateView(
                icon: Icons.inbox_outlined,
                title: 'Nothing here yet',
                message: 'Create something to get started.',
              ),
              Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () {
                      showDialog<bool>(
                        context: context,
                        builder: (_) => AppConfirmDialog(
                          title: 'Delete this server?',
                          description: 'This action cannot be undone.',
                          onConfirm: () => confirmCount += 1,
                          body: const Text('Type the server name to continue.'),
                        ),
                      );
                    },
                    child: const Text('Open dialog'),
                  );
                },
              ),
              Builder(
                builder: (context) {
                  return TextButton(
                    onPressed: () {
                      showDialog<bool>(
                        context: context,
                        builder: (_) => AppDestructiveConfirmDialog(
                          title: destructiveTitle,
                          description: 'This deletes the selected database.',
                        ),
                      ).then((value) {
                        destructiveConfirmed = value ?? false;
                      });
                    },
                    child: const Text('Open destructive dialog'),
                  );
                },
              ),
              AppFormDialog(
                title: 'Create database',
                description: 'Use the shared form shell.',
                actions: const [],
                child: Form(
                  child: Column(
                    children: [
                      AppFormSection(
                        title: 'Connection settings',
                        description:
                            'Use the shared section wrapper for grouped fields.',
                        children: [
                          AppTextFormField(
                            fieldKey: const Key('app-form-text'),
                            controller: textController,
                            labelText: 'Database name',
                            helperText: 'Use a short, memorable name.',
                            helperMaxLines: 2,
                            validator: (value) => value == null || value.isEmpty
                                ? 'Database name is required.'
                                : null,
                          ),
                          AppPasswordFormField(
                            fieldKey: const Key('app-form-password'),
                            controller: passwordController,
                            labelText: 'Password',
                          ),
                          AppNumberFormField(
                            fieldKey: const Key('app-form-number'),
                            controller: numberController,
                            labelText: 'Port',
                          ),
                          AppSelectFormField<String>(
                            fieldKey: const Key('app-form-select'),
                            labelText: 'Engine',
                            value: selectedValue,
                            items: const [
                              DropdownMenuItem(
                                value: 'postgres',
                                child: Text('PostgreSQL'),
                              ),
                            ],
                            onChanged: (value) {
                              selectedValue = value;
                            },
                          ),
                          AppToggleField(
                            fieldKey: const Key('app-form-toggle'),
                            value: toggleValue,
                            title: 'Compression',
                            onChanged: (value) {
                              toggleValue = value;
                            },
                          ),
                          AppCheckboxField(
                            value: checkboxValue,
                            title: 'I understand',
                            onChanged: (value) {
                              checkboxValue = value ?? false;
                            },
                          ),
                        ],
                      ),
                      const AppFormSection(children: []),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Loading metrics'), findsOneWidget);
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.text('Create something to get started.'), findsOneWidget);
    expect(find.text('Create database'), findsOneWidget);
    expect(find.text('Use the shared form shell.'), findsOneWidget);
    expect(find.text('Connection settings'), findsOneWidget);
    expect(
      find.text('Use the shared section wrapper for grouped fields.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextFormField, 'Database name'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Port'), findsOneWidget);
    expect(
      find.widgetWithText(DropdownButtonFormField<String>, 'Engine'),
      findsOneWidget,
    );
    expect(find.text('Compression'), findsOneWidget);
    expect(find.text('I understand'), findsOneWidget);
    expect(find.byKey(const Key('app-form-text')), findsOneWidget);
    expect(find.byKey(const Key('app-form-password')), findsOneWidget);
    expect(find.byKey(const Key('app-form-number')), findsOneWidget);
    expect(find.byKey(const Key('app-form-select')), findsOneWidget);
    expect(find.byKey(const Key('app-form-toggle')), findsOneWidget);
    expect(
      tester
          .widget<InputDecorator>(
            find.descendant(
              of: find.byKey(const Key('app-form-text')),
              matching: find.byType(InputDecorator),
            ),
          )
          .decoration
          .helperMaxLines,
      2,
    );

    await tester.tap(find.text('Open dialog'));
    await tester.pump();

    expect(find.text('Delete this server?'), findsOneWidget);
    expect(find.text('This action cannot be undone.'), findsOneWidget);
    expect(find.text('Type the server name to continue.'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(confirmCount, 0);

    await tester.tap(find.text('Open dialog'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(confirmCount, 1);

    await tester.tap(find.text('Open destructive dialog'));
    await tester.pump();
    expect(find.text('Delete database'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(destructiveConfirmed, isFalse);

    await tester.tap(find.text('Open destructive dialog'));
    await tester.pump();
    await tester.tap(find.text('Delete'));
    await tester.pump();
    expect(destructiveConfirmed, isTrue);

    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) {
            return TextButton(
              onPressed: () {
                showDialog<bool>(
                  context: context,
                  builder: (_) => const AppDestructiveConfirmDialog(
                    title: 'Delete server',
                    description: 'Disabled until you type the server name.',
                    confirmEnabled: false,
                    confirmButtonKey: Key('disabled-destructive-button'),
                  ),
                );
              },
              child: const Text('Open disabled destructive dialog'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open disabled destructive dialog'));
    await tester.pump();
    final disabledButton = tester.widget<FilledButton>(
      find.byKey(const Key('disabled-destructive-button')),
    );
    expect(disabledButton.onPressed, isNull);
  });

  testWidgets('Form dialog keeps actions visible while body scrolls', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        AppFormDialog(
          title: 'Long form',
          maxWidth: 460,
          actions: [
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            FilledButton(
              key: const Key('long-form-save'),
              onPressed: () {},
              child: const Text('Save'),
            ),
          ],
          child: Column(
            children: List.generate(
              30,
              (index) => AppTextFormField(
                fieldKey: Key('long-form-field-$index'),
                labelText: 'Field $index',
              ),
            ),
          ),
        ),
      ),
    );

    final saveFinder = find.byKey(const Key('long-form-save'));
    expect(saveFinder, findsOneWidget);
    final initialSaveTop = tester.getTopLeft(saveFinder).dy;

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();

    expect(saveFinder, findsOneWidget);
    expect(tester.getTopLeft(saveFinder).dy, initialSaveTop);
  });

  testWidgets('Password form field keeps its label and exposes reveal state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AppPasswordFormField(
          fieldKey: Key('shared-password-field'),
          labelText: 'Database password',
          helperText: 'Use the password saved for this database user.',
          helperMaxLines: 2,
        ),
      ),
    );

    EditableText field() => tester.widget<EditableText>(
      find.descendant(
        of: find.byKey(const Key('shared-password-field')),
        matching: find.byType(EditableText),
      ),
    );

    expect(field().obscureText, isTrue);
    expect(find.text('Database password'), findsOneWidget);
    expect(find.byTooltip('Show password'), findsOneWidget);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();

    expect(field().obscureText, isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(find.text('Database password'), findsOneWidget);
  });

  testWidgets('Empty state renders its action below the message', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        const AppEmptyStateView(
          icon: Icons.dns_outlined,
          title: 'No servers yet',
          message: 'Connect a server to get started.',
          action: Text('Connect a server', key: Key('empty-state-action')),
        ),
      ),
    );

    expect(find.byKey(const Key('empty-state-action')), findsOneWidget);
    final messageBottom = tester
        .getBottomLeft(find.text('Connect a server to get started.'))
        .dy;
    final actionTop = tester
        .getTopLeft(find.byKey(const Key('empty-state-action')))
        .dy;
    expect(actionTop, greaterThan(messageBottom));
  });

  testWidgets('showAppNotice shows title and message and pops on OK', (
    WidgetTester tester,
  ) async {
    // D-43 (T-013): the single-OK notice owner — also covers its lines for
    // the ui_system gate, which requires app_dialogs.dart at 100%.
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => showAppNotice(
                context,
                title: 'Notice title',
                message: 'Notice message.',
              ),
              child: const Text('Open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(find.text('Notice title'), findsOneWidget);
    expect(find.text('Notice message.'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'OK'));
    await tester.pump();
    expect(find.text('Notice title'), findsNothing);
  });

  testWidgets('showAppNotice carries the OK button key when given', (
    WidgetTester tester,
  ) async {
    // D-43 (T-013): the scheduler's E2E-addressed OK key survives routing.
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => showAppNotice(
                context,
                title: 'Notice title',
                message: 'Notice message.',
                okButtonKey: const Key('notice-ok-button'),
              ),
              child: const Text('Open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('notice-ok-button')));
    await tester.pump();
    expect(find.text('Notice title'), findsNothing);
  });
}
