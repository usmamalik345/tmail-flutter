import 'dart:async';

import 'package:core/presentation/state/failure.dart';
import 'package:core/presentation/state/success.dart';
import 'package:core/utils/app_logger.dart';
import 'package:dartz/dartz.dart';
import 'package:dio/dio.dart';
import 'package:model/email/attachment.dart';
import 'package:model/upload/file_info.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/bounded_concurrency_runner.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/drive_document_transfer_runner.dart';
import 'package:tmail_ui_user/features/upload/data/network/file_uploader.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_task_id.dart';
import 'package:tmail_ui_user/features/upload/domain/state/attachment_upload_state.dart';
import 'package:tmail_ui_user/features/upload/presentation/validator/attachment_upload_validation_service.dart';
import 'package:tmail_ui_user/main/routes/route_navigation.dart';
import 'package:tmail_ui_user/main/utils/toast_manager.dart';
import 'package:uuid/uuid.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy_factory.dart';
import 'package:workplace/data/datasource/drive_transfer/staged_drive_file.dart';
import 'package:workplace/data/model/workplace_type_defs.dart';
import 'package:workplace/domain/entity/drive_document.dart';
import 'package:workplace/presentation/model/drive_pick_state.dart';

/// Resolves the JMAP upload endpoint for the current session, or null when
/// there is none yet.
typedef ResolveUploadUri = Uri? Function();

/// Downloads drive documents into platform temp storage and uploads them as
/// real attachments, one bounded-concurrency pipeline per batch.
///
/// Platform capability is the strategy factory's business: when it has no
/// strategy for this platform, [transfer] declines the batch and the caller
/// keeps its link-only behaviour.
class DriveTransferPipeline {
  DriveTransferPipeline({
    required this.validationService,
    required this.fileUploader,
    required this.uuid,
    required this.strategyFactory,
    required this.transferRunner,
    required this.resolveUploadUri,
  });

  final AttachmentUploadValidationService validationService;
  final FileUploader fileUploader;
  final Uuid uuid;
  final DriveDocumentTransferRunner transferRunner;

  /// App-wide singleton from `CoreBindings`: it caches capability detection
  /// and sweeps stale staging once, so it outlives any one composer.
  final DriveTransferStrategyFactory strategyFactory;
  final ResolveUploadUri resolveUploadUri;

  /// Returns whether this pipeline took responsibility for [docs]. `false`
  /// means nothing was attempted — no staging strategy on this platform, or
  /// no upload endpoint to send to — so the caller should fall back.
  ///
  /// A batch the user declines at the size gate still counts as taken: the
  /// documents were handled and the user was told why nothing was attached.
  ///
  /// Failure paths:
  /// - no upload URI / no auth header / no strategy → `false`, caller toasts.
  /// - staging or upload failure → per-file, see [DriveDocumentTransferRunner].
  Future<bool> transfer(List<DriveDocument> docs) async {
    if (docs.isEmpty) return false;

    final uploadUri = resolveUploadUri();
    if (uploadUri == null) {
      logWarning('DriveTransferPipeline::transfer: no upload URI available');
      return false;
    }

    if (!transferRunner.canAuthenticate) {
      logWarning('DriveTransferPipeline::transfer: no authorization header available');
      return false;
    }

    final strategy = strategyFactory.create(
      uploader: ({
        required staged,
        required uploadUri,
        required onUploadProgress,
        required cancelToken,
      }) =>
          _uploadStagedFile(
            staged: staged,
            uploadUri: uploadUri,
            onUploadProgress: onUploadProgress,
            cancelToken: cancelToken,
          ),
    );
    if (strategy == null) return false;

    final declaredTotalBytes =
        docs.fold<int>(0, (total, doc) => total + doc.size);

    await validationService.validateBytes(
      // Drive documents are never inline, so both totals are the same sum.
      proposedAllAttachmentBytes: declaredTotalBytes,
      proposedRegularAttachmentBytes: declaredTotalBytes,
      onAllowed: () => unawaited(_runBatch(docs, uploadUri, strategy)),
    );
    return true;
  }

  /// One toast per pick, not per file: the batch reports itself once every
  /// transfer has settled. Counting needs no lock — the workers are concurrent
  /// futures on a single isolate, not parallel threads.
  Future<void> _runBatch(
    List<DriveDocument> docs,
    Uri uploadUri,
    DriveTransferStrategy<StagedDriveFile> strategy,
  ) async {
    // Guards the whole batch: runWithConcurrency propagates a worker's escaped
    // error, and that must not become an unhandled root-zone error under the
    // caller's unawaited().
    try {
      var attachedCount = 0;
      var failedCount = 0;
      // Every chip goes up first: what the user sees must match what they
      // picked, not how many files fit through the concurrency limit at once.
      final pendingTransfers = transferRunner.enqueue(docs);
      await runWithConcurrency(
        pendingTransfers,
        strategy.maxConcurrentTransfers,
        (pending) async {
          final result = await transferRunner.run(
            pending: pending,
            uploadUri: uploadUri,
            strategy: strategy,
          );
          switch (result) {
            case DriveTransferResult.attached:
              attachedCount++;
            case DriveTransferResult.failed:
              failedCount++;
            case DriveTransferResult.cancelled:
              break;
          }
        },
      );
      if (attachedCount > 0) _showSuccessToast(attachedCount);
      // One toast for the whole batch, not one per file.
      if (failedCount > 0) transferRunner.uploadController.showDriveTransferFailureToast();
    } catch (error) {
      logWarning('DriveTransferPipeline::_runBatch: batch failed: $error');
    }
  }

  /// Toasts the batch result, or logs when there is no [ToastManager] bound.
  void _showSuccessToast(int attachedCount) {
    final toastManager = getBinding<ToastManager>();
    if (toastManager == null) {
      logWarning(
        'DriveTransferPipeline::_showSuccessToast: no ToastManager bound, '
        'success not shown to the user',
      );
      return;
    }
    toastManager.showMessageSuccess(DriveAttachSuccess(attachedCount));
  }

  /// Uploads a staged file whose bytes live in memory or on disk through the
  /// shared [FileUploader]. The OPFS strategy never calls this — it streams
  /// its own raw XHR so the file never reaches the Dart heap.
  Future<Attachment> _uploadStagedFile({
    required StagedDriveFile staged,
    required Uri uploadUri,
    required OnFileProcessedProgress onUploadProgress,
    required CancelToken cancelToken,
  }) async {
    final fileInfo = switch (staged) {
      BytesStagedFile(:final bytes) => FileInfo.fromBytes(
          bytes: bytes,
          name: staged.fileName,
          size: staged.fileSize,
          type: staged.mimeType,
        ),
      FileBackedStagedFile(:final filePath) => FileInfo(
          fileName: staged.fileName,
          fileSize: staged.fileSize,
          filePath: filePath,
          type: staged.mimeType,
        ),
      OpfsStagedFile() => throw UnsupportedError(
          'OPFS staged files upload through their own XHR path'),
    };

    final progressController = StreamController<Either<Failure, Success>>();
    final progressSubscription = progressController.stream.listen((state) {
      state.map((success) {
        if (success is UploadingAttachmentUploadState) {
          onUploadProgress(success.progress, success.total);
        }
      });
    });

    try {
      return await fileUploader.uploadAttachment(
        UploadTaskId(uuid.v4()),
        fileInfo,
        uploadUri,
        cancelToken: cancelToken,
        onSendController: progressController,
      );
    } finally {
      await progressSubscription.cancel();
      await progressController.close();
    }
  }
}
