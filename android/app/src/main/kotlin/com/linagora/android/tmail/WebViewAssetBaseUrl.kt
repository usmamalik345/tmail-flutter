package com.linagora.android.tmail

import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Exposes the on-disk `flutter_assets/` URL for Dart to pass as `loadData`'s `baseUrl`. */
class WebViewAssetBaseUrl {

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                FLUTTER_ASSETS_BASE_URL_METHOD -> result.success(flutterAssetsBaseUrl())
                else -> result.notImplemented()
            }
        }
    }

    private fun flutterAssetsBaseUrl(): String {
        val flutterAssetsDir = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        return "$ANDROID_ASSET_URL_PREFIX$flutterAssetsDir/"
    }

    private companion object {
        const val CHANNEL = "com.linagora.tmail/webview_asset_base_url"
        const val FLUTTER_ASSETS_BASE_URL_METHOD = "flutterAssetsBaseUrl"
        const val ANDROID_ASSET_URL_PREFIX = "file:///android_asset/"
    }
}
