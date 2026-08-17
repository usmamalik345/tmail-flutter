import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy.dart';
import 'package:workplace/data/datasource/drive_transfer/staged_drive_file.dart';
import 'package:workplace/data/model/workplace_type_defs.dart';

/// Mobile/desktop branch of the conditional export in
/// `drive_transfer_strategy_factory.dart`. IO temp-file staging is not
/// available yet, so downloadable documents keep the link-only behaviour.
class DriveTransferStrategyFactory {
  const DriveTransferStrategyFactory();

  /// The single source of truth for whether this platform can stage
  /// downloadable drive documents — callers must not re-derive it (e.g. via
  /// `kIsWeb`) independently.
  bool get canStage => false;

  DriveTransferStrategy<StagedDriveFile>? create(
          {required StagedFileUploader uploader}) =>
      null;
}
