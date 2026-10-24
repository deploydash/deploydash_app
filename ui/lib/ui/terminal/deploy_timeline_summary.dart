({int warningCount, int errorCount}) summarizeDeployTimeline({
  required bool succeeded,
  required List<String> timeline,
}) {
  final warningCount = timeline
      .where((line) => line.toLowerCase().contains('warn'))
      .length;
  final errorCount = succeeded
      ? 0
      : timeline.where((line) {
          final normalized = line.toLowerCase();
          return normalized.contains('error') || normalized.contains('failed');
        }).length;

  return (warningCount: warningCount, errorCount: errorCount);
}
