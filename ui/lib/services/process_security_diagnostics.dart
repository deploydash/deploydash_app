/// What the native layer reported about process hardening at startup.
///
/// Deploy Dash disables core dumps and ptrace on Linux, restricts image
/// loading on Windows, and requires a Hardened Runtime on macOS, all before
/// Flutter or Python starts. This is that result, carried into Dart so a
/// refusal to launch can say which control failed instead of just failing.
/// See `docs/reference/desktop-process-hardening.md`.
class ProcessSecurityDiagnostics {
  /// Creates a diagnostics record. Built by [tryParse] from the native
  /// payload, not by hand.
  const ProcessSecurityDiagnostics({
    required this.required,
    required this.effective,
    required this.platform,
    required this.controls,
    required this.errors,
  });

  /// Whether hardening is mandatory for this build.
  ///
  /// False for a debug or profile build, where the controls would prevent
  /// debugging; a release build that reports false has a packaging defect.
  final bool required;

  /// Whether every required control was actually applied.
  ///
  /// [required] and [effective] are separate on purpose: `required &&
  /// !effective` is the one combination that must stop the launch, and it is
  /// not expressible in a single flag.
  final bool effective;

  /// Which platform's control set was applied.
  final String platform;

  /// Per-control results, named by the native layer. Read for diagnostics
  /// only; the decision is [effective].
  final Map<String, Object?> controls;

  /// What went wrong, in the native layer's words. Empty when nothing did.
  final List<String> errors;

  /// Reads the native payload, or null when it is not one.
  ///
  /// Null means "the native layer said nothing intelligible", which callers
  /// must treat as hardening *not* confirmed. Every field is type-checked
  /// rather than coerced: a payload that cannot state plainly that the
  /// controls were applied is not evidence that they were.
  static ProcessSecurityDiagnostics? tryParse(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final required = raw['required'];
    final effective = raw['effective'];
    final platform = raw['platform'];
    if (required is! bool || effective is! bool || platform is! String) {
      return null;
    }
    final controlsRaw = raw['controls'];
    final errorsRaw = raw['errors'];
    return ProcessSecurityDiagnostics(
      required: required,
      effective: effective,
      platform: platform,
      controls: controlsRaw is Map<String, dynamic>
          ? Map<String, Object?>.unmodifiable(controlsRaw)
          : const <String, Object?>{},
      errors: errorsRaw is List
          ? errorsRaw.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }

  /// A single line of `key=value` pairs for a startup failure message.
  ///
  /// Includes [errors] only when there are some, so the common failure reads
  /// as three facts rather than three facts and an empty list.
  String describeForError() {
    final details = <String>[
      'process_security_required=$required',
      'process_security_effective=$effective',
      'process_security_platform=$platform',
    ];
    if (errors.isNotEmpty) {
      details.add('process_security_errors=${errors.join('; ')}');
    }
    return details.join(', ');
  }
}
