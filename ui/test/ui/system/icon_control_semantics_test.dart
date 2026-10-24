import 'package:ui/services/local_search_index.dart';
import 'package:ui/ui/system/app_actions.dart';
import 'package:ui/ui/system/app_context_navigation.dart';
import 'package:ui/ui/system/app_forms.dart';
import 'package:ui/ui/system/app_search.dart';
import 'package:ui/ui/system/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guard: every icon-only control in the shared primitives has a label a
/// screen reader can read.
///
/// `AGENTS.md` makes icon-only the strict default for row-level actions, so
/// these are exactly the controls most likely to reach a user with nothing to
/// announce but "button". The E2E driver finds elements by `Key`, type and
/// text, so **every existing gate passes whether or not a label exists** —
/// the accessibility coverage was an illusion, which is what T-3.7.5 says.
///
/// A tooltip is not a label. Flutter's `Tooltip` sets `SemanticsProperties.
/// tooltip`, and while some platforms fall back to announcing it, the label
/// is the field assistive technology reads first and the only one guaranteed
/// to be used. This walks the semantics tree rather than the widget tree so
/// it asserts what is actually exposed.
Widget _host(Widget child) {
  return MaterialApp(
    theme: buildDeployDashTheme(ThemeData.light()),
    home: Scaffold(body: Center(child: child)),
  );
}

/// Every semantics node in the tree that is a button.
List<SemanticsNode> _buttonNodes(SemanticsNode root) {
  final found = <SemanticsNode>[];
  void walk(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isButton) {
      found.add(node);
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  walk(root);
  return found;
}

void main() {
  Future<void> expectEveryButtonLabelled(
    WidgetTester tester,
    Widget child, {
    required String what,
  }) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(child));
    await tester.pumpAndSettle();

    final root = tester.binding.rootElement!.renderObject!.debugSemantics;
    expect(root, isNotNull, reason: 'semantics must be enabled for $what');
    final buttons = _buttonNodes(root!);
    expect(
      buttons,
      isNotEmpty,
      reason: '$what renders no button, so this test asserts nothing',
    );
    final unlabelled = buttons
        .where((node) => node.getSemanticsData().label.trim().isEmpty)
        .toList();
    expect(
      unlabelled,
      isEmpty,
      reason:
          '$what exposes ${unlabelled.length} button(s) with no semantic '
          'label. A tooltip is not a label: give the control a Semantics '
          'label carrying the same verb the tooltip does.',
    );
    handle.dispose();
  }

  testWidgets('the collapsed rail action button is labelled', (tester) async {
    await expectEveryButtonLabelled(
      tester,
      AppRailActionButton(
        extended: false,
        icon: Icons.add,
        label: 'Add server',
        onPressed: () {},
      ),
      what: 'AppRailActionButton (collapsed)',
    );
  });

  testWidgets('the contextual navigation scroll buttons are labelled', (
    tester,
  ) async {
    // Narrow enough that the rail overflows, which is the only state that
    // renders the scroll arrows.
    await expectEveryButtonLabelled(
      tester,
      SizedBox(
        width: 160,
        child: AppContextNavigation(
          items: List<AppContextNavigationItem>.generate(
            8,
            (index) => AppContextNavigationItem(
              id: 'destination-$index',
              label: 'Destination $index',
              icon: Icons.folder_outlined,
            ),
          ),
          selectedIndex: 0,
          onSelected: (_) {},
          axis: Axis.horizontal,
          keyNamespace: 'project',
        ),
      ),
      what: 'AppContextNavigation scroll buttons',
    );
  });

  testWidgets('the collapsed search button is labelled', (tester) async {
    await expectEveryButtonLabelled(
      tester,
      SizedBox(
        width: 300,
        child: AppSearchOverlay(
          focusNode: FocusNode(),
          collapsed: true,
          resultsBuilder: (_) => const <LocalSearchResult>[],
          onSelected: (_) {},
        ),
      ),
      what: 'AppSearchOverlay (collapsed)',
    );
  });

  testWidgets('the search clear button is labelled', (tester) async {
    await expectEveryButtonLabelled(
      tester,
      SizedBox(
        width: 300,
        child: AppSearchField(
          controller: TextEditingController(text: 'prod'),
          focusNode: FocusNode(),
          onClear: () {},
        ),
      ),
      what: 'AppSearchField clear button',
    );
  });

  testWidgets('the password visibility toggle is labelled', (tester) async {
    await expectEveryButtonLabelled(
      tester,
      const SizedBox(
        width: 300,
        child: AppPasswordFormField(labelText: 'Password'),
      ),
      what: 'AppPasswordFormField',
    );
  });
}
