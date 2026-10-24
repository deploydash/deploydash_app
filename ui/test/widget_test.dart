import 'package:ui/main.dart';
import 'package:ui/providers/server_list_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MyApp shows first-run server onboarding', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverCatalogProvider.overrideWith(
            () => _FakeServerCatalogNotifier(
              const ServerCatalogState(
                isLoading: false,
                onboardingComplete: false,
                servers: [],
              ),
            ),
          ),
        ],
        child: const MyApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Connect your first server'), findsWidgets);
    expect(find.byKey(const Key('server-onboarding-start-button')), findsOne);
  });
}

class _FakeServerCatalogNotifier extends ServerCatalogNotifier {
  _FakeServerCatalogNotifier(this._seedState);

  final ServerCatalogState _seedState;

  @override
  ServerCatalogState build() => _seedState;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> selectServer(String serverId) async {
    state = state.copyWith(selectedServerId: serverId);
  }
}
