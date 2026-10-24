import 'package:ui/ui/system/app_dialogs.dart';
import 'package:ui/ui/system/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// Characterization for D-70 (T-012, commit 1): the confirm-actions twin
// extraction must preserve the two load-bearing halves — plain confirm runs
// the callback BEFORE popping (reversing strands the callback's effects
// behind a popped route), and destructive keeps error styling with no
// callback at all.
void main() {
  testWidgets('plain confirm runs the callback before popping', (tester) async {
    BuildContext? dialogContext;
    var callbackSawCurrentRoute = false;
    var callbackRan = false;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildDeployDashTheme(ThemeData.light()),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showDialog<bool>(
                    context: context,
                    builder: (_) => AppConfirmDialog(
                      title: 'Continue?',
                      description: 'Proceed with the action.',
                      onConfirm: () {
                        callbackRan = true;
                        callbackSawCurrentRoute =
                            ModalRoute.of(dialogContext!)?.isCurrent ?? false;
                      },
                      body: Builder(
                        builder: (bodyContext) {
                          dialogContext = bodyContext;
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(callbackRan, isTrue);
    expect(
      callbackSawCurrentRoute,
      isTrue,
      reason: 'onConfirm must run while the dialog route is still current.',
    );
    expect(find.text('Continue?'), findsNothing);
  });

  testWidgets('destructive confirm keeps error styling and plain pop', (
    tester,
  ) async {
    bool? poppedValue;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildDeployDashTheme(ThemeData.light()),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () async {
                  poppedValue = await showDialog<bool>(
                    context: context,
                    builder: (_) => const AppDestructiveConfirmDialog(
                      title: 'Delete it?',
                      description: 'Gone forever.',
                      confirmButtonKey: Key('destructive-confirm'),
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();

    final colorScheme = Theme.of(
      tester.element(find.byKey(const Key('destructive-confirm'))),
    ).colorScheme;
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('destructive-confirm')),
    );
    expect(button.style?.backgroundColor?.resolve({}), colorScheme.error);
    expect(button.style?.foregroundColor?.resolve({}), colorScheme.onError);

    await tester.tap(find.byKey(const Key('destructive-confirm')));
    await tester.pump();
    expect(poppedValue, isTrue);
  });
}
