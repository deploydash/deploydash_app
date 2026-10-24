import 'deploy_failure_evidence.dart';

/// The outcome of an operation that can fail with a typed [AppFailure],
/// instead of throwing or returning `null` on failure.
sealed class Result<T> {
  const Result();
}

/// A successful outcome carrying the produced [value].
final class Ok<T> extends Result<T> {
  /// Wraps a produced value as a success.
  const Ok(this.value);

  /// What the operation produced.
  final T value;

  @override
  bool operator ==(Object other) => other is Ok<T> && other.value == value;

  @override
  int get hashCode => Object.hash(Ok, value);

  @override
  String toString() => 'Ok($value)';
}

/// A failed outcome carrying the typed [failure].
final class Err<T> extends Result<T> {
  /// Wraps a typed failure as a failed outcome.
  ///
  /// [T] is unconstrained by the failure, so an `Err` can be returned from
  /// any operation without inventing a value to fail with.
  const Err(this.failure);

  /// Why the operation did not produce a value.
  final AppFailure failure;

  @override
  bool operator ==(Object other) => other is Err<T> && other.failure == failure;

  @override
  int get hashCode => Object.hash(Err, failure);

  @override
  String toString() => 'Err($failure)';
}

/// Typed failure modes surfaced to the UI. [CancelledFailure] is
/// deliberately distinct from every other kind so a caller can never render
/// a user-initiated cancellation as an error -- see
/// `OperationQueueCancelledException` in `services/concurrency_engine.dart`,
/// which this type distinguishes from.
sealed class AppFailure {
  const AppFailure();
}

/// The backend engine returned a structured error envelope
/// (`{"status": "error", "code": ..., "msg": ..., "stage": ..., "details": ...}`).
/// See `docs/contracts/engine-protocol.md`.
final class EngineFailure extends AppFailure {
  /// Wraps the fields of one engine error envelope.
  ///
  /// Build these with `mapEngineErrorToFailure` rather than by hand: it is
  /// the one place that knows which codes mean cancellation.
  const EngineFailure({
    required this.code,
    required this.msg,
    this.stage,
    this.details,
    this.failureEvidence,
    this.context = const <String, dynamic>{},
  });

  /// The engine's error code, e.g. `ENGINE_VALIDATION_ERROR`.
  final String code;

  /// The engine's human-readable message.
  final String msg;

  /// Which stage of request handling failed, if the engine reported one.
  final String? stage;

  /// Additional technical detail, if the engine reported any.
  final String? details;

  /// Typed, bounded evidence associated with the failed deployment operation.
  final DeployFailureEvidence? failureEvidence;

  /// Structured operation context outside the standard error envelope fields.
  ///
  /// Some recoverable engine failures carry a next-action contract, such as
  /// the fingerprints required to confirm a changed SSH host key. Keeping
  /// that context on the typed failure preserves the contract without asking
  /// callers to retain and reparse the raw engine envelope.
  final Map<String, dynamic> context;

  @override
  bool operator ==(Object other) =>
      other is EngineFailure &&
      other.code == code &&
      other.msg == msg &&
      other.stage == stage &&
      other.details == details &&
      other.failureEvidence == failureEvidence;

  @override
  int get hashCode =>
      Object.hash(EngineFailure, code, msg, stage, details, failureEvidence);

  @override
  String toString() =>
      'EngineFailure(code: $code, msg: $msg, stage: $stage, details: $details)';
}

/// The connection to the managed server could not be established or was
/// lost (SSH connect/auth failure, timeout, network unreachable).
final class ConnectionFailure extends AppFailure {
  /// Records that the server could not be reached, and what went wrong.
  const ConnectionFailure(this.message);

  /// What prevented the connection, in the transport's own words.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is ConnectionFailure && other.message == message;

  @override
  int get hashCode => Object.hash(ConnectionFailure, message);

  @override
  String toString() => 'ConnectionFailure($message)';
}

/// User-supplied input failed local validation before any request was sent.
final class ValidationFailure extends AppFailure {
  /// Records input rejected locally, with the sentence to show the user.
  const ValidationFailure(this.message);

  /// What is wrong with the input, written for the person who typed it --
  /// nothing left the app, so there is no backend wording to defer to.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is ValidationFailure && other.message == message;

  @override
  int get hashCode => Object.hash(ValidationFailure, message);

  @override
  String toString() => 'ValidationFailure($message)';
}

/// Reading or writing the local encrypted app database failed.
final class LocalStorageFailure extends AppFailure {
  /// Records a failed read or write of the encrypted local database.
  const LocalStorageFailure(this.message);

  /// What the database layer reported.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is LocalStorageFailure && other.message == message;

  @override
  int get hashCode => Object.hash(LocalStorageFailure, message);

  @override
  String toString() => 'LocalStorageFailure($message)';
}

/// The operation was cancelled by the user or the concurrency engine.
/// Distinct from every other failure kind: the UI must never show this as
/// an error.
final class CancelledFailure extends AppFailure {
  /// The one cancellation value; it carries no detail because there is none
  /// worth showing.
  const CancelledFailure();

  @override
  bool operator ==(Object other) => other is CancelledFailure;

  @override
  int get hashCode => (CancelledFailure).hashCode;

  @override
  String toString() => 'CancelledFailure()';
}

/// An error that does not fit any of the above -- an unexpected exception
/// caught at a boundary. Preserves the original error and stack trace for
/// technical details rather than discarding them.
final class UnexpectedFailure extends AppFailure {
  /// Captures an error that reached a boundary without a typed shape.
  ///
  /// Not `const`, unlike every sibling: a caught error and stack trace are
  /// runtime values.
  UnexpectedFailure(this.error, [this.stackTrace]);

  /// The caught error, kept whole rather than stringified at the catch site.
  final Object error;

  /// Where it was thrown, when the catch site had one to pass on.
  final StackTrace? stackTrace;

  @override
  bool operator ==(Object other) =>
      other is UnexpectedFailure && other.error == error;

  @override
  int get hashCode => Object.hash(UnexpectedFailure, error);

  @override
  String toString() => 'UnexpectedFailure($error)';
}

/// Adapts a typed engine operation outcome for legacy detail views which still
/// render the established success-payload shape. Error payloads are rebuilt
/// from [AppFailure], never passed through from the native engine boundary.
///
/// This is deliberately a presentation adapter: it lets old views preserve
/// actionable details such as an SSH host-key confirmation while the service
/// boundary and its callers exchange typed [Result] values.
extension EngineOperationResultDiagnostics on Result<Map<String, dynamic>> {
  /// This result as the engine-envelope-shaped map legacy views expect.
  ///
  /// An [Ok] passes its value through unchanged. An [Err] is *rebuilt* into
  /// an envelope from the typed failure -- each failure kind maps to a fixed
  /// `code`, and only [EngineFailure] contributes a code the engine itself
  /// chose. Nothing crosses back from the native boundary untyped.
  Map<String, dynamic> get diagnosticPayload => switch (this) {
    Ok<Map<String, dynamic>>(:final value) => value,
    Err<Map<String, dynamic>>(:final failure) => _diagnosticPayload(failure),
  };
}

Map<String, dynamic> _diagnosticPayload(AppFailure failure) {
  return switch (failure) {
    EngineFailure(
      :final code,
      :final msg,
      :final stage,
      :final details,
      :final failureEvidence,
      :final context,
    ) =>
      <String, dynamic>{
        'status': 'error',
        'code': code,
        'msg': msg,
        ...?(stage == null ? null : <String, dynamic>{'stage': stage}),
        ...?(details == null ? null : <String, dynamic>{'details': details}),
        ...DeployFailureEvidence.envelopeMember(failureEvidence),
        ...context,
      },
    CancelledFailure() => const <String, dynamic>{
      'status': 'error',
      'code': 'ENGINE_TASK_CANCELLED',
      'msg': 'Operation was cancelled.',
    },
    ConnectionFailure(:final message) => <String, dynamic>{
      'status': 'error',
      'code': 'ENGINE_CONNECTION_FAILED',
      'msg': message,
    },
    ValidationFailure(:final message) => <String, dynamic>{
      'status': 'error',
      'code': 'ENGINE_CLIENT_VALIDATION_ERROR',
      'msg': message,
    },
    LocalStorageFailure(:final message) => <String, dynamic>{
      'status': 'error',
      'code': 'ENGINE_LOCAL_STORAGE_ERROR',
      'msg': message,
    },
    UnexpectedFailure(:final error) => <String, dynamic>{
      'status': 'error',
      'code': 'ENGINE_CLIENT_UNEXPECTED_ERROR',
      'msg': error.toString(),
    },
  };
}
