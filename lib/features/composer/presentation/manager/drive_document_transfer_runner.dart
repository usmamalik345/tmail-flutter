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
///
/// Every failure — staging, upload, oversized download — drops that file's chip
/// and toasts; a user cancel drops the chip silently. Siblings are unaffected.
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

  /// Whether there is a session to upload with. Checked before a batch starts,
  /// so no file is downloaded only to be rejected by the upload endpoint.
  bool get canAuthenticate => _resolveAuthHeader()?.isNotEmpty == true;

  Future<void> run({
    required DriveDocument doc,
    required Uri uploadUri,
    required DriveTransferStrategy<StagedDriveFile> strategy,
  }) async {
    final taskId = UploadTaskId(_uuid.v4());
    final cancelToken = CancelToken();
    var exceededDeclaredSize = false;

    _uploadController.addDownloadingPlaceholder(
      taskId: taskId,
      fileName: doc.name,
      fileSize: doc.size,
      mimeType: doc.mimeType,
      cancelToken: cancelToken,
    );

    try {
      final authHeader = _resolveAuthHeader();
      if (authHeader == null || authHeader.isEmpty) {
        throw StateError('No authorization header for drive transfer');
      }

      final attachment = await strategy.transfer(DriveTransferRequest(
        doc: doc,
        uploadUri: uploadUri,
        authHeader: authHeader,
        onDownloadProgress: (received, total) {
          // The link is sending more than the backend declared, so the size
          // the batch was validated against no longer holds: stop now.
          if (doc.size > 0 && received > doc.size) {
            exceededDeclaredSize = true;
            cancelToken.cancel();
            return;
          }
          _uploadController.updateDownloadProgress(
            taskId: taskId,
            received: received,
            total: total,
          );
        },
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
      if (cancelToken.isCancelled && !exceededDeclaredSize) {
        // The user asked for this one to stop, so no error toast.
        _uploadController.deleteFileUploaded(taskId);
      } else {
        _uploadController.failDriveTransfer(taskId);
      }
    }
  }
}
