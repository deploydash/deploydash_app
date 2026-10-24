// The six-site HH:MM:SS clock (D-57).
//
// Local-time-in/local-string-out: the owner formats the fields it is given
// and never converts. Every call site passes an already-local DateTime
// (`toLocal()` results, `DateTime.now()`, stored local stamps), so a
// conversion inside would double-convert some sources and assume about the
// rest. The date-padding `_twoDigits` in `ui/system/app_copy.dart` is a
// different contract (zero-padding primitive for dates) and survives
// alongside this owner.

/// `HH:MM:SS` for [value]'s own fields, zero-padded, no conversion.
String formatClockTime(DateTime value) {
  String twoDigits(int raw) => raw.toString().padLeft(2, '0');
  return '${twoDigits(value.hour)}:${twoDigits(value.minute)}:${twoDigits(value.second)}';
}
