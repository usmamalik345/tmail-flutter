import 'package:core/utils/app_logger.dart';
import 'package:core/utils/platform_info.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Resolves the on-disk `flutter_assets/` URL, used as `loadData`'s `baseUrl`
/// so relative asset URLs (e.g. the design-system font) can resolve on mobile.
class WebViewAssetBaseUrl {
  WebViewAssetBaseUrl({MethodChannel channel = const MethodChannel(channelName)})
      : _channel = channel;

  static final WebViewAssetBaseUrl instance = WebViewAssetBaseUrl();

  @visibleForTesting
  static const String channelName =
      'com.linagora.tmail/webview_asset_base_url';
  @visibleForTesting
  static const String flutterAssetsBaseUrlMethod = 'flutterAssetsBaseUrl';

  final MethodChannel _channel;

  Future<WebUri?>? _resolution;

  Future<WebUri?> flutterAssetsBaseUrl() {
    if (!PlatformInfo.isMobile) return Future.value(null);
    return _resolution ??= _resolve();
  }

  Future<WebUri?> _resolve() async {
    try {
      final baseUrl = await _channel.invokeMethod<String>(
        flutterAssetsBaseUrlMethod,
      );
      return baseUrl != null ? WebUri(baseUrl) : null;
    } catch (exception) {
      logWarning('$runtimeType::flutterAssetsBaseUrl:Exception = $exception');
      return null;
    }
  }
}
