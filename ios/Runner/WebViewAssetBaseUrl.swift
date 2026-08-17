import Flutter

/// Exposes the on-disk `flutter_assets/` URL for Dart to pass as `loadData`'s `baseUrl`.
class WebViewAssetBaseUrl {

    private static let channelName = "com.linagora.tmail/webview_asset_base_url"
    private static let flutterAssetsBaseUrlMethod = "flutterAssetsBaseUrl"

    func register(_ binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: Self.channelName,
            binaryMessenger: binaryMessenger
        )
        channel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case Self.flutterAssetsBaseUrlMethod:
                result(self?.flutterAssetsBaseUrl())
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func flutterAssetsBaseUrl() -> String? {
        // lookupKey(forAsset:) joins "<flutterAssetsDir>/<asset>"; trimming
        // the known asset name back off recovers the directory name, since
        // the underlying flutterAssetsName isn't exposed directly.
        let probeKey = FlutterDartProject.lookupKey(forAsset: "AssetManifest.json")
        guard let flutterAssetsDirName = probeKey
            .range(of: "/AssetManifest.json")
            .map({ String(probeKey[probeKey.startIndex..<$0.lowerBound]) }) else {
            return nil
        }
        let flutterAssetsUrl = Bundle.main.bundleURL.appendingPathComponent(
            flutterAssetsDirName,
            isDirectory: true
        )
        return flutterAssetsUrl.absoluteString
    }
}
