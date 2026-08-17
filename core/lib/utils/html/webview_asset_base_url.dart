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

  WebUri? _cachedFlutterAssetsBaseUrl;
  bool _fetchFailed = false;

  Future<WebUri?> flutterAssetsBaseUrl() async {
    if (!PlatformInfo.isMobile) return null;
    if (_cachedFlutterAssetsBaseUrl != null) return _cachedFlutterAssetsBaseUrl;
    if (_fetchFailed) return null;

    try {
      final baseUrl = await _channel.invokeMethod<String>(
        flutterAssetsBaseUrlMethod,
      );
      if (baseUrl == null) {
        _fetchFailed = true;
        return null;
      }
      return _cachedFlutterAssetsBaseUrl = WebUri(baseUrl);
    } catch (exception) {
      logWarning('$runtimeType::flutterAssetsBaseUrl:Exception = $exception');
      _fetchFailed = true;
      return null;
    }
  }
}
