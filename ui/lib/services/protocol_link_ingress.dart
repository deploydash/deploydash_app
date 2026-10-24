import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The source of `deploydash://` URIs the operating system hands the app.
///
/// An interface rather than a concrete class so the OAuth flow can be tested
/// without a real protocol registration -- callback handling stays Dart-owned,
/// and this is the only seam it needs.
abstract class ProtocolLinkIngress {
  /// URIs delivered while the app is running.
  Stream<Uri> get links;

  /// The URI that launched the app, if it was launched by one.
  ///
  /// A cold-start OAuth callback arrives this way rather than on [links],
  /// which is why both exist.
  Future<Uri?> getInitialLink();

  /// Stops listening and releases the platform handler.
  void dispose();
}

/// The real ingress, reading from `app_links` and from the native runners.
///
/// Two delivery paths exist because one is not enough. `app_links` handles
/// Linux; on Windows and macOS the runner receives the URI itself and relays
/// it over [nativeProtocolChannel], because those platforms deliver a protocol
/// activation to the already-running process in a way the plugin does not see.
/// Both paths converge here, are de-duplicated, and are queued until something
/// is listening -- a callback that arrives before the app has built its
/// listener must not be dropped, since the user would be left staring at a
/// browser tab that says it worked.
class SystemProtocolLinkIngress implements ProtocolLinkIngress {
  /// The channel the Windows and macOS runners relay protocol URIs over.
  static const nativeProtocolChannel = MethodChannel(
    'com.deploydash.desktop/protocol',
  );

  /// Creates the ingress. Every parameter exists for testing except
  /// [useNativeProtocolRelay], which defaults to the platforms that need it.
  SystemProtocolLinkIngress({
    AppLinks? appLinks,
    Stream<Uri> Function()? liveLinksLoader,
    Future<Uri?> Function()? initialLinkLoader,
    MethodChannel? nativeChannel,
    bool? useNativeProtocolRelay,
  }) : _appLinks = appLinks ?? AppLinks(),
       _liveLinksLoader = liveLinksLoader,
       _initialLinkLoader = initialLinkLoader,
       _nativeChannel = nativeChannel ?? nativeProtocolChannel,
       _useNativeProtocolRelay =
           useNativeProtocolRelay ?? (Platform.isWindows || Platform.isMacOS);

  final AppLinks _appLinks;
  final Stream<Uri> Function()? _liveLinksLoader;
  final Future<Uri?> Function()? _initialLinkLoader;
  final MethodChannel _nativeChannel;
  final bool _useNativeProtocolRelay;
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();
  final List<Uri> _queuedLinks = <Uri>[];
  final List<String> _recentLinkKeys = <String>[];

  StreamSubscription<Uri>? _liveLinksSubscription;
  bool _initialized = false;
  bool _nativeProtocolHandlerReady = false;

  /// URIs from both delivery paths, de-duplicated.
  ///
  /// Listening is what starts the ingress, and it replays anything that
  /// arrived beforehand.
  @override
  Stream<Uri> get links {
    _ensureInitialized();
    return _controller.stream;
  }

  /// The URI the app was launched with, or null.
  @override
  Future<Uri?> getInitialLink() async {
    _ensureInitialized();
    final loader = _initialLinkLoader;
    if (loader != null) {
      return loader();
    }
    return _appLinks.getInitialLink();
  }

  void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _controller.onListen = _flushQueuedLinks;
    final liveLinks = _liveLinksLoader?.call() ?? _appLinks.uriLinkStream;
    _liveLinksSubscription = liveLinks.listen(
      _emitOrQueue,
      onError: _controller.addError,
    );
    if (_useNativeProtocolRelay) {
      _ensureNativeProtocolHandler();
    }
  }

  void _ensureNativeProtocolHandler() {
    if (_nativeProtocolHandlerReady) {
      return;
    }
    _nativeProtocolHandlerReady = true;
    _nativeChannel.setMethodCallHandler((call) async {
      if (call.method != 'deliverProtocolUri') {
        return;
      }
      final rawUri = call.arguments;
      if (rawUri is! String) {
        return;
      }
      final parsedUri = Uri.tryParse(rawUri.trim());
      if (parsedUri != null) {
        _emitOrQueue(parsedUri);
      }
    });
    unawaited(
      _nativeChannel.invokeMethod<void>('protocolIngressReady').catchError((
        Object _,
      ) {
        // Older runners may not implement the readiness handshake yet.
      }),
    );
  }

  void _emitOrQueue(Uri uri) {
    final linkKey = uri.toString();
    if (_recentLinkKeys.contains(linkKey)) {
      return;
    }
    _recentLinkKeys.add(linkKey);
    if (_recentLinkKeys.length > 16) {
      _recentLinkKeys.removeAt(0);
    }
    if (_controller.hasListener) {
      _controller.add(uri);
      return;
    }
    _queuedLinks.add(uri);
  }

  void _flushQueuedLinks() {
    if (!_controller.hasListener || _queuedLinks.isEmpty) {
      return;
    }
    final pending = List<Uri>.from(_queuedLinks);
    _queuedLinks.clear();
    for (final uri in pending) {
      _controller.add(uri);
    }
  }

  /// Cancels the subscription, clears the native handler, and drops anything
  /// still queued.
  @override
  void dispose() {
    _liveLinksSubscription?.cancel();
    if (_nativeProtocolHandlerReady) {
      _nativeChannel.setMethodCallHandler(null);
    }
    _queuedLinks.clear();
    _recentLinkKeys.clear();
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }
}

/// The app-wide ingress, disposed with the container.
final protocolLinkIngressProvider = Provider<ProtocolLinkIngress>((ref) {
  final ingress = SystemProtocolLinkIngress();
  ref.onDispose(ingress.dispose);
  return ingress;
});
