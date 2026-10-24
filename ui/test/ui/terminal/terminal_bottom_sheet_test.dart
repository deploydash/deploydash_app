import 'dart:async';

import 'package:ui/services/concurrency_engine.dart';
import 'package:ui/ui/terminal/terminal_bottom_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('TerminalBottomSheet is minimized by default', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              TerminalBottomSheet(initialHeight: 180),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('terminal-sheet')), findsOneWidget);
    expect(find.byKey(const Key('terminal-selectable-output')), findsNothing);
    expect(find.text('Advanced activity'), findsOneWidget);
  });

  testWidgets('TerminalBottomSheet accepts stream output', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 180,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    controller.add(const TerminalStreamEntry('[deploy] build started'));
    await tester.pumpAndSettle();

    final outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    expect(outputWidget.data, contains('build started'));
  });

  testWidgets('Minimized terminal shows latest output line', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 180,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    controller.add(
      const TerminalStreamEntry('[verify] Connecting to 10.0.0.1:22 as ubuntu'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('terminal-collapsed-latest-output')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Connecting to 10.0.0.1:22 as ubuntu'),
      findsOneWidget,
    );
  });

  testWidgets(
    'Minimized terminal keeps technical details out of its latest summary',
    (WidgetTester tester) async {
      final controller = StreamController<TerminalStreamEntry>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox()),
                TerminalBottomSheet(
                  initialHeight: 180,
                  outputStream: controller.stream,
                  showDetails: true,
                ),
              ],
            ),
          ),
        ),
      );

      controller.add(const TerminalStreamEntry('Service status refreshed.'));
      controller.add(
        const TerminalStreamEntry(
          "Runtime operation 'status' prepared.",
          isDetail: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('terminal-collapsed-latest-output')),
        findsOneWidget,
      );
      expect(find.textContaining('Service status refreshed.'), findsOneWidget);
      expect(
        find.textContaining("Runtime operation 'status' prepared."),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('terminal-minimize-button')));
      await tester.pumpAndSettle();
      final outputWidget = tester.widget<SelectableText>(
        find.byKey(const Key('terminal-selectable-output')),
      );
      expect(
        outputWidget.data,
        contains("Runtime operation 'status' prepared."),
      );
    },
  );

  testWidgets('Minimized terminal shows spinner while task is running', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              TerminalBottomSheet(initialHeight: 180, isTaskRunning: true),
            ],
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('terminal-collapsed-running-indicator')),
      findsOneWidget,
    );
  });

  testWidgets('Terminal details toggle hides and shows detail lines', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 180,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    controller.add(const TerminalStreamEntry('Queued: Setup'));
    controller.add(
      const TerminalStreamEntry(
        'System update & patching | Hit:1 archive',
        isDetail: true,
      ),
    );
    await tester.pumpAndSettle();

    SelectableText outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    expect(outputWidget.data, contains('Queued: Setup'));
    expect(outputWidget.data, isNot(contains('Hit:1 archive')));

    await tester.tap(find.byKey(const Key('terminal-details-toggle')));
    await tester.pumpAndSettle();

    outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    expect(outputWidget.data, contains('Hit:1 archive'));
  });

  testWidgets('TerminalBottomSheet copy button copies output', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    final copiedPayloads = <Object?>[];
    addTearDown(controller.close);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedPayloads.add(call.arguments);
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 180,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    controller.add(
      const TerminalStreamEntry('[2026-02-10 10:11:12] Step 1/3: Connect'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('terminal-copy-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      copiedPayloads,
      contains(containsPair('text', contains('Step 1/3: Connect'))),
    );
    expect(find.text('Activity copied'), findsOneWidget);
  });

  testWidgets('TerminalBottomSheet clear button clears visible output', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 180,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    controller.add(const TerminalStreamEntry('line 1'));
    await tester.pumpAndSettle();
    SelectableText outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    expect(outputWidget.data, contains('line 1'));

    await tester.tap(find.byKey(const Key('terminal-clear-button')));
    await tester.pumpAndSettle();
    outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    expect(outputWidget.data, isNot(contains('line 1')));
    expect(outputWidget.data, contains('No activity yet.'));
    expect(
      find.textContaining('Latest activity: Activity cleared.'),
      findsOneWidget,
    );
  });

  testWidgets('TerminalBottomSheet removes modal selection button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              TerminalBottomSheet(initialHeight: 180),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-selection-button')), findsNothing);
    expect(find.byKey(const Key('terminal-selectable-output')), findsOneWidget);
  });

  testWidgets('TerminalBottomSheet resizes when dragged', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              TerminalBottomSheet(initialHeight: 180),
            ],
          ),
        ),
      ),
    );

    final sheetFinder = find.byKey(const Key('terminal-sheet'));
    final minimizeButton = find.byKey(const Key('terminal-minimize-button'));

    await tester.tap(minimizeButton);
    await tester.pumpAndSettle();

    final handleFinder = find.byKey(const Key('terminal-resize-handle'));
    final initialHeight = tester.getSize(sheetFinder).height;
    await tester.drag(handleFinder, const Offset(0, -60));
    await tester.pumpAndSettle();
    final resizedHeight = tester.getSize(sheetFinder).height;

    expect(resizedHeight, greaterThan(initialHeight));
  });

  testWidgets('TerminalBottomSheet can minimize and restore', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              TerminalBottomSheet(initialHeight: 180),
            ],
          ),
        ),
      ),
    );

    final sheetFinder = find.byKey(const Key('terminal-sheet'));
    final minimizeButton = find.byKey(const Key('terminal-minimize-button'));

    expect(find.byKey(const Key('terminal-selectable-output')), findsNothing);

    await tester.tap(minimizeButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-selectable-output')), findsOneWidget);
    expect(tester.getSize(sheetFinder).height, closeTo(180, 0.01));
    expect(find.text('Advanced activity'), findsOneWidget);

    await tester.tap(minimizeButton);
    await tester.pumpAndSettle();

    expect(tester.getSize(sheetFinder).height, closeTo(40, 0.01));
    expect(find.byKey(const Key('terminal-selectable-output')), findsNothing);
  });

  testWidgets('TerminalBottomSheet can maximize', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              TerminalBottomSheet(initialHeight: 180, maxHeight: 320),
            ],
          ),
        ),
      ),
    );

    final sheetFinder = find.byKey(const Key('terminal-sheet'));
    final maximizeButton = find.byKey(const Key('terminal-maximize-button'));
    const initialExpandedHeight = 180.0;

    await tester.tap(maximizeButton);
    await tester.pumpAndSettle();

    expect(tester.getSize(sheetFinder).height, closeTo(320, 0.01));
    expect(find.byKey(const Key('terminal-selectable-output')), findsOneWidget);

    await tester.tap(maximizeButton);
    await tester.pumpAndSettle();

    expect(
      tester.getSize(sheetFinder).height,
      closeTo(initialExpandedHeight, 0.01),
    );
  });

  testWidgets('Maximize and restore keep terminal pinned to bottom', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 220,
                maxHeight: 360,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    for (int i = 0; i < 180; i += 1) {
      controller.add(TerminalStreamEntry('maximize line $i'));
    }
    await tester.pumpAndSettle();
    _expectAtBottom(_terminalScrollController(tester));

    await tester.tap(find.byKey(const Key('terminal-maximize-button')));
    await tester.pumpAndSettle();
    _expectAtBottom(_terminalScrollController(tester));

    await tester.tap(find.byKey(const Key('terminal-maximize-button')));
    await tester.pumpAndSettle();
    _expectAtBottom(_terminalScrollController(tester));
  });

  testWidgets('expandForTask opens the terminal and follows latest output', (
    WidgetTester tester,
  ) async {
    final outputController = StreamController<TerminalStreamEntry>.broadcast();
    final harnessKey = GlobalKey<_TerminalHarnessState>();
    addTearDown(outputController.close);

    await tester.pumpWidget(
      MaterialApp(
        home: _TerminalHarness(
          key: harnessKey,
          outputStream: outputController.stream,
        ),
      ),
    );

    for (int i = 0; i < 80; i += 1) {
      outputController.add(TerminalStreamEntry('pre-open line $i'));
    }
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-selectable-output')), findsNothing);

    harnessKey.currentState!.setExpandForTask(true);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-selectable-output')), findsOneWidget);
    _expectAtBottom(_terminalScrollController(tester));

    outputController.add(
      const TerminalStreamEntry('line after task expansion'),
    );
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));
    final outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    expect(outputWidget.data, contains('line after task expansion'));
  });

  testWidgets('parent showDetails update preserves terminal follow state', (
    WidgetTester tester,
  ) async {
    final outputController = StreamController<TerminalStreamEntry>.broadcast();
    final harnessKey = GlobalKey<_TerminalHarnessState>();
    addTearDown(outputController.close);

    await tester.pumpWidget(
      MaterialApp(
        home: _TerminalHarness(
          key: harnessKey,
          outputStream: outputController.stream,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    for (int i = 0; i < 120; i += 1) {
      outputController.add(TerminalStreamEntry('parent visible $i'));
      outputController.add(
        TerminalStreamEntry('parent detail $i', isDetail: true),
      );
    }
    await tester.pumpAndSettle();
    _expectAtBottom(_terminalScrollController(tester));

    final outputScrollView = find.byKey(
      const Key('terminal-output-scroll-view'),
    );
    await tester.drag(outputScrollView, const Offset(0, 220));
    await tester.pumpAndSettle();

    final scrollController = _terminalScrollController(tester);
    harnessKey.currentState!.setShowDetails(true);
    await tester.pumpAndSettle();

    expect(
      scrollController.offset,
      lessThan(scrollController.position.maxScrollExtent - 1),
    );

    outputController.add(
      const TerminalStreamEntry('after parent detail update'),
    );
    await tester.pumpAndSettle();

    expect(
      scrollController.offset,
      lessThan(scrollController.position.maxScrollExtent - 1),
    );
  });

  testWidgets('Expanded terminal uses sticky-bottom auto-scroll', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 180,
                maxHeight: 320,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    for (int i = 0; i < 200; i += 1) {
      controller.add(TerminalStreamEntry('line $i'));
    }
    await tester.pumpAndSettle();

    final outputScrollView = find.byKey(
      const Key('terminal-output-scroll-view'),
    );
    final outputScrollWidget = tester.widget<SingleChildScrollView>(
      outputScrollView,
    );
    final scrollController = outputScrollWidget.controller!;
    expect(scrollController.hasClients, isTrue);

    expect(
      scrollController.offset,
      closeTo(scrollController.position.maxScrollExtent, 1.0),
    );

    await tester.drag(outputScrollView, const Offset(0, 220));
    await tester.pumpAndSettle();

    final beforeFollowCheck = scrollController.offset;
    controller.add(const TerminalStreamEntry('line after manual scroll up'));
    await tester.pumpAndSettle();

    expect(
      scrollController.offset,
      lessThan(scrollController.position.maxScrollExtent - 1),
    );
    expect((scrollController.offset - beforeFollowCheck).abs(), lessThan(2));

    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pump();

    controller.add(const TerminalStreamEntry('line while at bottom'));
    await tester.pumpAndSettle();

    expect(
      scrollController.offset,
      closeTo(scrollController.position.maxScrollExtent, 1.0),
    );

    for (int i = 0; i < 75; i += 1) {
      controller.add(TerminalStreamEntry('burst line $i'));
    }
    await tester.pumpAndSettle();

    expect(
      scrollController.offset,
      closeTo(scrollController.position.maxScrollExtent, 1.0),
    );
  });

  testWidgets('Queue tab does not disturb terminal follow-bottom state', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 220,
                maxHeight: 320,
                outputStream: controller.stream,
                initialQueueSnapshot: List<OperationQueueSnapshot>.generate(
                  40,
                  _queueSnapshot,
                  growable: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    for (int i = 0; i < 180; i += 1) {
      controller.add(TerminalStreamEntry('terminal line $i'));
    }
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));

    await tester.tap(find.byKey(const Key('queue-tab-button')));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const Key('terminal-queue-list')),
      const Offset(0, -300),
    );
    await tester.pumpAndSettle();

    controller.add(const TerminalStreamEntry('terminal line while queue open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('terminal-tab-button')));
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));
    final outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    expect(outputWidget.data, contains('terminal line while queue open'));
  });

  testWidgets('Queue tab preserves manual terminal scroll-up state', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 220,
                maxHeight: 320,
                outputStream: controller.stream,
                initialQueueSnapshot: List<OperationQueueSnapshot>.generate(
                  40,
                  _queueSnapshot,
                  growable: false,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    for (int i = 0; i < 180; i += 1) {
      controller.add(TerminalStreamEntry('manual queue line $i'));
    }
    await tester.pumpAndSettle();

    final outputScrollView = find.byKey(
      const Key('terminal-output-scroll-view'),
    );
    await tester.drag(outputScrollView, const Offset(0, 220));
    await tester.pumpAndSettle();

    final scrollController = _terminalScrollController(tester);

    await tester.tap(find.byKey(const Key('queue-tab-button')));
    await tester.pumpAndSettle();
    controller.add(const TerminalStreamEntry('output while manually scrolled'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('terminal-tab-button')));
    await tester.pumpAndSettle();

    expect(
      scrollController.offset,
      lessThan(scrollController.position.maxScrollExtent - 1),
    );
  });

  testWidgets('Terminal switches output streams without losing follow state', (
    WidgetTester tester,
  ) async {
    final firstController = StreamController<TerminalStreamEntry>.broadcast();
    final secondController = StreamController<TerminalStreamEntry>.broadcast();
    final harnessKey = GlobalKey<_TerminalHarnessState>();
    addTearDown(firstController.close);
    addTearDown(secondController.close);

    await tester.pumpWidget(
      MaterialApp(
        home: _TerminalHarness(
          key: harnessKey,
          outputStream: firstController.stream,
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    for (int i = 0; i < 100; i += 1) {
      firstController.add(TerminalStreamEntry('first stream line $i'));
    }
    await tester.pumpAndSettle();
    _expectAtBottom(_terminalScrollController(tester));

    harnessKey.currentState!.setOutputStream(secondController.stream);
    await tester.pumpAndSettle();
    secondController.add(const TerminalStreamEntry('second stream line'));
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));
    final outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    expect(outputWidget.data, contains('first stream line 99'));
    expect(outputWidget.data, contains('second stream line'));
  });

  testWidgets('Terminal trims blank output and caps retained history', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 220,
                maxHeight: 320,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    controller.add(const TerminalStreamEntry('    '));
    for (int i = 0; i < 5005; i += 1) {
      controller.add(TerminalStreamEntry('retained line $i'));
    }
    await tester.pumpAndSettle();

    final outputWidget = tester.widget<SelectableText>(
      find.byKey(const Key('terminal-selectable-output')),
    );
    final retainedLines = outputWidget.data!.split('\n');
    expect(retainedLines, isNot(contains('retained line 0')));
    expect(retainedLines, isNot(contains('retained line 4')));
    expect(retainedLines, contains('retained line 5'));
    expect(retainedLines, contains('retained line 5004'));
    expect(retainedLines, isNot(contains('    ')));
    _expectAtBottom(_terminalScrollController(tester));
  });

  testWidgets('Terminal resize preserves follow-bottom state', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 260,
                minHeight: 160,
                maxHeight: 360,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    for (int i = 0; i < 200; i += 1) {
      controller.add(TerminalStreamEntry('resize line $i'));
    }
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));

    await tester.drag(
      find.byKey(const Key('terminal-resize-handle')),
      const Offset(0, 70),
    );
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));

    final outputScrollView = find.byKey(
      const Key('terminal-output-scroll-view'),
    );
    await tester.drag(outputScrollView, const Offset(0, 220));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('terminal-resize-handle')),
      const Offset(0, 20),
    );
    await tester.pumpAndSettle();

    final scrollController = _terminalScrollController(tester);
    expect(
      scrollController.offset,
      lessThan(scrollController.position.maxScrollExtent - 1),
    );
  });

  testWidgets('Details toggle preserves terminal follow-bottom state', (
    WidgetTester tester,
  ) async {
    final controller = StreamController<TerminalStreamEntry>.broadcast();
    addTearDown(controller.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 220,
                maxHeight: 320,
                outputStream: controller.stream,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    for (int i = 0; i < 120; i += 1) {
      controller.add(TerminalStreamEntry('visible line $i'));
      controller.add(TerminalStreamEntry('detail line $i', isDetail: true));
    }
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));

    await tester.tap(find.byKey(const Key('terminal-details-toggle')));
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));

    await tester.tap(find.byKey(const Key('terminal-details-toggle')));
    await tester.pumpAndSettle();

    _expectAtBottom(_terminalScrollController(tester));

    final outputScrollView = find.byKey(
      const Key('terminal-output-scroll-view'),
    );
    await tester.drag(outputScrollView, const Offset(0, 220));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('terminal-details-toggle')));
    await tester.pumpAndSettle();

    final scrollController = _terminalScrollController(tester);
    expect(
      scrollController.offset,
      lessThan(scrollController.position.maxScrollExtent - 1),
    );
  });

  testWidgets('TerminalBottomSheet resize handle shows resize cursor', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox()),
              TerminalBottomSheet(initialHeight: 180),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();

    final region = tester.widget<MouseRegion>(
      find.byKey(const Key('terminal-resize-handle-cursor')),
    );
    expect(region.cursor, SystemMouseCursors.resizeUpDown);
  });

  testWidgets('Queue tab shows queue data and summary', (
    WidgetTester tester,
  ) async {
    final queueController =
        StreamController<List<OperationQueueSnapshot>>.broadcast();
    final metricsController =
        StreamController<OperationSchedulerMetricsSnapshot>.broadcast();
    addTearDown(queueController.close);
    addTearDown(metricsController.close);

    final initialQueue = <OperationQueueSnapshot>[
      OperationQueueSnapshot(
        operationInstanceId: 'op-1',
        operationType: 'run_workflow',
        state: OperationQueueState.queued,
        submittedAt: DateTime.utc(2026, 1, 1, 12, 0, 0),
        queuePosition: 0,
        hostKey: '192.168.1.10',
        claims: const <OperationResourceClaim>[],
        metadata: const <String, dynamic>{},
        message: 'Operation queued by scheduler.',
      ),
    ];

    final initialMetrics = OperationSchedulerMetricsSnapshot(
      submitted: 1,
      accepted: 0,
      queued: 1,
      rejected: 0,
      deduped: 0,
      running: 0,
      cancelling: 0,
      completedSuccess: 0,
      completedFailure: 0,
      completedCancelled: 0,
      averageWaitMs: 0,
      averageRunMs: 0,
      averageCancelMs: 0,
      queueDepth: 1,
      stale: 0,
      oldestQueueWaitMs: 0,
      queueDepthWarning: false,
      queueWaitWarning: false,
      queueOrdering: OperationQueueOrdering.fifo.name,
      preemptionMode: OperationPreemptionMode.none.name,
      failureByOperationType: const <String, int>{},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 200,
                queueStream: queueController.stream,
                queueMetricsStream: metricsController.stream,
                initialQueueSnapshot: initialQueue,
                initialQueueMetrics: initialMetrics,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('queue-tab-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-queue-list')), findsOneWidget);
    expect(find.textContaining('run_workflow'), findsOneWidget);
    expect(find.textContaining('Queue position: 0'), findsOneWidget);
    expect(find.textContaining('Background work: 1 queued'), findsOneWidget);

    queueController.add(<OperationQueueSnapshot>[
      OperationQueueSnapshot(
        operationInstanceId: 'op-2',
        operationType: 'deploy',
        state: OperationQueueState.running,
        submittedAt: DateTime.utc(2026, 1, 1, 12, 1),
        startedAt: DateTime.utc(2026, 1, 1, 12, 2),
        queuePosition: null,
        hostKey: null,
        claims: const <OperationResourceClaim>[],
        metadata: const <String, dynamic>{},
        message: 'Deployment is running.',
      ),
    ]);
    metricsController.add(_metricsSnapshot(submitted: 2, running: 1));
    await tester.pumpAndSettle();

    expect(find.textContaining('deploy'), findsOneWidget);
    expect(find.textContaining('Running'), findsOneWidget);
    expect(find.textContaining('Host: global'), findsOneWidget);
    expect(find.textContaining('Background work: 0 queued'), findsOneWidget);
  });

  testWidgets('Initial queue props update when streams are absent', (
    WidgetTester tester,
  ) async {
    final harnessKey = GlobalKey<_TerminalHarnessState>();

    await tester.pumpWidget(
      MaterialApp(home: _TerminalHarness(key: harnessKey)),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('queue-tab-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-queue-empty')), findsOneWidget);

    harnessKey.currentState!.setInitialQueue(<OperationQueueSnapshot>[
      _queueSnapshot(7),
    ], _metricsSnapshot(submitted: 1, queued: 1, queueDepth: 1));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-queue-empty')), findsNothing);
    expect(
      find.textContaining('Operation queued by scheduler 7.'),
      findsOneWidget,
    );
    expect(find.textContaining('Background work: 1 queued'), findsOneWidget);

    harnessKey.currentState!.setInitialQueue(
      const <OperationQueueSnapshot>[],
      null,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-queue-empty')), findsOneWidget);
    expect(find.textContaining('Background work: 0 queued'), findsOneWidget);
  });

  testWidgets('Queue stream and metrics stream can be replaced', (
    WidgetTester tester,
  ) async {
    final firstQueueController =
        StreamController<List<OperationQueueSnapshot>>.broadcast();
    final secondQueueController =
        StreamController<List<OperationQueueSnapshot>>.broadcast();
    final firstMetricsController =
        StreamController<OperationSchedulerMetricsSnapshot>.broadcast();
    final secondMetricsController =
        StreamController<OperationSchedulerMetricsSnapshot>.broadcast();
    final harnessKey = GlobalKey<_TerminalHarnessState>();
    addTearDown(firstQueueController.close);
    addTearDown(secondQueueController.close);
    addTearDown(firstMetricsController.close);
    addTearDown(secondMetricsController.close);

    await tester.pumpWidget(
      MaterialApp(home: _TerminalHarness(key: harnessKey)),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('queue-tab-button')));
    await tester.pumpAndSettle();

    harnessKey.currentState!.setQueueStreams(
      queueStream: firstQueueController.stream,
      metricsStream: firstMetricsController.stream,
    );
    await tester.pumpAndSettle();

    firstQueueController.add(<OperationQueueSnapshot>[_queueSnapshot(1)]);
    firstMetricsController.add(
      _metricsSnapshot(submitted: 1, queued: 1, queueDepth: 1),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Operation queued by scheduler 1.'),
      findsOneWidget,
    );

    harnessKey.currentState!.setQueueStreams(
      queueStream: secondQueueController.stream,
      metricsStream: secondMetricsController.stream,
    );
    await tester.pumpAndSettle();

    firstQueueController.add(<OperationQueueSnapshot>[_queueSnapshot(2)]);
    firstMetricsController.add(
      _metricsSnapshot(submitted: 2, queued: 2, queueDepth: 2),
    );
    secondQueueController.add(<OperationQueueSnapshot>[_queueSnapshot(3)]);
    secondMetricsController.add(
      _metricsSnapshot(submitted: 3, queued: 3, queueDepth: 3),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Operation queued by scheduler 1.'),
      findsNothing,
    );
    expect(
      find.textContaining('Operation queued by scheduler 2.'),
      findsNothing,
    );
    expect(
      find.textContaining('Operation queued by scheduler 3.'),
      findsOneWidget,
    );
    expect(find.textContaining('Background work: 3 queued'), findsOneWidget);
  });

  testWidgets('Queue tab renders all queue states and stale diagnostics', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final entries = <OperationQueueSnapshot>[
      _queueStateSnapshot(0, OperationQueueState.dispatching),
      _queueStateSnapshot(1, OperationQueueState.cancelling),
      _queueStateSnapshot(
        2,
        OperationQueueState.succeeded,
        completedAt: DateTime.utc(2026, 1, 1, 12, 8),
      ),
      _queueStateSnapshot(3, OperationQueueState.failed),
      _queueStateSnapshot(4, OperationQueueState.cancelled),
      _queueStateSnapshot(5, OperationQueueState.rejected),
      _queueStateSnapshot(
        6,
        OperationQueueState.deduped,
        isStale: true,
        blockingResources: const <String>['server:ssh', 'app:deploy'],
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 820,
                maxHeight: 820,
                initialQueueSnapshot: entries,
                initialQueueMetrics: _metricsSnapshot(
                  submitted: entries.length,
                  stale: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('queue-tab-button')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dispatching'), findsOneWidget);
    expect(find.textContaining('Cancelling'), findsOneWidget);
    expect(find.textContaining('Succeeded'), findsOneWidget);
    expect(find.textContaining('Failed'), findsOneWidget);
    expect(find.textContaining('Cancelled'), findsOneWidget);
    expect(find.textContaining('Rejected'), findsOneWidget);
    expect(find.textContaining('Deduped'), findsOneWidget);
    expect(find.textContaining('Stale operation detected.'), findsOneWidget);
    expect(
      find.textContaining('Blocked resources: server:ssh, app:deploy'),
      findsOneWidget,
    );
  });

  testWidgets('Queue tab hides terminal-only controls and shows warning', (
    WidgetTester tester,
  ) async {
    final initialMetrics = OperationSchedulerMetricsSnapshot(
      submitted: 4,
      accepted: 0,
      queued: 4,
      rejected: 0,
      deduped: 0,
      running: 1,
      cancelling: 0,
      completedSuccess: 0,
      completedFailure: 2,
      completedCancelled: 0,
      averageWaitMs: 0,
      averageRunMs: 0,
      averageCancelMs: 0,
      queueDepth: 4,
      stale: 1,
      oldestQueueWaitMs: 120000,
      queueDepthWarning: true,
      queueWaitWarning: true,
      queueOrdering: OperationQueueOrdering.fifo.name,
      preemptionMode: OperationPreemptionMode.none.name,
      failureByOperationType: const <String, int>{},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              TerminalBottomSheet(
                initialHeight: 200,
                initialQueueMetrics: initialMetrics,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('terminal-minimize-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('queue-tab-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('terminal-details-toggle')), findsNothing);
    expect(find.byKey(const Key('terminal-copy-button')), findsNothing);
    expect(find.byKey(const Key('terminal-clear-button')), findsNothing);
    expect(find.byKey(const Key('terminal-queue-warning')), findsOneWidget);
  });
}

class _TerminalHarness extends StatefulWidget {
  const _TerminalHarness({super.key, this.outputStream});

  final Stream<TerminalStreamEntry>? outputStream;

  @override
  State<_TerminalHarness> createState() => _TerminalHarnessState();
}

class _TerminalHarnessState extends State<_TerminalHarness> {
  Stream<TerminalStreamEntry>? _outputStream;
  Stream<List<OperationQueueSnapshot>>? _queueStream;
  Stream<OperationSchedulerMetricsSnapshot>? _metricsStream;
  bool _showDetails = false;
  bool _expandForTask = false;
  List<OperationQueueSnapshot> _initialQueueSnapshot =
      const <OperationQueueSnapshot>[];
  OperationSchedulerMetricsSnapshot? _initialQueueMetrics;

  @override
  void initState() {
    super.initState();
    _outputStream = widget.outputStream;
  }

  void setOutputStream(Stream<TerminalStreamEntry>? stream) {
    setState(() => _outputStream = stream);
  }

  void setQueueStreams({
    Stream<List<OperationQueueSnapshot>>? queueStream,
    Stream<OperationSchedulerMetricsSnapshot>? metricsStream,
  }) {
    setState(() {
      _queueStream = queueStream;
      _metricsStream = metricsStream;
    });
  }

  void setShowDetails(bool value) {
    setState(() => _showDetails = value);
  }

  void setExpandForTask(bool value) {
    setState(() => _expandForTask = value);
  }

  void setInitialQueue(
    List<OperationQueueSnapshot> queue,
    OperationSchedulerMetricsSnapshot? metrics,
  ) {
    setState(() {
      _initialQueueSnapshot = queue;
      _initialQueueMetrics = metrics;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const Expanded(child: SizedBox()),
          TerminalBottomSheet(
            initialHeight: 220,
            maxHeight: 360,
            outputStream: _outputStream,
            queueStream: _queueStream,
            queueMetricsStream: _metricsStream,
            showDetails: _showDetails,
            expandForTask: _expandForTask,
            initialQueueSnapshot: _initialQueueSnapshot,
            initialQueueMetrics: _initialQueueMetrics,
          ),
        ],
      ),
    );
  }
}

ScrollController _terminalScrollController(WidgetTester tester) {
  final outputScrollWidget = tester.widget<SingleChildScrollView>(
    find.byKey(const Key('terminal-output-scroll-view')),
  );
  final controller = outputScrollWidget.controller;
  expect(controller, isNotNull);
  expect(controller!.hasClients, isTrue);
  return controller;
}

void _expectAtBottom(ScrollController controller) {
  expect(controller.offset, closeTo(controller.position.maxScrollExtent, 1.0));
}

OperationQueueSnapshot _queueSnapshot(int index) {
  return OperationQueueSnapshot(
    operationInstanceId: 'op-$index',
    operationType: 'run_workflow',
    state: OperationQueueState.queued,
    submittedAt: DateTime.utc(2026, 1, 1, 12, index),
    queuePosition: index,
    hostKey: '192.168.1.10',
    claims: const <OperationResourceClaim>[],
    metadata: const <String, dynamic>{},
    message: 'Operation queued by scheduler $index.',
  );
}

OperationQueueSnapshot _queueStateSnapshot(
  int index,
  OperationQueueState state, {
  DateTime? completedAt,
  List<String> blockingResources = const <String>[],
  bool isStale = false,
}) {
  return OperationQueueSnapshot(
    operationInstanceId: 'state-op-$index',
    operationType: 'operation_$index',
    state: state,
    submittedAt: DateTime.utc(2026, 1, 1, 12, index),
    startedAt: DateTime.utc(2026, 1, 1, 12, index + 1),
    completedAt: completedAt,
    queuePosition: null,
    hostKey: index.isEven ? 'server-$index' : '',
    claims: const <OperationResourceClaim>[],
    metadata: const <String, dynamic>{},
    message: 'State message $index.',
    blockingResources: blockingResources,
    isStale: isStale,
  );
}

OperationSchedulerMetricsSnapshot _metricsSnapshot({
  int submitted = 0,
  int accepted = 0,
  int queued = 0,
  int rejected = 0,
  int deduped = 0,
  int running = 0,
  int cancelling = 0,
  int completedSuccess = 0,
  int completedFailure = 0,
  int completedCancelled = 0,
  int averageWaitMs = 0,
  int averageRunMs = 0,
  int averageCancelMs = 0,
  int queueDepth = 0,
  int stale = 0,
  int oldestQueueWaitMs = 0,
  bool queueDepthWarning = false,
  bool queueWaitWarning = false,
  String queueOrdering = 'fifo',
  String preemptionMode = 'none',
  Map<String, int> failureByOperationType = const <String, int>{},
}) {
  return OperationSchedulerMetricsSnapshot(
    submitted: submitted,
    accepted: accepted,
    queued: queued,
    rejected: rejected,
    deduped: deduped,
    running: running,
    cancelling: cancelling,
    completedSuccess: completedSuccess,
    completedFailure: completedFailure,
    completedCancelled: completedCancelled,
    averageWaitMs: averageWaitMs,
    averageRunMs: averageRunMs,
    averageCancelMs: averageCancelMs,
    queueDepth: queueDepth,
    stale: stale,
    oldestQueueWaitMs: oldestQueueWaitMs,
    queueDepthWarning: queueDepthWarning,
    queueWaitWarning: queueWaitWarning,
    queueOrdering: queueOrdering,
    preemptionMode: preemptionMode,
    failureByOperationType: failureByOperationType,
  );
}
