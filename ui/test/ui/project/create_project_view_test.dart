import 'package:ui/ui/project/create_project_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CreateProjectView uses a focused flow with fixed actions', (
    WidgetTester tester,
  ) async {
    var cancelled = false;
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CreateProjectView(onCancel: () => cancelled = true),
        ),
      ),
    );

    expect(
      find.byKey(const Key('create-project-focused-flow')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('create-project-submit-button')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('create-project-cancel-button')));
    expect(cancelled, isTrue);
  });

  testWidgets('CreateProjectView validates required project name', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CreateProjectView())),
    );

    await tester.tap(find.byKey(const Key('create-project-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Project name is required'), findsOneWidget);
    expect(find.text('Runtime is required'), findsOneWidget);
  });

  testWidgets('CreateProjectView submits valid payload', (
    WidgetTester tester,
  ) async {
    CreateProjectRequest? capturedRequest;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CreateProjectView(
            onCreate: (request) => capturedRequest = request,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('create-project-name-field')),
      'Worker App',
    );
    await tester.tap(find.byKey(const Key('create-project-runtime-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Python').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create-project-submit-button')));
    await tester.pumpAndSettle();

    expect(capturedRequest, isNotNull);
    expect(capturedRequest?.name, 'Worker App');
    expect(capturedRequest?.type, 'Web app');
    expect(capturedRequest?.gitUrl, '');
    expect(capturedRequest?.primaryDomain, 'Not configured');
    expect(capturedRequest?.railpackRuntimeId, 'python');
    expect(capturedRequest?.railpackProvider, 'python');
    expect(capturedRequest?.railpackBuildCommand, isEmpty);
    expect(capturedRequest?.railpackRunCommand, isEmpty);
    expect(capturedRequest?.appPort, 8000);
  });

  testWidgets('CreateProjectView shows generic auto-detect helper text', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: CreateProjectView())),
    );

    await tester.tap(find.byKey(const Key('create-project-runtime-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('.NET').last);
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Leave commands blank to enable auto detection of .NET project and startup command.',
      ),
      findsOneWidget,
    );
  });
}
