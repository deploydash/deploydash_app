/// Returns [map] with every key stringified, values untouched.
///
/// The single owner of the entry-lambda stringify shape for the desktop app.
/// Three hand-rolled `(key, value) => MapEntry(...)` lambdas in
/// `app_deployment_runtime_methods.dart` preceded it (D-43) in two spellings
/// (`key.toString()` and `'$key'`) — which is why it is a top-level function
/// in `utils/` rather than a static on whichever class happened to need it
/// first: a helper that can only be reached through one class is a helper
/// the next class will rewrite.
///
/// Uses the `'$key'` spelling. A null key yields `'null'` — the same value
/// `key.toString()` produced, since Dart's `Null.toString()` is `'null'` —
/// so converging the two spellings changes no behavior on any edge. (This
/// differs from T-014's codec owner in arity: that one takes whole maps for
/// its own sites; this one folds entry-lambdas.)
Map<String, dynamic> stringifyJsonKeys(Map<dynamic, dynamic> map) {
  return map.map((key, value) => MapEntry('$key', value));
}
