/// One entry in the runtime picker shown when configuring a web app deploy.
///
/// The value pairs the wire-level Railpack provider with the copy and
/// defaults a novice sees, so the picker, the pre-filled command fields and
/// the saved project row all read the same source.
class RailpackRuntimeOption {
  /// Creates a runtime option. The set of them is fixed at
  /// [railpackRuntimeOptions]; nothing constructs one at runtime.
  const RailpackRuntimeOption({
    required this.id,
    required this.label,
    required this.provider,
    required this.suggestedPort,
    required this.defaultBuildCommand,
    required this.defaultRunCommand,
    required this.commandHelperText,
  });

  /// Stable selection id. Equal to [provider] for every real runtime; only
  /// auto-detect has an id with no provider behind it.
  final String id;

  /// What the picker shows, in the runtime's own spelling ('Node.js', '.NET').
  final String label;

  /// The Railpack provider sent to the backend, or null to let Railpack
  /// decide.
  final String? provider;

  /// The port the deploy form pre-fills, being the one this runtime's
  /// frameworks conventionally listen on. A starting point, not a constraint.
  final int suggestedPort;

  /// Build command pre-filled in the form. Blank means "send nothing and let
  /// Railpack detect it" -- which is deliberately what almost every runtime
  /// does.
  final String defaultBuildCommand;

  /// Run command pre-filled in the form, with the same blank-means-detect
  /// rule as [defaultBuildCommand].
  final String defaultRunCommand;

  /// The sentence under the command fields explaining what blank means here.
  final String commandHelperText;
}

/// Selection id for "let Railpack work it out", the picker's default.
const String railpackAutoDetectRuntimeId = 'auto_detect';

/// The option that sends no provider at all.
///
/// Also the fallback every lookup here returns for an unrecognised id, so a
/// project row written by a newer build degrades to auto-detection rather
/// than to a wrong runtime.
const RailpackRuntimeOption railpackAutoDetectRuntime = RailpackRuntimeOption(
  id: railpackAutoDetectRuntimeId,
  label: 'Auto-detect',
  provider: null,
  suggestedPort: 3000,
  defaultBuildCommand: '',
  defaultRunCommand: '',
  commandHelperText:
      'Leave these blank to enable auto detection of the build and startup '
      'commands.',
);

/// The Node.js option, named because it is the one runtime that pre-fills
/// commands, and [railpackRuntimeSelectionId] has to recognise them.
const RailpackRuntimeOption railpackNodeRuntime = RailpackRuntimeOption(
  id: 'node',
  label: 'Node.js',
  provider: 'node',
  suggestedPort: 3000,
  defaultBuildCommand: 'npm run build',
  defaultRunCommand: 'npm run start',
  commandHelperText:
      'Deploy Dash pre-fills the common Node.js defaults. Clear either '
      'command to enable auto detection instead.',
);

/// Every runtime the picker offers, in display order, auto-detect first.
const List<RailpackRuntimeOption>
railpackRuntimeOptions = <RailpackRuntimeOption>[
  railpackAutoDetectRuntime,
  railpackNodeRuntime,
  RailpackRuntimeOption(
    id: 'python',
    label: 'Python',
    provider: 'python',
    suggestedPort: 8000,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of Flask, Django, '
        'FastAPI, and other Python entrypoints.',
  ),
  RailpackRuntimeOption(
    id: 'php',
    label: 'PHP',
    provider: 'php',
    suggestedPort: 8080,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of PHP entrypoints, '
        'or override them if the app uses a custom entrypoint.',
  ),
  RailpackRuntimeOption(
    id: 'ruby',
    label: 'Ruby',
    provider: 'ruby',
    suggestedPort: 3000,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of Rails, Rack, or '
        'other Ruby app defaults.',
  ),
  RailpackRuntimeOption(
    id: 'golang',
    label: 'Go',
    provider: 'golang',
    suggestedPort: 3000,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of the Go build '
        'and startup commands.',
  ),
  RailpackRuntimeOption(
    id: 'java',
    label: 'Java',
    provider: 'java',
    suggestedPort: 8080,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of the Java build '
        'tool and startup command.',
  ),
  RailpackRuntimeOption(
    id: 'rust',
    label: 'Rust',
    provider: 'rust',
    suggestedPort: 3000,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of the Rust build '
        'and startup command.',
  ),
  RailpackRuntimeOption(
    id: 'dotnet',
    label: '.NET',
    provider: 'dotnet',
    suggestedPort: 8080,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of .NET project and '
        'startup command.',
  ),
  RailpackRuntimeOption(
    id: 'deno',
    label: 'Deno',
    provider: 'deno',
    suggestedPort: 8000,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of the Deno app layout '
        'and entrypoint.',
  ),
  RailpackRuntimeOption(
    id: 'elixir',
    label: 'Elixir',
    provider: 'elixir',
    suggestedPort: 4000,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Leave commands blank to enable auto detection of Phoenix or other '
        'Elixir runtime conventions.',
  ),
  RailpackRuntimeOption(
    id: 'shell',
    label: 'Shell',
    provider: 'shell',
    suggestedPort: 3000,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Use this when the repository is driven by custom shell scripts. '
        'Leave commands blank to start with auto-detected defaults.',
  ),
  RailpackRuntimeOption(
    id: 'staticfile',
    label: 'Static site',
    provider: 'staticfile',
    suggestedPort: 80,
    defaultBuildCommand: '',
    defaultRunCommand: '',
    commandHelperText:
        'Use this for static output. Leave commands blank to enable auto '
        'detection of the publish directory.',
  ),
];

const Set<String> _railpackProviderIds = <String>{
  'node',
  'python',
  'php',
  'ruby',
  'golang',
  'java',
  'rust',
  'dotnet',
  'deno',
  'elixir',
  'shell',
  'staticfile',
};

/// The canonical provider id for [raw], or null when it is not one.
///
/// Trims and lower-cases, so a value read back from an older project row or
/// typed by hand still matches. Null covers both "no provider stored" and
/// "stored a provider this build does not know", which are the same thing to
/// every caller: fall back to auto-detection.
String? normalizeRailpackProvider(String? raw) {
  if (raw == null) {
    return null;
  }
  final normalized = raw.trim().toLowerCase();
  if (_railpackProviderIds.contains(normalized)) {
    return normalized;
  }
  return null;
}

/// The option with [selectionId], or [railpackAutoDetectRuntime].
RailpackRuntimeOption railpackRuntimeForSelection(String selectionId) {
  final normalized = selectionId.trim().toLowerCase();
  for (final option in railpackRuntimeOptions) {
    if (option.id == normalized) {
      return option;
    }
  }
  return railpackAutoDetectRuntime;
}

/// The option for a stored provider, or [railpackAutoDetectRuntime].
RailpackRuntimeOption railpackRuntimeForProvider(String? provider) {
  final normalized = normalizeRailpackProvider(provider);
  if (normalized == null) {
    return railpackAutoDetectRuntime;
  }
  return railpackRuntimeForSelection(normalized);
}

/// Which picker entry to show for a saved project.
///
/// A stored provider answers it outright. When there is none -- a project
/// saved before `railpackProvider` existed -- the commands are inspected, and
/// exactly the Node.js defaults select Node.js. Anything else is
/// auto-detect, including a project that happens to use one of those commands
/// under a different runtime: guessing further would silently pin a provider
/// the user never chose.
String railpackRuntimeSelectionId({
  required String? railpackProvider,
  required String railpackBuildCommand,
  required String railpackRunCommand,
}) {
  final normalizedProvider = normalizeRailpackProvider(railpackProvider);
  if (normalizedProvider != null) {
    return normalizedProvider;
  }
  final buildCommand = railpackBuildCommand.trim();
  final runCommand = railpackRunCommand.trim();
  if (buildCommand == railpackNodeRuntime.defaultBuildCommand &&
      runCommand == railpackNodeRuntime.defaultRunCommand) {
    return railpackNodeRuntime.id;
  }
  return railpackAutoDetectRuntime.id;
}
