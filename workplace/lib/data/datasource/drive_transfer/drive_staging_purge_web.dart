import 'package:core/utils/app_logger.dart';
import 'package:workplace/data/datasource/drive_transfer/opfs_feature_detection.dart';
import 'package:workplace/data/datasource/drive_transfer/opfs_file_ops.dart';

/// Removes every OPFS staging entry, whatever its age.
///
/// Staged documents are persistent and origin-scoped, so without this they
/// outlive a logout and carry into the next account's session. Failures are
/// logged, never rethrown: a logout must not be blocked by storage cleanup,
/// and a browser without OPFS has nothing to clean.
///
/// Reaches for the implementations directly rather than through an injected
/// port: purging is a logout concern with one caller, not one of the storage
/// operations a transfer depends on.
Future<void> purgeDriveStagingStorage() async {
  try {
    if (!OpfsFeatureDetection().isOpfsSupported()) return;
    await OpfsFileOps().purgeAllTempFiles();
  } catch (error) {
    logWarning('purgeDriveStagingStorage: failed to purge staging storage: $error');
  }
}
