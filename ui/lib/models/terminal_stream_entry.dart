/// A rendered terminal row and whether it is advanced diagnostic output.
///
/// The shell terminal shows two levels: the narrative a novice follows, and
/// the raw remote output behind it. [isDetail] is what the view filters on, so
/// the distinction has to travel with the row rather than be re-derived from
/// its text.
class TerminalStreamEntry {
  /// Creates a row carrying [message], marked as detail when [isDetail].
  const TerminalStreamEntry(this.message, {this.isDetail = false});

  /// The line as it should appear.
  final String message;

  /// Whether this row belongs to the technical-details reveal rather than the
  /// primary narrative.
  final bool isDetail;
}
