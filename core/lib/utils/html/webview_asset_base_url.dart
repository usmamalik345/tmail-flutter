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

/// True when [action] is the WebView's own navigation to [baseUrl] (or
/// `about:blank`) triggered by `loadData`, as opposed to a user-followed
/// link. iOS can report this navigation's URL with `/private/var/` instead
/// of `/var/`, or a mismatched trailing slash, compared to the string
/// [baseUrl] was built from — so this compares on a normalized path instead
/// of exact string equality. `hasGesture` is checked so a malicious `file://`
/// link inside the HTML content can never be auto-allowed just because its
/// path happens to match.
bool isProgrammaticDocumentLoad(NavigationAction action, WebUri? baseUrl) {
  if (!action.isForMainFrame) return false;

  final url = action.request.url?.toString();
  if (url == 'about:blank') return true;

  if (baseUrl == null ||
      url == null ||
      action.request.url?.scheme != 'file' ||
      action.hasGesture == true) {
    return false;
  }

  String normalize(String path) => path
      .replaceFirst('file:///private/var/', 'file:///var/')
      .replaceFirst(RegExp(r'/+$'), '');

  final navigatedUrl = normalize(url);
  final cachedBaseUrl = normalize(baseUrl.toString());
  return navigatedUrl == cachedBaseUrl ||
      navigatedUrl.startsWith('$cachedBaseUrl/');
}

/// Enables `chrome://inspect` access to Android WebViews in debug builds
/// only. Unlike iOS's per-instance `isInspectable` setting, Android WebView
/// debugging is a one-time global flag that must be set before any WebView
/// is created.
Future<void> enableAndroidWebViewDebuggingInDebugMode() async {
  if (!kDebugMode) return;
  await InAppWebViewController.setWebContentsDebuggingEnabled(true);
}
