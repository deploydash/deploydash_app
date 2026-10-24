import '../../../../providers/scheduler_task_provider.dart';

String schedulerNextTaskId(
  String name,
  Iterable<ProjectScheduledTask> existing,
) {
  final base = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final candidateBase = base.isEmpty ? 'task' : base;
  final existingIds = existing.map((task) => task.id).toSet();
  var candidate = candidateBase;
  var counter = 2;
  while (existingIds.contains(candidate)) {
    candidate = '$candidateBase-$counter';
    counter += 1;
  }
  return candidate;
}

DateTime? schedulerParseIsoDate(dynamic value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(value.trim())?.toLocal();
}

String schedulerScheduleSummary(ProjectScheduledTask task) {
  switch (task.scheduleType) {
    case 'every_minutes':
      final value = task.intervalValue ?? 5;
      return 'Every $value minute${value == 1 ? '' : 's'}';
    case 'every_hours':
      final value = task.intervalValue ?? 1;
      return 'Every $value hour${value == 1 ? '' : 's'}';
    case 'daily_at':
      return 'Daily at ${task.dailyTime ?? '02:00'}';
    default:
      return 'Custom schedule';
  }
}
