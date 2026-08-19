import 'package:core/utils/html/webview_asset_base_url.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
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

  List<int> mockCountingHandler({dynamic result, Object? error}) {
    final callCount = [0];
    binaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, WebViewAssetBaseUrl.flutterAssetsBaseUrlMethod);
      callCount[0]++;
      if (error != null) throw error;
      return result;
    });
    return callCount;
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
      final callCount = mockCountingHandler(result: 'file:///var/app/flutter_assets/');
      final webViewAssetBaseUrl = WebViewAssetBaseUrl();

      await webViewAssetBaseUrl.flutterAssetsBaseUrl();
      await webViewAssetBaseUrl.flutterAssetsBaseUrl();

      expect(callCount[0], 1);
    });

    test('concurrent calls only hit the native channel once', () async {
      final callCount = mockCountingHandler(result: 'file:///var/app/flutter_assets/');
      final webViewAssetBaseUrl = WebViewAssetBaseUrl();

      final results = await Future.wait([
        webViewAssetBaseUrl.flutterAssetsBaseUrl(),
        webViewAssetBaseUrl.flutterAssetsBaseUrl(),
      ]);

      expect(callCount[0], 1);
      expect(results[0].toString(), 'file:///var/app/flutter_assets/');
      expect(results[1].toString(), 'file:///var/app/flutter_assets/');
    });

    test('returns null and does not retry when the native channel throws', () async {
      final callCount = mockCountingHandler(error: PlatformException(code: 'error'));
      final webViewAssetBaseUrl = WebViewAssetBaseUrl();

      final first = await webViewAssetBaseUrl.flutterAssetsBaseUrl();
      final second = await webViewAssetBaseUrl.flutterAssetsBaseUrl();

      expect(first, isNull);
      expect(second, isNull);
      expect(callCount[0], 1);
    });

    test('caches a null result and only calls the native channel once', () async {
      final callCount = mockCountingHandler(result: null);
      final webViewAssetBaseUrl = WebViewAssetBaseUrl();

      final first = await webViewAssetBaseUrl.flutterAssetsBaseUrl();
      final second = await webViewAssetBaseUrl.flutterAssetsBaseUrl();

      expect(first, isNull);
      expect(second, isNull);
      expect(callCount[0], 1);
    });
  });

  group('isProgrammaticDocumentLoad', () {
    NavigationAction navigationActionFor(
      String? url, {
      bool isForMainFrame = true,
      bool? hasGesture,
    }) {
      return NavigationAction(
        isForMainFrame: isForMainFrame,
        hasGesture: hasGesture,
        request: URLRequest(url: url != null ? WebUri(url) : null),
      );
    }

    test('allows about:blank regardless of baseUrl', () {
      final action = navigationActionFor('about:blank');

      expect(isProgrammaticDocumentLoad(action, null), isTrue);
    });

    test('allows an exact match with the cached base url', () {
      final baseUrl = WebUri('file:///var/app/flutter_assets/');
      final action = navigationActionFor('file:///var/app/flutter_assets/');

      expect(isProgrammaticDocumentLoad(action, baseUrl), isTrue);
    });

    test('allows when iOS reports /private/var/ but the cached url uses /var/', () {
      final baseUrl = WebUri('file:///var/mobile/flutter_assets/');
      final action = navigationActionFor('file:///private/var/mobile/flutter_assets/');

      expect(isProgrammaticDocumentLoad(action, baseUrl), isTrue);
    });

    test('allows a trailing-slash mismatch', () {
      final baseUrl = WebUri('file:///var/app/flutter_assets/');
      final action = navigationActionFor('file:///var/app/flutter_assets');

      expect(isProgrammaticDocumentLoad(action, baseUrl), isTrue);
    });

    test('denies a non-file scheme', () {
      final baseUrl = WebUri('file:///var/app/flutter_assets/');
      final action = navigationActionFor('https://example.com');

      expect(isProgrammaticDocumentLoad(action, baseUrl), isFalse);
    });

    test('denies a matching path when the navigation has a user gesture', () {
      final baseUrl = WebUri('file:///var/app/flutter_assets/');
      final action = navigationActionFor(
        'file:///var/app/flutter_assets/',
        hasGesture: true,
      );

      expect(isProgrammaticDocumentLoad(action, baseUrl), isFalse);
    });

    test('denies an unrelated file path', () {
      final baseUrl = WebUri('file:///var/app/flutter_assets/');
      final action = navigationActionFor('file:///var/app/other/');

      expect(isProgrammaticDocumentLoad(action, baseUrl), isFalse);
    });

    test('denies when not for the main frame', () {
      final baseUrl = WebUri('file:///var/app/flutter_assets/');
      final action = navigationActionFor(
        'file:///var/app/flutter_assets/',
        isForMainFrame: false,
      );

      expect(isProgrammaticDocumentLoad(action, baseUrl), isFalse);
    });

    test('denies when baseUrl is null', () {
      final action = navigationActionFor('file:///var/app/flutter_assets/');

      expect(isProgrammaticDocumentLoad(action, null), isFalse);
    });
  });
}
