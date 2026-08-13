/// Selects the drive-transfer strategy for the current platform capability.
///
/// `create()` returns `null` when the platform has no staging strategy yet:
/// callers keep the link-only behaviour for downloadable documents instead of
/// branching on platform themselves.
export 'drive_transfer_strategy_factory_mobile.dart'
    if (dart.library.html) 'drive_transfer_strategy_factory_web.dart';
