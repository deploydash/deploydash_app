import 'dart:io';

import 'package:ui/data/local/app_data_directory.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('resolveWindowsStoreAppSupportDirectory', () {
    test('resolves Windows Store data under package-managed LocalState', () {
      expect(
        resolveWindowsStoreAppSupportDirectory(
          runsOnWindows: true,
          packageFamilyName: ' TidyTechnology.DeployDash_test ',
          localAppData: r' C:\Users\tester\AppData\Local ',
        ),
        p.join(
          r'C:\Users\tester\AppData\Local',
          'Packages',
          'TidyTechnology.DeployDash_test',
          'LocalState',
          'Deploy Dash',
        ),
      );
      expect(
        resolveWindowsStoreAppSupportDirectory(
          runsOnWindows: false,
          packageFamilyName: 'TidyTechnology.DeployDash_test',
          localAppData: r'C:\Users\tester\AppData\Local',
        ),
        isNull,
      );
    });

    test('throws when Windows Store local app data is missing', () {
      expect(
        () => resolveWindowsStoreAppSupportDirectory(
          runsOnWindows: true,
          packageFamilyName: 'TidyTechnology.DeployDash_test',
          localAppData: ' ',
        ),
        throwsStateError,
      );
    });
  });

  group('resolveAppDataDirectory', () {
    tearDown(debugResetAppDataDirectoryTestState);

    test('uses Windows Store LocalState when package family is set', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-app-data-',
      );
      addTearDown(() async {
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      debugOverrideAppDataDirectoryWindowsCheck(() => true);
      debugOverrideWindowsStoreAppDataEnvironment(
        packageFamilyLoader: () => 'TidyTechnology.DeployDash_test',
        localAppDataLoader: () => tempDirectory.path,
      );

      final directory = await resolveAppDataDirectory();
      expect(
        directory.path,
        p.join(
          tempDirectory.path,
          'Packages',
          'TidyTechnology.DeployDash_test',
          'LocalState',
          'Deploy Dash',
        ),
      );
      expect(await directory.exists(), isTrue);
    });

    test('honors an explicit directory override', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'deploydash-app-data-override-',
      );
      addTearDown(() async {
        if (await tempDirectory.exists()) {
          await tempDirectory.delete(recursive: true);
        }
      });

      debugOverrideAppDataDirectoryResolver(() async => tempDirectory);
      final directory = await resolveAppDataDirectory();
      expect(directory.path, tempDirectory.path);
    });
  });
}
