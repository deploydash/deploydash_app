import 'package:ui/ui/project/workspace/scheduler/scheduler_tab_logic.dart';
import 'package:ui/providers/scheduler_task_provider.dart';
import 'package:ui/utils/project_slug.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scheduler slugs normalize names and fall back', () {
    // D-26 (T-011): schedulerSlugifyProjectName folded into the owner; same
    // values asserted through slugifyProjectName with the explicit site
    // fallback.
    expect(
      slugifyProjectName('Alpha App', fallback: 'project-scheduler'),
      'alpha-app',
    );
    expect(
      slugifyProjectName('   ', fallback: 'project-scheduler'),
      'project-scheduler',
    );
  });

  test('schedulerNextTaskId avoids collisions', () {
    final existing = <ProjectScheduledTask>[
      const ProjectScheduledTask(
        id: 'nightly-backup',
        projectId: 'project-1',
        name: 'Nightly backup',
        targetType: 'project',
        command: 'backup',
        scheduleType: 'daily_at',
      ),
      const ProjectScheduledTask(
        id: 'nightly-backup-2',
        projectId: 'project-1',
        name: 'Nightly backup duplicate',
        targetType: 'project',
        command: 'backup',
        scheduleType: 'daily_at',
      ),
    ];

    expect(schedulerNextTaskId('Nightly backup', existing), 'nightly-backup-3');
    expect(schedulerNextTaskId('   ', existing), 'task');
  });

  test('schedulerParseIsoDate parses strings and rejects invalid values', () {
    expect(schedulerParseIsoDate(null), isNull);
    expect(schedulerParseIsoDate(' '), isNull);
    expect(schedulerParseIsoDate('not-a-date'), isNull);
    expect(schedulerParseIsoDate('2026-04-19T09:30:00Z'), isA<DateTime>());
  });

  test('schedulerScheduleSummary covers supported schedule types', () {
    const everyMinutes = ProjectScheduledTask(
      id: 'task-1',
      projectId: 'project-1',
      name: 'Every five minutes',
      targetType: 'project',
      command: 'backup',
      scheduleType: 'every_minutes',
      intervalValue: 5,
    );
    const everyHours = ProjectScheduledTask(
      id: 'task-2',
      projectId: 'project-1',
      name: 'Every hour',
      targetType: 'project',
      command: 'backup',
      scheduleType: 'every_hours',
      intervalValue: 1,
    );
    const daily = ProjectScheduledTask(
      id: 'task-3',
      projectId: 'project-1',
      name: 'Nightly',
      targetType: 'project',
      command: 'backup',
      scheduleType: 'daily_at',
      dailyTime: '03:00',
    );
    const custom = ProjectScheduledTask(
      id: 'task-4',
      projectId: 'project-1',
      name: 'Custom',
      targetType: 'project',
      command: 'backup',
      scheduleType: 'unknown',
    );

    expect(schedulerScheduleSummary(everyMinutes), 'Every 5 minutes');
    expect(schedulerScheduleSummary(everyHours), 'Every 1 hour');
    expect(schedulerScheduleSummary(daily), 'Daily at 03:00');
    expect(schedulerScheduleSummary(custom), 'Custom schedule');
  });
}
