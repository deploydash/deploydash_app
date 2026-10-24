import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The shell every Deploy Dash dialog is built in.
///
/// Owns the padding, the title-and-description block and the height cap, so
/// dialogs across the app open at the same size and read the same way. Build
/// on this rather than [AlertDialog] directly.
class AppDialogScaffold extends StatelessWidget {
  /// Creates a dialog shell.
  const AppDialogScaffold({
    super.key,
    required this.title,
    required this.child,
    this.description,
    this.actions = const <Widget>[],
    this.maxWidth = 520,
    this.maxHeightFactor = 0.72,
  });

  /// What the dialog is for, in sentence case.
  final String title;

  /// One line under the title explaining what is about to happen. Omitted
  /// when blank rather than rendered as an empty gap.
  final String? description;

  /// The dialog's body.
  final Widget child;

  /// The footer buttons, cancel first and the primary action last.
  final List<Widget> actions;

  /// The widest the body grows.
  final double maxWidth;

  /// The body's height as a fraction of the window, clamped to 260-720
  /// logical pixels -- so a dialog neither exceeds a short window nor sprawls
  /// on a tall one.
  final double maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    // Hoisted so the `!= null` check promotes it; a widget field is never
    // promoted.
    final description = this.description;
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final maxHeight = (viewportHeight * maxHeightFactor).clamp(260.0, 720.0);
    return AlertDialog(
      titlePadding: EdgeInsets.fromLTRB(
        tokens.spaceXl,
        tokens.spaceXl,
        tokens.spaceXl,
        tokens.spaceSm,
      ),
      contentPadding: EdgeInsets.fromLTRB(
        tokens.spaceXl,
        0,
        tokens.spaceXl,
        tokens.spaceLg,
      ),
      actionsPadding: EdgeInsets.fromLTRB(
        tokens.spaceLg,
        0,
        tokens.spaceLg,
        tokens.spaceLg,
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title),
          if (description != null && description.trim().isNotEmpty) ...[
            SizedBox(height: tokens.spaceXs),
            Text(description, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        child: child,
      ),
      actions: actions,
    );
  }
}

/// The Cancel + confirm action row shared by [AppConfirmDialog] and
/// [AppDestructiveConfirmDialog].
///
/// Why the behavior is a parameter, not a branch on a bool: plain confirm
/// runs the caller's callback and then pops `true`, while destructive pops
/// `true` with no callback at all (the caller acts on the popped value).
/// A styling-only merge would silently rewire one of those two semantics
/// (D-70) — so the confirm press is passed in as [onConfirmPressed], already
/// resolved to "callback-then-pop" or "pop-only-or-disabled" by the caller.
List<Widget> _confirmActions({
  required BuildContext context,
  required String cancelLabel,
  required String confirmLabel,
  required VoidCallback? onConfirmPressed,
  ButtonStyle? confirmStyle,
  Key? confirmButtonKey,
}) {
  return [
    TextButton(
      onPressed: () => Navigator.of(context).pop(false),
      child: Text(cancelLabel),
    ),
    FilledButton(
      key: confirmButtonKey,
      style: confirmStyle,
      onPressed: onConfirmPressed,
      child: Text(confirmLabel),
    ),
  ];
}

/// A blocking notice with a single OK button, built on [AppDialogScaffold].
///
/// Why a shared function instead of one more ConfirmDialog-with-empty-callback:
/// seven notice sites already converged on this exact single-OK shape (D-43),
/// while four still hand-roll Cancel+OK around a callback that does nothing.
/// The Cancel button on a notice is vestigial — both buttons just pop — so the
/// far-site shape wins and this function owns it.
Future<void> showAppNotice(
  BuildContext context, {
  required String title,
  required String message,
  Key? okButtonKey,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AppDialogScaffold(
      title: title,
      actions: [
        FilledButton(
          key: okButtonKey,
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('OK'),
        ),
      ],
      child: Text(message),
    ),
  );
}

/// A confirmation for an ordinary action.
///
/// Pops `true` when confirmed and `false` when cancelled, so the caller can
/// await the result rather than routing it through a callback -- though
/// [onConfirm] runs first, before the pop.
class AppConfirmDialog extends StatelessWidget {
  /// Creates a confirmation dialog.
  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.description,
    required this.onConfirm,
    this.confirmLabel = 'Continue',
    this.cancelLabel = 'Cancel',
    this.body,
  });

  /// What is being confirmed.
  final String title;

  /// What will happen if the user continues. Required here, unlike on
  /// [AppDialogScaffold]: a confirmation with nothing to read is a dialog
  /// that teaches the user to click through.
  final String description;

  /// Runs before the dialog pops with `true`.
  final VoidCallback onConfirm;

  /// The primary button's label. Name the verb rather than saying "OK".
  final String confirmLabel;

  /// The cancel button's label.
  final String cancelLabel;

  /// Extra detail between the description and the buttons.
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    return AppDialogScaffold(
      title: title,
      description: description,
      actions: _confirmActions(
        context: context,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
        onConfirmPressed: () {
          onConfirm();
          Navigator.of(context).pop(true);
        },
      ),
      child: body ?? const SizedBox.shrink(),
    );
  }
}

/// A confirmation for something that destroys data.
///
/// The shared treatment for every destructive action -- an error-coloured
/// primary button, and [confirmEnabled] so a dialog can require the user to
/// type a name before the button works. Never style a destructive
/// confirmation by hand; a delete that looks like an ordinary save is how one
/// gets clicked.
///
/// Pops `true` or `false`, with no `onConfirm`: destructive work happens after
/// the dialog closes and the caller has the answer, not from inside it.
class AppDestructiveConfirmDialog extends StatelessWidget {
  /// Creates a destructive confirmation.
  const AppDestructiveConfirmDialog({
    super.key,
    required this.title,
    required this.description,
    this.confirmLabel = 'Delete',
    this.cancelLabel = 'Cancel',
    this.body,
    this.confirmEnabled = true,
    this.confirmButtonKey,
  });

  /// What is being deleted.
  final String title;

  /// Exactly what will be destroyed, and whether it can be recovered.
  final String description;

  /// The destructive button's label. `Delete` by default.
  final String confirmLabel;

  /// The cancel button's label.
  final String cancelLabel;

  /// Extra detail -- typically the list of what will be removed, or the
  /// field the user must type into.
  final Widget? body;

  /// Whether the destructive button is usable. False while a required
  /// confirmation has not been typed.
  final bool confirmEnabled;

  /// A key for the destructive button, so tests and E2E runners can address
  /// it directly.
  final Key? confirmButtonKey;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppDialogScaffold(
      title: title,
      description: description,
      actions: _confirmActions(
        context: context,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
        onConfirmPressed: confirmEnabled
            ? () => Navigator.of(context).pop(true)
            : null,
        confirmStyle: FilledButton.styleFrom(
          backgroundColor: colorScheme.error,
          foregroundColor: colorScheme.onError,
        ),
        confirmButtonKey: confirmButtonKey,
      ),
      child: body ?? const SizedBox.shrink(),
    );
  }
}
