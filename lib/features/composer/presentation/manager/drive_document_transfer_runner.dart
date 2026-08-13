import 'package:core/utils/app_logger.dart';
import 'package:dio/dio.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_task_id.dart';
import 'package:tmail_ui_user/features/upload/presentation/controller/upload_controller.dart';
import 'package:uuid/uuid.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy.dart';
import 'package:workplace/data/datasource/drive_transfer/staged_drive_file.dart';
import 'package:workplace/domain/entity/drive_document.dart';

/// Resolves the `Authorization` header for the current session, or null when
/// there is none to send.
typedef ResolveAuthHeader = String? Function();

/// Runs one drive document through both legs of its transfer: chip placeholder,
/// download and upload progress, then completion or failure.
class DriveDocumentTransferRunner {
  DriveDocumentTransferRunner({
    required UploadController uploadController,
    required Uuid uuid,
    required ResolveAuthHeader resolveAuthHeader,
  })  : _uploadController = uploadController,
        _uuid = uuid,
        _resolveAuthHeader = resolveAuthHeader;

  final UploadController _uploadController;
  final Uuid _uuid;
  final ResolveAuthHeader _resolveAuthHeader;

  Future<void> run({
    required DriveDocument doc,
    required Uri uploadUri,
    required DriveTransferStrategy<StagedDriveFile> strategy,
  }) async {
    final taskId = UploadTaskId(_uuid.v4());
    final cancelToken = CancelToken();

    _uploadController.addDownloadingPlaceholder(
      taskId: taskId,
      fileName: doc.name,
      fileSize: doc.size,
      mimeType: doc.mimeType,
      cancelToken: cancelToken,
    );

    try {
      final attachment = await strategy.transfer(DriveTransferRequest(
        doc: doc,
        uploadUri: uploadUri,
        authHeader: _resolveAuthHeader() ?? '',
        onDownloadProgress: (received, total) => _uploadController.updateDownloadProgress(
          taskId: taskId,
          received: received,
          total: total,
        ),
        onUploadProgress: (sent, total) => _uploadController.updateUploadProgress(
          taskId: taskId,
          sent: sent,
          total: total,
        ),
        cancelToken: cancelToken,
      ));
      _uploadController.completeUploadedFile(
        taskId: taskId,
        attachment: attachment,
      );
    } catch (error) {
      // A failing file drops its own chip and nothing else: an expired link or
      // a cancelled transfer must not take its siblings down with it.
      logWarning('DriveDocumentTransferRunner::run(${doc.name}): $error');
      if (cancelToken.isCancelled) {
        // The user asked for this one to stop, so no error toast.
        _uploadController.deleteFileUploaded(taskId);
      } else {
        _uploadController.failDriveTransfer(taskId);
      }
    }
  }
}
