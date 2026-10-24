import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/github_repository.dart';
import '../services/protocol_link_ingress.dart';

/// Everything that talks to github.com over HTTP, and nothing else.
///
/// Split out of `github_integration_provider.dart` by T-3.3.6 along the seam
/// the task names: this file is the OAuth token exchange and the three REST
/// calls (repositories, branches, deploy keys). It holds no application state
/// and knows nothing about deploys, so a fake gateway is all a test of the
/// notifier needs.

abstract class GitHubAuthGateway {
  Future<bool> openAuthorizationUrl(Uri authorizeUrl);
  Stream<Uri> get callbackLinks;
  Future<Uri?> getInitialCallbackLink();
  Future<String> exchangeCodeForToken({
    required String code,
    required String clientId,
    required String redirectUri,
    String? clientSecret,
  });
  Future<List<GitHubRepository>> fetchRepositories({
    required String accessToken,
  });
  Future<List<String>> fetchBranches({
    required String accessToken,
    required String repositoryFullName,
  });
  Future<void> registerDeployKey({
    required String accessToken,
    required String repositoryFullName,
    required String publicKey,
  });
}

class SystemGitHubAuthGateway implements GitHubAuthGateway {
  SystemGitHubAuthGateway({required ProtocolLinkIngress protocolLinkIngress})
    : _protocolLinkIngress = protocolLinkIngress;

  final ProtocolLinkIngress _protocolLinkIngress;

  @override
  Stream<Uri> get callbackLinks => _protocolLinkIngress.links;

  @override
  Future<Uri?> getInitialCallbackLink() =>
      _protocolLinkIngress.getInitialLink();

  @override
  Future<bool> openAuthorizationUrl(Uri authorizeUrl) async {
    return launchUrl(authorizeUrl, mode: LaunchMode.externalApplication);
  }

  @override
  Future<String> exchangeCodeForToken({
    required String code,
    required String clientId,
    required String redirectUri,
    String? clientSecret,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.https('github.com', '/login/oauth/access_token'),
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'DeployDashDesktop/1.0');
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(
        Uri(
          queryParameters: {
            'client_id': clientId,
            'code': code,
            'redirect_uri': redirectUri,
            if (clientSecret != null && clientSecret.isNotEmpty)
              'client_secret': clientSecret,
          },
        ).query,
      );

      final response = await request.close();
      final payload = await _readJsonObject(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          _githubApiErrorMessage(
            fallback: 'GitHub token exchange failed (${response.statusCode}).',
            payload: payload,
          ),
        );
      }

      final accessToken = payload['access_token'];
      if (accessToken is! String || accessToken.isEmpty) {
        throw StateError(
          _githubApiErrorMessage(
            fallback: 'GitHub token exchange returned no access token.',
            payload: payload,
          ),
        );
      }
      return accessToken;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<List<GitHubRepository>> fetchRepositories({
    required String accessToken,
  }) async {
    final client = HttpClient();
    final repositories = <GitHubRepository>[];
    final seenFullNames = <String>{};
    Uri? nextPageUrl = Uri.https('api.github.com', '/user/repos', {
      'per_page': '100',
      'sort': 'updated',
      'affiliation': 'owner,collaborator,organization_member',
    });
    var pageCount = 0;

    try {
      while (nextPageUrl != null && pageCount < 10) {
        pageCount += 1;
        final request = await client.getUrl(nextPageUrl);
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'DeployDashDesktop/1.0',
        );

        final response = await request.close();
        final payload = await _readJson(response);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
            _githubApiErrorMessage(
              fallback:
                  'GitHub repository fetch failed (${response.statusCode}).',
              payload: payload is Map<String, dynamic> ? payload : null,
            ),
          );
        }
        if (payload is! List<dynamic>) {
          throw StateError('GitHub repository response was not a list.');
        }

        for (final repoJson in payload) {
          if (repoJson is! Map<String, dynamic>) {
            continue;
          }
          final fullName = repoJson['full_name'];
          final name = repoJson['name'];
          if (fullName is! String || fullName.isEmpty || name is! String) {
            continue;
          }
          if (seenFullNames.contains(fullName)) {
            continue;
          }
          seenFullNames.add(fullName);

          repositories.add(
            GitHubRepository(
              name: name,
              fullName: fullName,
              isPrivate: repoJson['private'] == true,
            ),
          );
        }

        nextPageUrl = _parseNextPageUri(response.headers.value('link'));
      }
    } finally {
      client.close(force: true);
    }

    repositories.sort(
      (left, right) =>
          left.fullName.toLowerCase().compareTo(right.fullName.toLowerCase()),
    );
    return repositories;
  }

  @override
  Future<List<String>> fetchBranches({
    required String accessToken,
    required String repositoryFullName,
  }) async {
    final normalizedRepository = repositoryFullName.trim();
    final repositoryPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
    if (!repositoryPattern.hasMatch(normalizedRepository)) {
      throw StateError('Invalid repository name: $repositoryFullName');
    }

    final client = HttpClient();
    final branches = <String>{};
    Uri? nextPageUrl = Uri.https(
      'api.github.com',
      '/repos/$normalizedRepository/branches',
      {'per_page': '100'},
    );
    var pageCount = 0;
    try {
      while (nextPageUrl != null && pageCount < 10) {
        pageCount += 1;
        final request = await client.getUrl(nextPageUrl);
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $accessToken',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json',
        );
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'DeployDashDesktop/1.0',
        );

        final response = await request.close();
        final payload = await _readJson(response);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError(
            _githubApiErrorMessage(
              fallback: 'GitHub branch fetch failed (${response.statusCode}).',
              payload: payload is Map<String, dynamic> ? payload : null,
            ),
          );
        }
        if (payload is! List<dynamic>) {
          throw StateError('GitHub branch response was not a list.');
        }
        for (final branchJson in payload) {
          if (branchJson is! Map<String, dynamic>) {
            continue;
          }
          final name = branchJson['name'];
          if (name is String && name.trim().isNotEmpty) {
            branches.add(name.trim());
          }
        }
        nextPageUrl = _parseNextPageUri(response.headers.value('link'));
      }
    } finally {
      client.close(force: true);
    }

    final sorted = branches.toList(
      growable: false,
    )..sort((left, right) => left.toLowerCase().compareTo(right.toLowerCase()));
    return sorted;
  }

  @override
  Future<void> registerDeployKey({
    required String accessToken,
    required String repositoryFullName,
    required String publicKey,
  }) async {
    final normalizedPublicKey = publicKey.trim();
    if (!_looksLikeSshPublicKey(normalizedPublicKey)) {
      throw StateError(
        'Deploy key payload is invalid. Expected an OpenSSH public key.',
      );
    }

    final normalizedRepository = repositoryFullName.trim();
    final repositoryPattern = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');
    if (!repositoryPattern.hasMatch(normalizedRepository)) {
      throw StateError('Invalid repository name: $repositoryFullName');
    }

    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.https('api.github.com', '/repos/$normalizedRepository/keys'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $accessToken',
      );
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'DeployDashDesktop/1.0');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({
          'title':
              'deploydash-${normalizedRepository.replaceAll('/', '-')}-${DateTime.now().millisecondsSinceEpoch}',
          'key': normalizedPublicKey,
          'read_only': true,
        }),
      );

      final response = await request.close();
      final payload = await _readJson(response);
      if (response.statusCode == 201) {
        return;
      }
      if (response.statusCode == 422 && _isDuplicateDeployKeyError(payload)) {
        return;
      }
      throw StateError(
        _githubApiErrorMessage(
          fallback:
              'GitHub deploy key registration failed (${response.statusCode}).',
          payload: payload is Map<String, dynamic> ? payload : null,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  static bool _looksLikeSshPublicKey(String value) {
    if (value.isEmpty || value.contains('\n') || value.contains('\r')) {
      return false;
    }
    final parts = value.split(RegExp(r'\s+'));
    if (parts.length < 2) {
      return false;
    }
    const allowedAlgorithms = <String>{
      'ssh-ed25519',
      'ssh-rsa',
      'ecdsa-sha2-nistp256',
      'ecdsa-sha2-nistp384',
      'ecdsa-sha2-nistp521',
    };
    final algorithm = parts[0].trim();
    if (!allowedAlgorithms.contains(algorithm)) {
      return false;
    }

    final encoded = parts[1].trim();
    if (!RegExp(r'^[A-Za-z0-9+/]+={0,3}$').hasMatch(encoded)) {
      return false;
    }
    final padded = _padBase64(encoded);
    if (padded == null) {
      return false;
    }
    try {
      return base64Decode(padded).isNotEmpty;
    } on FormatException {
      return false;
    }
  }

  static String? _padBase64(String value) {
    final remainder = value.length % 4;
    if (remainder == 0) {
      return value;
    }
    if (remainder == 2) {
      return '$value==';
    }
    if (remainder == 3) {
      return '$value=';
    }
    return null;
  }

  // Transport decoders (HttpClientResponse input, StateError errors) — the D-26
  // fold-in is declined: input/error contracts differ (D-45 pair 2, T-021).
  static Future<dynamic> _readJson(HttpClientResponse response) async {
    final body = await response.transform(utf8.decoder).join();
    if (body.isEmpty) {
      return null;
    }
    return jsonDecode(body);
  }

  static Future<Map<String, dynamic>> _readJsonObject(
    HttpClientResponse response,
  ) async {
    final payload = await _readJson(response);
    if (payload is! Map<String, dynamic>) {
      throw StateError('GitHub API returned an unexpected response.');
    }
    return payload;
  }

  static Uri? _parseNextPageUri(String? linkHeader) {
    if (linkHeader == null || linkHeader.isEmpty) {
      return null;
    }
    final segments = linkHeader.split(',');
    for (final segment in segments) {
      final trimmed = segment.trim();
      if (!trimmed.contains('rel="next"')) {
        continue;
      }
      final start = trimmed.indexOf('<');
      final end = trimmed.indexOf('>');
      if (start == -1 || end <= start + 1) {
        continue;
      }
      return Uri.tryParse(trimmed.substring(start + 1, end));
    }
    return null;
  }

  static String _githubApiErrorMessage({
    required String fallback,
    Map<String, dynamic>? payload,
  }) {
    if (payload == null) {
      return fallback;
    }
    final description = payload['error_description'];
    if (description is String && description.isNotEmpty) {
      return description;
    }
    final message = payload['message'];
    if (message is String && message.isNotEmpty) {
      return message;
    }
    final error = payload['error'];
    if (error is String && error.isNotEmpty) {
      return error;
    }
    return fallback;
  }

  static bool _isDuplicateDeployKeyError(dynamic payload) {
    if (payload is! Map<String, dynamic>) {
      return false;
    }

    final message = payload['message'];
    if (message is String &&
        message.toLowerCase().contains('key is already in use')) {
      return true;
    }

    final errors = payload['errors'];
    if (errors is! List<dynamic>) {
      return false;
    }

    for (final error in errors) {
      if (error is! Map<String, dynamic>) {
        continue;
      }
      final errorMessage = error['message'];
      if (errorMessage is String &&
          errorMessage.toLowerCase().contains('key is already in use')) {
        return true;
      }
    }
    return false;
  }
}

final gitHubAuthGatewayProvider = Provider<GitHubAuthGateway>(
  (ref) => SystemGitHubAuthGateway(
    protocolLinkIngress: ref.read(protocolLinkIngressProvider),
  ),
);

final gitHubInteractionStepDelayProvider = Provider<Duration>(
  (ref) => const Duration(milliseconds: 350),
);
