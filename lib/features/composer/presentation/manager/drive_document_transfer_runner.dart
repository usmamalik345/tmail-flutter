import 'package:core/utils/app_logger.dart';
import 'package:dio/dio.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_task_id.dart';
import 'package:tmail_ui_user/features/upload/presentation/controller/upload_controller.dart';
import 'package:tmail_ui_user/features/upload/presentation/model/drive_transfer_placeholder.dart';
import 'package:uuid/uuid.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy.dart';
import 'package:workplace/data/datasource/drive_transfer/staged_drive_file.dart';
import 'package:workplace/domain/entity/drive_document.dart';

/// Resolves the `Authorization` header for the current session, or null when
/// there is none to send.
typedef ResolveAuthHeader = String? Function();

/// How one document's transfer ended.
enum DriveTransferResult { attached, failed, cancelled }

/// A document whose chip is already on screen while it waits for a concurrency
/// slot. Its identity is minted at enqueue time, so it can be cancelled before
/// its transfer ever starts.
class PendingDriveTransfer {
  final DriveDocument doc;
  final UploadTaskId taskId;
  final CancelToken cancelToken;

  const PendingDriveTransfer({
    required this.doc,
    required this.taskId,
    required this.cancelToken,
  });
}

/// Runs one drive document through both legs of its transfer: download and
/// upload progress, then completion or failure.
///
/// Every failure — staging, upload, oversized download — drops that file's chip
/// and toasts; a user cancel drops the chip silently. Siblings are unaffected.
class DriveDocumentTransferRunner {
  DriveDocumentTransferRunner({
    required this.uploadController,
    required this.uuid,
    required this.resolveAuthHeader,
  });

  final UploadController uploadController;
  final Uuid uuid;
  final ResolveAuthHeader resolveAuthHeader;

  /// Whether there is a session to upload with. Checked before a batch starts,
  /// so no file is downloaded only to be rejected by the upload endpoint.
  bool get canAuthenticate => resolveAuthHeader()?.trim().isNotEmpty == true;

  /// Puts a chip on screen for every [docs] entry at once, before any slot is
  /// free, and returns the handles to transfer them by.
  List<PendingDriveTransfer> enqueue(List<DriveDocument> docs) {
    final pendingTransfers = docs
        .map((doc) => PendingDriveTransfer(
              doc: doc,
              taskId: UploadTaskId(uuid.v4()),
              cancelToken: CancelToken(),
            ))
        .toList();

    uploadController.addDownloadingPlaceholders(pendingTransfers
        .map((pending) => DriveTransferPlaceholder(
              taskId: pending.taskId,
              fileName: pending.doc.name,
              fileSize: pending.doc.size,
              mimeType: pending.doc.mimeType,
              cancelToken: pending.cancelToken,
            ))
        .toList());

    return pendingTransfers;
  }

  /// Returns how the document's transfer ended, so a batch can tell an actual
  /// failure apart from a user cancel.
  Future<DriveTransferResult> run({
    required PendingDriveTransfer pending,
    required Uri uploadUri,
    required DriveTransferStrategy<StagedDriveFile> strategy,
  }) async {
    final doc = pending.doc;
    final taskId = pending.taskId;
    final cancelToken = pending.cancelToken;
    bool exceededDeclaredSize = false;

    // Cancelled while queued, so there is nothing left to download.
    if (cancelToken.isCancelled) {
      uploadController.deleteFileUploaded(taskId);
      return DriveTransferResult.cancelled;
    }

    try {
      final attachment = await strategy.transfer(DriveTransferRequest(
        doc: doc,
        uploadUri: uploadUri,
        authHeader: _requireAuthHeader(),
        onDownloadProgress: (received, total) {
          // The link is sending more than the backend declared, so the size
          // the batch was validated against no longer holds: stop now.
          // `doc.size` is 0 when the backend declared nothing, and the
          // response's own total is then the only ceiling there is.
          final declaredSize = doc.size > 0 ? doc.size : total;
          if (declaredSize > 0 && received > declaredSize) {
            exceededDeclaredSize = true;
            cancelToken.cancel();
            return;
          }
          uploadController.updateDownloadProgress(
            taskId: taskId,
            received: received,
            total: total,
          );
        },
        onUploadProgress: (sent, total) => uploadController.updateUploadProgress(
          taskId: taskId,
          sent: sent,
          total: total,
        ),
        cancelToken: cancelToken,
      ));
      uploadController.completeUploadedFile(
        taskId: taskId,
        attachment: attachment,
      );
      return DriveTransferResult.attached;
    } catch (error) {
      return _handleTransferFailure(
        taskId: taskId,
        cancelToken: cancelToken,
        exceededDeclaredSize: exceededDeclaredSize,
        error: error,
      );
    }
  }

  /// The `Authorization` header for the current session, or a thrown
  /// [StateError] when there is none to send.
  String _requireAuthHeader() {
    final authHeader = resolveAuthHeader();
    if (authHeader == null || authHeader.trim().isEmpty) {
      throw StateError('No authorization header for drive transfer');
    }
    return authHeader;
  }

  /// A failing file drops its own chip and nothing else: an expired link or
  /// a cancelled transfer must not take its siblings down with it.
  DriveTransferResult _handleTransferFailure({
    required UploadTaskId taskId,
    required CancelToken cancelToken,
    required bool exceededDeclaredSize,
    required Object error,
  }) {
    if (cancelToken.isCancelled && !exceededDeclaredSize) {
      // A user cancel is not a failure, so no warning log and no toast.
      uploadController.deleteFileUploaded(taskId);
      return DriveTransferResult.cancelled;
    }
    logWarning(
      'DriveDocumentTransferRunner::run: transfer failed | '
      'taskId=${taskId.id} | error=${_errorCategory(error)}',
    );
    uploadController.failDriveTransfer(taskId);
    return DriveTransferResult.failed;
  }

  /// A stable, PII-free label for a transfer failure: no document name, no
  /// download URI, no error message.
  String _errorCategory(Object error) => error is DioException
      ? 'DioException.${error.type.name}(${error.response?.statusCode})'
      : error.runtimeType.toString();
}
