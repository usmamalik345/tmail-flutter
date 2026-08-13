/// Removes every drive-staging entry this package owns.
///
/// The main app cannot import `package:web` code directly, so the web
/// implementation is reached through this conditional export and is a no-op
/// everywhere else.
export 'drive_staging_purge_mobile.dart'
    if (dart.library.html) 'drive_staging_purge_web.dart';
