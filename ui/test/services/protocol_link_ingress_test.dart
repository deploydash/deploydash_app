import 'dart:async';

import 'package:ui/services/protocol_link_ingress.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();
  const windowsChannel = MethodChannel('com.deploydash.desktop/protocol');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowsChannel, null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(windowsChannel, null);
  });

  test('queues live callback URIs until a listener attaches', () async {
    final liveLinks = StreamController<Uri>.broadcast();
    final ingress = SystemProtocolLinkIngress(
      liveLinksLoader: () => liveLinks.stream,
      initialLinkLoader: () async => null,
      useNativeProtocolRelay: false,
    );
    addTearDown(() async {
      ingress.dispose();
      await liveLinks.close();
    });

    ingress.links;
    liveLinks.add(Uri.parse('deploydash://callback?code=queued'));
    await pumpEventQueue();

    final received = <Uri>[];
    final subscription = ingress.links.listen(received.add);
    addTearDown(subscription.cancel);
    await pumpEventQueue();

    expect(received.map((uri) => uri.toString()), [
      'deploydash://callback?code=queued',
    ]);
  });

  test('returns the initial link from the injected loader', () async {
    final expected = Uri.parse('deploydash://callback?code=initial');
    final ingress = SystemProtocolLinkIngress(
      liveLinksLoader: () => const Stream<Uri>.empty(),
      initialLinkLoader: () async => expected,
      useNativeProtocolRelay: false,
    );
    addTearDown(ingress.dispose);

    final result = await ingress.getInitialLink();

    expect(result, expected);
  });

  test(
    'registers native ingress readiness and delivers relayed URIs',
    () async {
      final methodCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(windowsChannel, (call) async {
            methodCalls.add(call);
            return null;
          });

      final ingress = SystemProtocolLinkIngress(
        liveLinksLoader: () => const Stream<Uri>.empty(),
        initialLinkLoader: () async => null,
        nativeChannel: windowsChannel,
        useNativeProtocolRelay: true,
      );
      addTearDown(ingress.dispose);

      final received = <Uri>[];
      final subscription = ingress.links.listen(received.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      expect(
        methodCalls.map((call) => call.method),
        contains('protocolIngressReady'),
      );

      final payload = codec.encodeMethodCall(
        const MethodCall(
          'deliverProtocolUri',
          'deploydash://callback?code=relayed&state=abc',
        ),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(windowsChannel.name, payload, (_) {});
      await pumpEventQueue();

      expect(received.map((uri) => uri.toString()), [
        'deploydash://callback?code=relayed&state=abc',
      ]);
    },
  );

  test(
    'suppresses duplicate URIs from native relay and live link stream',
    () async {
      final liveLinks = StreamController<Uri>.broadcast();
      final ingress = SystemProtocolLinkIngress(
        liveLinksLoader: () => liveLinks.stream,
        initialLinkLoader: () async => null,
        nativeChannel: windowsChannel,
        useNativeProtocolRelay: true,
      );
      addTearDown(() async {
        ingress.dispose();
        await liveLinks.close();
      });

      final received = <Uri>[];
      final subscription = ingress.links.listen(received.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      final duplicate = Uri.parse('deploydash://callback?code=dup&state=abc');
      final payload = codec.encodeMethodCall(
        MethodCall('deliverProtocolUri', duplicate.toString()),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(windowsChannel.name, payload, (_) {});
      liveLinks.add(duplicate);
      await pumpEventQueue();

      expect(received.map((uri) => uri.toString()), [duplicate.toString()]);
    },
  );
}
