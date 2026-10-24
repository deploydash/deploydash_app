import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui/terminal/deploy_timeline_summary.dart';

void main() {
  group('summarizeDeployTimeline', () {
    test(
      'successful deploy reports zero errors even with noisy timeline text',
      () {
        final summary = summarizeDeployTimeline(
          succeeded: true,
          timeline: const [
            'npm warn deprecated glob@10.5.0: old versions are not supported',
            'Publish via Caddy | {"level":"warn","msg":"server is listening only on the HTTP port"}',
            'Run `npm audit` for details.',
            'Deployment completed successfully',
          ],
        );

        expect(summary.warningCount, 2);
        expect(summary.errorCount, 0);
      },
    );

    test('failed deploy still counts error-like timeline lines', () {
      final summary = summarizeDeployTimeline(
        succeeded: false,
        timeline: const [
          'Publish via Caddy | retry 1/8',
          'Failed: Publish app through Caddy over HTTP and HTTPS',
          'Error: executed 5 commands (failed after 8/8 retries)',
        ],
      );

      expect(summary.warningCount, 0);
      expect(summary.errorCount, 2);
    });
  });
}
