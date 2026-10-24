import 'package:ui/utils/host_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeHostInput', () {
    test('trims whitespace and removes non-empty ipv6 brackets', () {
      expect(normalizeHostInput('  [2001:db8::1]  '), '2001:db8::1');
    });

    test('preserves empty bracket literal when inner value is blank', () {
      expect(normalizeHostInput(' [ ] '), '[ ]');
    });
  });

  group('isValidHostInput', () {
    test('accepts ipv4, ipv6, and hostnames', () {
      expect(isValidHostInput('203.0.113.10'), isTrue);
      expect(isValidHostInput('[2001:db8::10]'), isTrue);
      expect(isValidHostInput('api.example.com'), isTrue);
    });

    test('rejects blank and malformed hostnames', () {
      expect(isValidHostInput(''), isFalse);
      expect(isValidHostInput('bad host'), isFalse);
      expect(isValidHostInput('-bad.example.com'), isFalse);
    });
  });

  group('validateHostOrAddress', () {
    test('returns required message for empty input', () {
      expect(
        validateHostOrAddress('   '),
        'Server host or address is required',
      );
    });

    test('returns invalid message for malformed host', () {
      expect(
        validateHostOrAddress('bad host'),
        'Enter a valid host, IPv4 address, or IPv6 address',
      );
    });

    test('returns null for valid input', () {
      expect(validateHostOrAddress('app.example.com'), isNull);
    });
  });

  group('formatHostPort', () {
    test('wraps normalized ipv6 addresses in brackets', () {
      expect(formatHostPort(' [2001:db8::1] ', 2222), '[2001:db8::1]:2222');
    });

    test('leaves hostnames unchanged', () {
      expect(formatHostPort('app.example.com', 443), 'app.example.com:443');
    });
  });

  group('formatHostForDisplay', () {
    // The one owner of "bracket an IPv6 literal", which used to exist three
    // times: here inline, as `_formatHostForWorkspace`, and as
    // `_formatHostForGitHubProvider` — the last of which nothing called
    // except its own `@visibleForTesting` alias. These cases come from that
    // deleted test, so its coverage moved rather than went away.
    test('brackets a bare ipv6 literal', () {
      expect(formatHostForDisplay('2001:db8::10'), '[2001:db8::10]');
    });

    test('brackets an ipv6 literal with surrounding whitespace', () {
      expect(formatHostForDisplay(' 2001:db8::10 '), '[2001:db8::10]');
    });

    test('does not double-bracket one that already is', () {
      expect(formatHostForDisplay('[2001:db8::10]'), '[2001:db8::10]');
    });

    test('leaves an ipv4 address and a hostname alone', () {
      expect(formatHostForDisplay('203.0.113.10'), '203.0.113.10');
      expect(formatHostForDisplay(' app.example.com '), 'app.example.com');
    });

    test('an empty host stays empty rather than becoming brackets', () {
      expect(formatHostForDisplay('   '), '');
      expect(isIpv6Literal('   '), isFalse);
    });
  });
}
