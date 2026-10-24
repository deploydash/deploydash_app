import 'dart:async';

import 'package:ui/data/local/server_repository.dart';
import 'package:ui/providers/project_provider.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:ui/ui/project/project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _testProjectProvider = NotifierProvider<_TestProjectNotifier, Project?>(
  _TestProjectNotifier.new,
);
final _testServerProvider = NotifierProvider<_TestServerNotifier, Server?>(
  _TestServerNotifier.new,
);

class _TestProjectNotifier extends Notifier<Project?> {
  @override
  Project? build() => null;

  void set(Project? project) {
    state = project;
  }
}

class _TestServerNotifier extends Notifier<Server?> {
  @override
  Server? build() => null;

  void set(Server? server) {
    state = server;
  }
}

const _server = Server(
  id: 'server-1',
  name: 'Server 1',
  host: '192.0.2.10',
  port: 22,
  sshUser: 'ubuntu',
  authMethod: ServerAuthMethod.password,
);

const _projectA = Project(
  id: 'project-a',
  serverId: 'server-1',
  name: 'Project A',
  type: 'Web app',
  gitUrl: '',
  primaryDomain: 'a.example.com',
);

const _projectB = Project(
  id: 'project-b',
  serverId: 'server-1',
  name: 'Project B',
  type: 'Web app',
  gitUrl: '',
  primaryDomain: 'b.example.com',
);

class _ScopeHarness extends ConsumerStatefulWidget {
  const _ScopeHarness({required this.bindCompleters});

  final Map<String, Completer<void>> bindCompleters;

  @override
  ConsumerState<_ScopeHarness> createState() => _ScopeHarnessState();
}

class _ScopeHarnessState extends ConsumerState<_ScopeHarness>
    with WorkspaceScopedConsumerState<_ScopeHarness> {
  String _label = 'idle';

  void _bind(Project project, Server server) {
    bindWorkspaceSelection(project, server);
    final run = captureWorkspaceRun(
      metadata: <String, Object?>{'projectId': project.id},
    );
    unawaited(() async {
      await widget.bindCompleters[project.id]!.future;
      guardSetState(run, () {
        _label = 'loaded ${project.id}';
      });
    }());
  }

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(selectedProjectProvider);
    final server = ref.watch(selectedServerProvider);
    scheduleScopeBind(project: project, server: server, onBind: _bind);
    return Text(_label, key: const Key('scope-harness-label'));
  }
}

void main() {
  testWidgets('late bind completion cannot update a newer workspace scope', (
    tester,
  ) async {
    final completers = <String, Completer<void>>{
      _projectA.id: Completer<void>(),
      _projectB.id: Completer<void>(),
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedProjectProvider.overrideWith(
            (ref) => ref.watch(_testProjectProvider),
          ),
          selectedServerProvider.overrideWith(
            (ref) => ref.watch(_testServerProvider),
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, child) {
              return _ScopeHarness(bindCompleters: completers);
            },
          ),
        ),
      ),
    );

    final context = tester.element(find.byType(_ScopeHarness));
    final container = ProviderScope.containerOf(context);
    container.read(_testServerProvider.notifier).set(_server);
    container.read(_testProjectProvider.notifier).set(_projectA);
    await tester.pump();
    await tester.pump();

    container.read(_testProjectProvider.notifier).set(_projectB);
    await tester.pump();
    await tester.pump();

    completers[_projectA.id]!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('loaded project-a'), findsNothing);
    expect(find.text('idle'), findsOneWidget);

    completers[_projectB.id]!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('loaded project-b'), findsOneWidget);
  });
}
