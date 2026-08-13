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
import 'package:uuid/uuid.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy_factory.dart';
import 'package:workplace/data/datasource/drive_transfer/staged_drive_file.dart';
import 'package:workplace/data/model/workplace_type_defs.dart';
import 'package:workplace/domain/entity/drive_document.dart';

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
    required AttachmentUploadValidationService validationService,
    required FileUploader fileUploader,
    required Uuid uuid,
    required DriveTransferStrategyFactory strategyFactory,
    required DriveDocumentTransferRunner transferRunner,
    required ResolveUploadUri resolveUploadUri,
  })  : _validationService = validationService,
        _fileUploader = fileUploader,
        _uuid = uuid,
        _strategyFactory = strategyFactory,
        _transferRunner = transferRunner,
        _resolveUploadUri = resolveUploadUri;

  final AttachmentUploadValidationService _validationService;
  final FileUploader _fileUploader;
  final Uuid _uuid;
  final DriveDocumentTransferRunner _transferRunner;

  /// App-wide singleton from `CoreBindings`: it caches capability detection
  /// and sweeps stale staging once, so it outlives any one composer.
  final DriveTransferStrategyFactory _strategyFactory;
  final ResolveUploadUri _resolveUploadUri;

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

    if (!_transferRunner.canAuthenticate) {
      logWarning('DriveTransferPipeline::transfer: no authorization header available');
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
      (doc) => _transferRunner.run(
        doc: doc,
        uploadUri: uploadUri,
        strategy: strategy,
      ),
    );
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
