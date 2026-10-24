import 'dart:io';

String normalizeHostInput(String value) {
  final trimmed = value.trim();
  if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
    final inner = trimmed.substring(1, trimmed.length - 1).trim();
    return inner.isEmpty ? trimmed : inner;
  }
  return trimmed;
}

bool isValidHostInput(String value) {
  final host = normalizeHostInput(value);
  if (host.isEmpty) {
    return false;
  }

  if (InternetAddress.tryParse(host) != null) {
    return true;
  }

  final hostnamePattern = RegExp(
    r'^(?=.{1,253}$)(?!-)([a-zA-Z0-9-]{1,63}\.)*[a-zA-Z0-9-]{1,63}$',
  );
  return hostnamePattern.hasMatch(host);
}

String? validateHostOrAddress(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Server host or address is required';
  }
  if (!isValidHostInput(value)) {
    return 'Enter a valid host, IPv4 address, or IPv6 address';
  }
  return null;
}

/// Whether [value] is an IPv6 address literal.
bool isIpv6Literal(String value) {
  final host = normalizeHostInput(value);
  if (host.isEmpty) {
    return false;
  }
  return InternetAddress.tryParse(host)?.type == InternetAddressType.IPv6;
}

/// [value] as it should be shown or embedded in a URI.
///
/// An IPv6 literal is bracketed, per RFC 3986; anything else is returned
/// trimmed. One owner: this existed three times over, as
/// `_formatHostForWorkspace` in `ui/project/project_workspace.dart`, as
/// `_formatHostForGitHubProvider` in `providers/github_integration_provider.dart`,
/// and inline in [formatHostPort] below — the two named copies byte-identical
/// apart from the file they were named after, which is what
/// "whoever added the second one could not see the first" looks like in
/// practice. `utils/` is importable by every layer, so this is where it goes.
String formatHostForDisplay(String value) {
  final host = normalizeHostInput(value);
  return isIpv6Literal(host) ? '[$host]' : host;
}

String formatHostPort(String host, int port) {
  return '${formatHostForDisplay(host)}:$port';
}
