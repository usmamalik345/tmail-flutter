import 'dart:async';

import 'package:core/presentation/state/failure.dart';
import 'package:core/presentation/state/success.dart';
import 'package:core/utils/app_logger.dart';
import 'package:dartz/dartz.dart';
import 'package:dio/dio.dart';
import 'package:model/email/attachment.dart';
import 'package:model/upload/file_info.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/bounded_concurrency_runner.dart';
import 'package:tmail_ui_user/features/upload/data/network/file_uploader.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_task_id.dart';
import 'package:tmail_ui_user/features/upload/domain/state/attachment_upload_state.dart';
import 'package:tmail_ui_user/features/upload/presentation/controller/upload_controller.dart';
import 'package:tmail_ui_user/features/upload/presentation/validator/attachment_upload_validation_service.dart';
import 'package:uuid/uuid.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy_factory.dart';
import 'package:workplace/data/datasource/drive_transfer/staged_drive_file.dart';
import 'package:workplace/domain/entity/drive_document.dart';

/// Downloads drive documents into platform temp storage and uploads them as
/// real attachments, one bounded-concurrency pipeline per batch.
///
/// Platform capability is the strategy factory's business: when it has no
/// strategy for this platform, [transfer] declines the batch and the caller
/// keeps its link-only behaviour.
class DriveTransferPipeline {
  DriveTransferPipeline({
    required AttachmentUploadValidationService validationService,
    required UploadController uploadController,
    required FileUploader fileUploader,
    required Uuid uuid,
    required Uri? Function() resolveUploadUri,
    required String? Function() resolveAuthHeader,
  })  : _validationService = validationService,
        _uploadController = uploadController,
        _fileUploader = fileUploader,
        _uuid = uuid,
        _resolveUploadUri = resolveUploadUri,
        _resolveAuthHeader = resolveAuthHeader;

  final AttachmentUploadValidationService _validationService;
  final UploadController _uploadController;
  final FileUploader _fileUploader;
  final Uuid _uuid;
  final Uri? Function() _resolveUploadUri;
  final String? Function() _resolveAuthHeader;

  /// Held for this pipeline's lifetime: the factory caches its capability
  /// detection and runs the stale-staging sweep once per instance.
  ///
  /// Not `const`: only the mobile branch of the conditional export has a const
  /// constructor, which is the only branch the analyzer sees.
  // ignore: prefer_const_constructors
  final DriveTransferStrategyFactory _strategyFactory = DriveTransferStrategyFactory();

  /// Returns whether this pipeline took responsibility for [docs]. `false`
  /// means nothing was attempted — no staging strategy on this platform, or
  /// no upload endpoint to send to — so the caller should fall back.
  ///
  /// A batch the user declines at the size gate still counts as taken: the
  /// documents were handled and the user was told why nothing was attached.
  Future<bool> transfer(List<DriveDocument> docs) async {
    if (docs.isEmpty) return false;

    final uploadUri = _resolveUploadUri();
    if (uploadUri == null) {
      logWarning('DriveTransferPipeline::transfer: no upload URI available');
      return false;
    }

    final strategy = _strategyFactory.create(
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

    await _validationService.validateBytes(
      // Drive documents are never inline, so both totals are the same sum.
      proposedAllAttachmentBytes: declaredTotalBytes,
      proposedRegularAttachmentBytes: declaredTotalBytes,
      onAllowed: () => unawaited(_runBatch(docs, uploadUri, strategy)),
    );
    return true;
  }

  Future<void> _runBatch(
    List<DriveDocument> docs,
    Uri uploadUri,
    DriveTransferStrategy<StagedDriveFile> strategy,
  ) {
    return runWithConcurrency(
      docs,
      strategy.maxConcurrentTransfers,
      (doc) => _transferOne(doc, uploadUri, strategy),
    );
  }

  Future<void> _transferOne(
    DriveDocument doc,
    Uri uploadUri,
    DriveTransferStrategy<StagedDriveFile> strategy,
  ) async {
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
      logWarning('DriveTransferPipeline::_transferOne(${doc.name}): $error');
      _uploadController.deleteFileUploaded(taskId);
    }
  }

  /// Uploads a staged file whose bytes live in memory or on disk through the
  /// shared [FileUploader]. The OPFS strategy never calls this — it streams
  /// its own raw XHR so the file never reaches the Dart heap.
  Future<Attachment> _uploadStagedFile({
    required StagedDriveFile staged,
    required Uri uploadUri,
    required void Function(int sent, int total) onUploadProgress,
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
      return await _fileUploader.uploadAttachment(
        UploadTaskId(_uuid.v4()),
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
