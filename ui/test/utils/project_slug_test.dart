import 'package:ui/utils/project_slug.dart';
import 'package:flutter_test/flutter_test.dart';

// Characterization for D-26 (T-011): nine hand-rolled slug helpers converge
// onto [slugifyProjectName], differing only in the fallback each site passes
// explicitly. This table pins every site's fallback plus the shared
// transform, so each routed call's value is fixed before its def is deleted.
void main() {
  test('slug transform trims, lowers, dashes, and strips edges', () {
    expect(slugifyProjectName('  Blog API  '), 'blog-api');
    expect(slugifyProjectName('Regs v3'), 'regs-v3');
    expect(slugifyProjectName('--Padded--'), 'padded');
    expect(slugifyProjectName('a  b'), 'a-b');
  });

  test('every D-26 site fallback survives the convergence', () {
    const fallbacksBySite = <String, String>{
      'deletion coordinator': 'project-app',
      'app deployment models': 'project-app',
      'github provider': 'project-app',
      'app deployment payloads': 'project-app',
      'sqlite names': 'db',
      'database tab': 'project-db',
      'workers tab': 'project-workers',
      'scheduler tab': 'project-scheduler',
      'backup payloads': 'project-backups',
    };
    for (final entry in fallbacksBySite.entries) {
      // A name that normalizes to empty yields the site's fallback, and a
      // normal name yields the shared transform regardless of fallback.
      expect(
        slugifyProjectName('***', fallback: entry.value),
        entry.value,
        reason: '${entry.key} fallback lost.',
      );
      expect(
        slugifyProjectName('Blog API', fallback: entry.value),
        'blog-api',
        reason: '${entry.key} transform diverged.',
      );
    }
  });

  test('default fallback stays project-app', () {
    expect(slugifyProjectName('***'), 'project-app');
  });
}
