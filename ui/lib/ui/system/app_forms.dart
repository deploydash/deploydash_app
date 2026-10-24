import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_accessibility_identifier.dart';
import 'app_dialogs.dart';
import 'app_theme.dart';

/// A dialog holding a form, scrollable when the form outgrows the window.
///
/// Built on [AppDialogScaffold], adding the scroll view and scrollbar so no
/// form dialog has to arrange its own -- a form that silently clips its last
/// field on a short window is the failure this prevents.
class AppFormDialog extends StatelessWidget {
  /// Creates a form dialog.
  const AppFormDialog({
    super.key,
    required this.title,
    required this.child,
    required this.actions,
    this.description,
    this.maxWidth = 420,
    this.maxHeightFactor = 0.72,
  });

  /// What the form is for, in sentence case.
  final String title;

  /// One line under the title explaining what it does.
  final String? description;

  /// The form's fields, usually one or more [AppFormSection]s.
  final Widget child;

  /// The footer buttons, cancel first and the save action last.
  final List<Widget> actions;

  /// The form's width. Narrower than a plain dialog by default: a form reads
  /// better in a column than spread across a wide window.
  final double maxWidth;

  /// The form's height as a fraction of the window, before it scrolls.
  final double maxHeightFactor;

  @override
  Widget build(BuildContext context) {
    return AppDialogScaffold(
      title: title,
      description: description,
      actions: actions,
      maxWidth: maxWidth,
      maxHeightFactor: maxHeightFactor,
      child: SizedBox(
        width: maxWidth,
        child: Scrollbar(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(right: context.appThemeTokens.spaceXs),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// A group of related fields, evenly spaced, with an optional heading.
///
/// The spacing comes from the token scale rather than from each form, so
/// fields sit the same distance apart in every dialog.
class AppFormSection extends StatelessWidget {
  /// Creates a form section.
  const AppFormSection({
    super.key,
    required this.children,
    this.title,
    this.description,
  });

  /// The fields, spaced apart automatically.
  final List<Widget> children;

  /// What this group of fields is for. Omitted when blank.
  final String? title;

  /// A line explaining the group, above the fields.
  final String? description;

  @override
  Widget build(BuildContext context) {
    final tokens = context.appThemeTokens;
    // Hoisted so the `!= null` checks promote them; a widget field cannot be.
    final title = this.title?.trim();
    final description = this.description?.trim();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null && title.isNotEmpty) ...[
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          SizedBox(height: tokens.spaceXs / 2),
        ],
        if (description != null && description.isNotEmpty) ...[
          Text(description, style: Theme.of(context).textTheme.bodySmall),
          SizedBox(height: tokens.spaceSm),
        ],
        ..._withSpacing(children, tokens.spaceSm),
      ],
    );
  }
}

/// The standard text input.
///
/// A `TextFormField` wrapper, not a `TextField` one: validation, the error
/// line and form submission come with it, which is why new forms are expected
/// to use this rather than compose their own.
class AppTextFormField extends StatelessWidget {
  /// Creates a text field.
  const AppTextFormField({
    super.key,
    this.fieldKey,
    this.controller,
    required this.labelText,
    this.hintText,
    this.helperText,
    this.helperMaxLines,
    this.validator,
    this.onChanged,
    this.keyboardType,
    this.textInputAction,
    this.focusNode,
    this.autofocus = false,
    this.inputFormatters,
    this.autovalidateMode = AutovalidateMode.onUserInteraction,
    this.obscureText = false,
    this.enabled = true,
    this.readOnly = false,
    this.maxLines = 1,
    this.suffixIcon,
    this.onFieldSubmitted,
  });

  /// A key for the field itself, so tests and E2E runners can address it.
  final Key? fieldKey;

  /// The field's text. Owned by the caller.
  final TextEditingController? controller;

  /// The field's label, in sentence case. Always present -- a bare input with
  /// only a placeholder leaves nothing on screen once the user types.
  final String labelText;

  /// Placeholder text, shown while the field is empty.
  final String? hintText;

  /// A line under the field explaining what to enter or why it matters.
  final String? helperText;

  /// How many lines the helper may take before truncating.
  final int? helperMaxLines;

  /// Returns the problem with the current value, or null when it is valid.
  final String? Function(String?)? validator;

  /// Called on every keystroke.
  final ValueChanged<String>? onChanged;

  /// The keyboard to request. Irrelevant on desktop, kept so this wrapper is a
  /// complete stand-in for `TextFormField`.
  final TextInputType? keyboardType;

  /// What the Enter key does.
  final TextInputAction? textInputAction;

  /// The field's focus, for ordering or programmatic focus.
  final FocusNode? focusNode;

  /// Whether to focus this field when the form opens.
  final bool autofocus;

  /// Restrictions applied as the user types.
  final List<TextInputFormatter>? inputFormatters;

  /// When to validate. Defaults to after the user has interacted, so a form
  /// does not open covered in errors for fields nobody has touched.
  final AutovalidateMode autovalidateMode;

  /// Whether to mask the text. Forces a single line when set.
  final bool obscureText;

  /// Whether the field accepts input.
  final bool enabled;

  /// Whether the field shows a value the user cannot change.
  final bool readOnly;

  /// How many lines the input grows to.
  final int? maxLines;

  /// A control inside the field's right edge.
  final Widget? suffixIcon;

  /// Called when the user presses Enter.
  final ValueChanged<String>? onFieldSubmitted;

  @override
  Widget build(BuildContext context) {
    return appAccessibilityIdentifierForKeys(
      widgetKey: key,
      fieldKey: fieldKey,
      child: TextFormField(
        key: fieldKey,
        controller: controller,
        enabled: enabled,
        readOnly: readOnly,
        obscureText: obscureText,
        autovalidateMode: autovalidateMode,
        validator: validator,
        onChanged: onChanged,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        focusNode: focusNode,
        autofocus: autofocus,
        inputFormatters: inputFormatters,
        maxLines: obscureText ? 1 : maxLines,
        onFieldSubmitted: onFieldSubmitted,
        decoration: InputDecoration(
          labelText: labelText,
          hintText: hintText,
          helperText: helperText,
          helperMaxLines: helperMaxLines,
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }
}

/// A text input that masks its value, with a reveal toggle.
///
/// The toggle carries a semantic label as well as a tooltip, because a
/// tooltip alone is not an accessible name -- assistive tech may or may not
/// announce it.
class AppPasswordFormField extends StatefulWidget {
  /// Creates a password field.
  const AppPasswordFormField({
    super.key,
    this.fieldKey,
    this.controller,
    required this.labelText,
    this.hintText,
    this.helperText,
    this.helperMaxLines,
    this.validator,
    this.onChanged,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.onFieldSubmitted,
    this.autovalidateMode = AutovalidateMode.onUserInteraction,
  });

  /// A key for the field itself, so tests and E2E runners can address it.
  final Key? fieldKey;

  /// The field's text. Owned by the caller.
  final TextEditingController? controller;

  /// The field's label, in sentence case. Always present -- a bare input with
  /// only a placeholder leaves nothing on screen once the user types.
  final String labelText;

  /// Placeholder text, shown while the field is empty.
  final String? hintText;

  /// A line under the field explaining what to enter or why it matters.
  final String? helperText;

  /// How many lines the helper may take before truncating.
  final int? helperMaxLines;

  /// Returns the problem with the current value, or null when it is valid.
  final String? Function(String?)? validator;

  /// Called on every keystroke.
  final ValueChanged<String>? onChanged;

  /// The field's focus, for ordering or programmatic focus.
  final FocusNode? focusNode;

  /// Whether to focus this field when the form opens.
  final bool autofocus;

  /// What the Enter key does.
  final TextInputAction? textInputAction;

  /// Called when the user presses Enter.
  final ValueChanged<String>? onFieldSubmitted;

  /// When to validate. Defaults to after the user has interacted, so a form
  /// does not open covered in errors for fields nobody has touched.
  final AutovalidateMode autovalidateMode;

  @override
  State<AppPasswordFormField> createState() => _AppPasswordFormFieldState();
}

class _AppPasswordFormFieldState extends State<AppPasswordFormField> {
  bool _obscureText = true;

  @override
  Widget build(BuildContext context) {
    return appAccessibilityIdentifierForKeys(
      widgetKey: widget.key,
      fieldKey: null,
      child: AppTextFormField(
        controller: widget.controller,
        fieldKey: widget.fieldKey,
        labelText: widget.labelText,
        hintText: widget.hintText,
        helperText: widget.helperText,
        helperMaxLines: widget.helperMaxLines,
        validator: widget.validator,
        onChanged: widget.onChanged,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        textInputAction: widget.textInputAction,
        onFieldSubmitted: widget.onFieldSubmitted,
        obscureText: _obscureText,
        autovalidateMode: widget.autovalidateMode,
        suffixIcon: IconButton(
          tooltip: _obscureText ? 'Show password' : 'Hide password',
          onPressed: () => setState(() => _obscureText = !_obscureText),
          icon: Icon(
            _obscureText
                ? Icons.visibility_outlined
                : Icons.visibility_off_outlined,
            semanticLabel: _obscureText ? 'Show password' : 'Hide password',
          ),
        ),
      ),
    );
  }
}

/// A text input for numbers.
///
/// Requests a numeric keyboard and takes formatters, but does not itself
/// restrict input: the range a number is allowed to take belongs with the
/// [validator], where the message can say what the limit is.
class AppNumberFormField extends StatelessWidget {
  /// Creates a number field.
  const AppNumberFormField({
    super.key,
    this.fieldKey,
    this.controller,
    required this.labelText,
    this.hintText,
    this.helperText,
    this.validator,
    this.onChanged,
    this.inputFormatters,
    this.autovalidateMode = AutovalidateMode.onUserInteraction,
    this.enabled = true,
    this.focusNode,
    this.autofocus = false,
    this.textInputAction,
    this.onFieldSubmitted,
  });

  /// A key for the field itself, so tests and E2E runners can address it.
  final Key? fieldKey;

  /// The field's text. Owned by the caller.
  final TextEditingController? controller;

  /// The field's label, in sentence case. Always present -- a bare input with
  /// only a placeholder leaves nothing on screen once the user types.
  final String labelText;

  /// Placeholder text, shown while the field is empty.
  final String? hintText;

  /// A line under the field explaining what to enter or why it matters.
  final String? helperText;

  /// Returns the problem with the current value, or null when it is valid.
  final String? Function(String?)? validator;

  /// Called on every keystroke.
  final ValueChanged<String>? onChanged;

  /// Restrictions applied as the user types.
  final List<TextInputFormatter>? inputFormatters;

  /// When to validate. Defaults to after the user has interacted, so a form
  /// does not open covered in errors for fields nobody has touched.
  final AutovalidateMode autovalidateMode;

  /// Whether the field accepts input.
  final bool enabled;

  /// The field's focus, for ordering or programmatic focus.
  final FocusNode? focusNode;

  /// Whether to focus this field when the form opens.
  final bool autofocus;

  /// What the Enter key does.
  final TextInputAction? textInputAction;

  /// Called when the user presses Enter.
  final ValueChanged<String>? onFieldSubmitted;

  @override
  Widget build(BuildContext context) {
    return appAccessibilityIdentifierForKeys(
      widgetKey: key,
      fieldKey: null,
      child: AppTextFormField(
        controller: controller,
        fieldKey: fieldKey,
        labelText: labelText,
        hintText: hintText,
        helperText: helperText,
        validator: validator,
        onChanged: onChanged,
        enabled: enabled,
        focusNode: focusNode,
        autofocus: autofocus,
        textInputAction: textInputAction,
        onFieldSubmitted: onFieldSubmitted,
        keyboardType: TextInputType.number,
        inputFormatters: inputFormatters,
        autovalidateMode: autovalidateMode,
      ),
    );
  }
}

/// A dropdown that takes part in form validation.
class AppSelectFormField<T> extends StatelessWidget {
  /// Creates a select field.
  const AppSelectFormField({
    super.key,
    this.fieldKey,
    required this.labelText,
    required this.items,
    this.value,
    this.onChanged,
    this.validator,
    this.helperText,
    this.isExpanded = true,
    this.autovalidateMode = AutovalidateMode.onUserInteraction,
  });

  /// A key for the field, so tests and E2E runners can address it.
  final Key? fieldKey;

  /// The field's label, in sentence case.
  final String labelText;

  /// The options to choose from.
  final List<DropdownMenuItem<T>> items;

  /// The current selection, or null when nothing is chosen.
  final T? value;

  /// Called with the new selection.
  final ValueChanged<T?>? onChanged;

  /// Returns the problem with the current selection, or null.
  final String? Function(T?)? validator;

  /// A line under the field explaining the choice.
  final String? helperText;

  /// Whether the dropdown fills its width. True by default, so a select lines
  /// up with the text fields around it.
  final bool isExpanded;

  /// When to validate. Defaults to after the user has interacted.
  final AutovalidateMode autovalidateMode;

  @override
  Widget build(BuildContext context) {
    return appAccessibilityIdentifierForKeys(
      widgetKey: key,
      fieldKey: fieldKey,
      child: DropdownButtonFormField<T>(
        key: fieldKey,
        initialValue: value,
        isExpanded: isExpanded,
        autovalidateMode: autovalidateMode,
        validator: validator,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: labelText,
          helperText: helperText,
        ),
        items: items,
      ),
    );
  }
}

/// A labelled switch, for a setting that takes effect on its own.
///
/// Use [AppCheckboxField] instead for something the user is agreeing to as
/// part of a larger action -- a confirmation, or an acknowledgement.
class AppToggleField extends StatelessWidget {
  /// Creates a toggle.
  const AppToggleField({
    super.key,
    this.fieldKey,
    required this.value,
    required this.title,
    this.subtitle,
    this.onChanged,
  });

  /// A key for the field, so tests and E2E runners can address it.
  final Key? fieldKey;

  /// Whether the setting is on.
  final bool value;

  /// What the setting does, in sentence case.
  final String title;

  /// What turning it on means, when that is not obvious from the title.
  final String? subtitle;

  /// Called with the new value. Null disables the toggle.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return appAccessibilityIdentifierForKeys(
      widgetKey: key,
      fieldKey: fieldKey,
      child: SwitchListTile.adaptive(
        key: fieldKey,
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: onChanged,
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
      ),
    );
  }
}

/// A labelled checkbox, for something the user is agreeing to.
class AppCheckboxField extends StatelessWidget {
  /// Creates a checkbox.
  const AppCheckboxField({
    super.key,
    required this.value,
    required this.title,
    this.subtitle,
    this.onChanged,
    this.dense = false,
  });

  /// Whether it is ticked.
  final bool value;

  /// What is being agreed to, in sentence case.
  final String title;

  /// Further detail below the title.
  final String? subtitle;

  /// Called with the new value. Null disables the checkbox.
  final ValueChanged<bool?>? onChanged;

  /// Whether to use tighter vertical spacing, for a checkbox inside a list.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    return CheckboxListTile.adaptive(
      dense: dense,
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
    );
  }
}

List<Widget> _withSpacing(List<Widget> children, double spacing) {
  if (children.isEmpty) {
    return const <Widget>[];
  }
  final result = <Widget>[];
  for (var index = 0; index < children.length; index += 1) {
    if (index > 0) {
      result.add(SizedBox(height: spacing));
    }
    result.add(children[index]);
  }
  return result;
}
