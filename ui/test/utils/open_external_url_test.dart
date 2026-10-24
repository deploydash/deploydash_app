import 'package:ui/utils/open_external_url.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

// Characterization for D-43 (T-013, commit 3): the scheme-guarded external
// opener. O1 already guarded https|http; O2 (the GitHub authorization-link
// button) only null-checked — a non-http(s) URL launched today. Routing O2
// through this owner deliberately stops that: only http(s) ever launches.
// (Deliberate hardening, recorded per the ticket — not the enforceScheme
// fallback: the authorization URL is always https in practice, and a
// javascript: URL must never reach the OS opener from this button.)
void main() {
  test('launches http and https URLs externally', () async {
    final launcher = _RecordingLauncher();
    UrlLauncherPlatform.instance = launcher;

    await openExternalUrl('https://github.com/login/oauth/authorize?x=1');
    expect(launcher.launchedUrls, [
      'https://github.com/login/oauth/authorize?x=1',
    ]);

    await openExternalUrl('http://insecure.local/setup');
    expect(launcher.launchedUrls, hasLength(2));
  });

  test('ignores non-http(s) URLs', () async {
    final launcher = _RecordingLauncher();
    UrlLauncherPlatform.instance = launcher;

    await openExternalUrl('javascript:alert(1)');
    await openExternalUrl('file:///etc/passwd');
    expect(launcher.launchedUrls, isEmpty);
  });

  test('ignores unparseable URLs', () async {
    final launcher = _RecordingLauncher();
    UrlLauncherPlatform.instance = launcher;

    await openExternalUrl(':::');
    expect(launcher.launchedUrls, isEmpty);
  });
}

class _RecordingLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final launchedUrls = <String>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launchedUrls.add(url);
    return true;
  }
}
