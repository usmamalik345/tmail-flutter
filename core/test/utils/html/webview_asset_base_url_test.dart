import 'package:core/utils/html/webview_asset_base_url.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(WebViewAssetBaseUrl.channelName);
  final binaryMessenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mockNativeResult(dynamic result) {
    binaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, WebViewAssetBaseUrl.flutterAssetsBaseUrlMethod);
      return result;
    });
  }

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    binaryMessenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('WebViewAssetBaseUrl::flutterAssetsBaseUrl', () {
    test('returns null on desktop/web without calling the native channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      var wasCalled = false;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        wasCalled = true;
        return 'file:///should-not-be-used/';
      });

      final result = await WebViewAssetBaseUrl().flutterAssetsBaseUrl();

      expect(result, isNull);
      expect(wasCalled, isFalse);
    });

    test('resolves the base url the native side returns', () async {
      mockNativeResult('file:///var/app/flutter_assets/');

      final result = await WebViewAssetBaseUrl().flutterAssetsBaseUrl();

      expect(result.toString(), 'file:///var/app/flutter_assets/');
    });

    test('resolves the base url the native side returns on iOS', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      mockNativeResult('file:///var/mobile/flutter_assets/');

      final result = await WebViewAssetBaseUrl().flutterAssetsBaseUrl();

      expect(result.toString(), 'file:///var/mobile/flutter_assets/');
    });

    test('caches the resolved url and only calls the native channel once', () async {
      var callCount = 0;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, WebViewAssetBaseUrl.flutterAssetsBaseUrlMethod);
        callCount++;
        return 'file:///var/app/flutter_assets/';
      });
      final webViewAssetBaseUrl = WebViewAssetBaseUrl();

      await webViewAssetBaseUrl.flutterAssetsBaseUrl();
      await webViewAssetBaseUrl.flutterAssetsBaseUrl();

      expect(callCount, 1);
    });

    test('concurrent calls only hit the native channel once', () async {
      var callCount = 0;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, WebViewAssetBaseUrl.flutterAssetsBaseUrlMethod);
        callCount++;
        return 'file:///var/app/flutter_assets/';
      });
      final webViewAssetBaseUrl = WebViewAssetBaseUrl();

      final results = await Future.wait([
        webViewAssetBaseUrl.flutterAssetsBaseUrl(),
        webViewAssetBaseUrl.flutterAssetsBaseUrl(),
      ]);

      expect(callCount, 1);
      expect(results[0].toString(), 'file:///var/app/flutter_assets/');
      expect(results[1].toString(), 'file:///var/app/flutter_assets/');
    });

    test('returns null and does not retry when the native channel throws', () async {
      var callCount = 0;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, WebViewAssetBaseUrl.flutterAssetsBaseUrlMethod);
        callCount++;
        throw PlatformException(code: 'error');
      });
      final webViewAssetBaseUrl = WebViewAssetBaseUrl();

      final first = await webViewAssetBaseUrl.flutterAssetsBaseUrl();
      final second = await webViewAssetBaseUrl.flutterAssetsBaseUrl();

      expect(first, isNull);
      expect(second, isNull);
      expect(callCount, 1);
    });

    test('caches a null result and only calls the native channel once', () async {
      var callCount = 0;
      binaryMessenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, WebViewAssetBaseUrl.flutterAssetsBaseUrlMethod);
        callCount++;
        return null;
      });
      final webViewAssetBaseUrl = WebViewAssetBaseUrl();

      final first = await webViewAssetBaseUrl.flutterAssetsBaseUrl();
      final second = await webViewAssetBaseUrl.flutterAssetsBaseUrl();

      expect(first, isNull);
      expect(second, isNull);
      expect(callCount, 1);
    });
  });
}
