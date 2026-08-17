import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:model/email/attachment.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/drive_document_transfer_runner.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/drive_transfer_pipeline.dart';
import 'package:tmail_ui_user/features/upload/data/network/file_uploader.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_task_id.dart';
import 'package:tmail_ui_user/features/upload/presentation/controller/upload_controller.dart';
import 'package:tmail_ui_user/features/upload/presentation/validator/attachment_upload_validation_service.dart';
import 'package:tmail_ui_user/main/utils/toast_manager.dart';
import 'package:uuid/uuid.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy_factory.dart';
import 'package:workplace/data/datasource/drive_transfer/staged_drive_file.dart';
import 'package:workplace/data/model/workplace_type_defs.dart';
import 'package:workplace/domain/entity/drive_document.dart';
import 'package:workplace/presentation/model/drive_pick_state.dart';

import 'drive_transfer_pipeline_test.mocks.dart';

/// The pipeline never stages or uploads through the strategy itself — it hands
/// it to the runner — so only the concurrency it declares matters here.
class _FakeStrategy extends DriveTransferStrategy<StagedDriveFile> {
  @override
  int get maxConcurrentTransfers => 2;

  @override
  Future<StagedDriveFile> stage({
    required DriveDocument doc,
    required OnFileProcessedProgress onDownloadProgress,
    required CancelToken cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<Attachment> upload(DriveUploadRequest<StagedDriveFile> request) =>
      throw UnimplementedError();
}

@GenerateNiceMocks([
  MockSpec<AttachmentUploadValidationService>(),
  MockSpec<FileUploader>(),
  MockSpec<DriveTransferStrategyFactory>(),
  MockSpec<DriveDocumentTransferRunner>(),
  MockSpec<Uuid>(),
  MockSpec<ToastManager>(),
  MockSpec<UploadController>(),
])
void main() {
  late MockAttachmentUploadValidationService validationService;
  late MockDriveTransferStrategyFactory strategyFactory;
  late MockDriveDocumentTransferRunner transferRunner;
  late MockToastManager toastManager;
  late MockUploadController uploadController;
  late _FakeStrategy strategy;
  late Uri? uploadUri;

  DriveDocument docOf(String id, {int size = 1000}) => DriveDocument(
        id: id,
        name: '$id.pdf',
        size: size,
        mimeType: 'application/pdf',
        downloadLink: Uri.parse('https://drive.example.com/$id'),
      );

  PendingDriveTransfer pendingOf(DriveDocument doc) => PendingDriveTransfer(
        doc: doc,
        taskId: UploadTaskId(doc.id),
        cancelToken: CancelToken(),
      );

  DriveTransferPipeline buildPipeline() => DriveTransferPipeline(
        validationService: validationService,
        fileUploader: MockFileUploader(),
        uuid: MockUuid(),
        strategyFactory: strategyFactory,
        transferRunner: transferRunner,
        resolveUploadUri: () => uploadUri,
      );

  /// Lets the gate through, the way a batch within the size limit passes.
  void allowValidation() {
    when(validationService.validateBytes(
      context: anyNamed('context'),
      proposedAllAttachmentBytes: anyNamed('proposedAllAttachmentBytes'),
      proposedRegularAttachmentBytes: anyNamed('proposedRegularAttachmentBytes'),
      onAllowed: anyNamed('onAllowed'),
    )).thenAnswer((invocation) async {
      (invocation.namedArguments[#onAllowed] as VoidCallback)();
    });
  }

  setUp(() {
    validationService = MockAttachmentUploadValidationService();
    strategyFactory = MockDriveTransferStrategyFactory();
    transferRunner = MockDriveDocumentTransferRunner();
    toastManager = MockToastManager();
    uploadController = MockUploadController();
    strategy = _FakeStrategy();
    uploadUri = Uri.parse('https://jmap.example.com/upload');

    Get.testMode = true;
    Get.put<ToastManager>(toastManager);

    when(transferRunner.canAuthenticate).thenReturn(true);
    when(transferRunner.uploadController).thenReturn(uploadController);
    when(strategyFactory.create(uploader: anyNamed('uploader')))
        .thenReturn(strategy);
    when(transferRunner.enqueue(any)).thenAnswer((invocation) =>
        (invocation.positionalArguments.first as List<DriveDocument>)
            .map(pendingOf)
            .toList());
    allowValidation();
  });

  tearDown(Get.reset);

  group('DriveTransferPipeline::transfer::decline paths::', () {
    test('Should decline when there is no upload URI', () async {
      uploadUri = null;

      expect(await buildPipeline().transfer([docOf('a')]), isFalse);
      verifyNever(transferRunner.enqueue(any));
      verifyNever(transferRunner.run(
        pending: anyNamed('pending'),
        uploadUri: anyNamed('uploadUri'),
        strategy: anyNamed('strategy'),
      ));
    });

    test('Should decline when the session cannot authenticate', () async {
      when(transferRunner.canAuthenticate).thenReturn(false);

      expect(await buildPipeline().transfer([docOf('a')]), isFalse);
      verifyNever(strategyFactory.create(uploader: anyNamed('uploader')));
      verifyNever(transferRunner.enqueue(any));
    });

    test('Should decline when the platform has no staging strategy', () async {
      when(strategyFactory.create(uploader: anyNamed('uploader')))
          .thenReturn(null);

      expect(await buildPipeline().transfer([docOf('a')]), isFalse);
      verifyNever(transferRunner.enqueue(any));
    });

    test('Should decline an empty pick before consulting the factory', () async {
      expect(await buildPipeline().transfer([]), isFalse);
      verifyNever(strategyFactory.create(uploader: anyNamed('uploader')));
    });
  });

  group('DriveTransferPipeline::transfer::size gate::', () {
    test('Should still take the batch when the user declines at the gate', () async {
      when(validationService.validateBytes(
        context: anyNamed('context'),
        proposedAllAttachmentBytes: anyNamed('proposedAllAttachmentBytes'),
        proposedRegularAttachmentBytes: anyNamed('proposedRegularAttachmentBytes'),
        onAllowed: anyNamed('onAllowed'),
      )).thenAnswer((_) async {});

      // Declined is still handled: the user was told, so no link-only fallback.
      expect(await buildPipeline().transfer([docOf('a')]), isTrue);
      verifyNever(transferRunner.enqueue(any));
    });

    test('Should gate on the declared total, counted as regular attachments', () async {
      await buildPipeline().transfer([
        docOf('a', size: 1000),
        docOf('b', size: 2500),
      ]);

      verify(validationService.validateBytes(
        context: anyNamed('context'),
        proposedAllAttachmentBytes: 3500,
        proposedRegularAttachmentBytes: 3500,
        onAllowed: anyNamed('onAllowed'),
      )).called(1);
    });
  });

  group('DriveTransferPipeline::transfer::batch::', () {
    /// The batch runs unawaited behind the gate, so let it settle.
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('Should show every picked file before the first transfer finishes', () async {
      final docs = List.generate(10, (index) => docOf('doc-$index'));
      final firstRunStarted = Completer<void>();
      final releaseFirstRun = Completer<void>();

      when(transferRunner.run(
        pending: anyNamed('pending'),
        uploadUri: anyNamed('uploadUri'),
        strategy: anyNamed('strategy'),
      )).thenAnswer((_) async {
        if (!firstRunStarted.isCompleted) firstRunStarted.complete();
        await releaseFirstRun.future;
        return DriveTransferResult.attached;
      });

      unawaited(buildPipeline().transfer(docs));
      await firstRunStarted.future;

      final enqueued = verify(transferRunner.enqueue(captureAny)).captured.single
          as List<DriveDocument>;
      expect(enqueued, hasLength(10));

      releaseFirstRun.complete();
      await settle();
    });

    test('Should toast only what actually landed', () async {
      final docs = [docOf('a'), docOf('b'), docOf('c')];
      when(transferRunner.run(
        pending: anyNamed('pending'),
        uploadUri: anyNamed('uploadUri'),
        strategy: anyNamed('strategy'),
      )).thenAnswer((invocation) async {
        final doc =
            (invocation.namedArguments[#pending] as PendingDriveTransfer).doc;
        return doc.id != 'c'
            ? DriveTransferResult.attached
            : DriveTransferResult.failed;
      });

      expect(await buildPipeline().transfer(docs), isTrue);
      await settle();

      final success = verify(toastManager.showMessageSuccess(captureAny))
          .captured
          .single as DriveAttachSuccess;
      expect(success.attachedCount, 2);
    });

    test('Should stay quiet when nothing landed', () async {
      when(transferRunner.run(
        pending: anyNamed('pending'),
        uploadUri: anyNamed('uploadUri'),
        strategy: anyNamed('strategy'),
      )).thenAnswer((_) async => DriveTransferResult.failed);

      expect(await buildPipeline().transfer([docOf('a')]), isTrue);
      await settle();

      verifyNever(toastManager.showMessageSuccess(any));
    });

    test('Should toast the batch once for every failure, not per file', () async {
      when(transferRunner.run(
        pending: anyNamed('pending'),
        uploadUri: anyNamed('uploadUri'),
        strategy: anyNamed('strategy'),
      )).thenAnswer((_) async => DriveTransferResult.failed);

      await buildPipeline().transfer([docOf('a'), docOf('b'), docOf('c')]);
      await settle();

      verify(uploadController.showDriveTransferFailureToast()).called(1);
    });

    test('Should not toast a failure when every transfer was cancelled', () async {
      when(transferRunner.run(
        pending: anyNamed('pending'),
        uploadUri: anyNamed('uploadUri'),
        strategy: anyNamed('strategy'),
      )).thenAnswer((_) async => DriveTransferResult.cancelled);

      await buildPipeline().transfer([docOf('a')]);
      await settle();

      verifyNever(uploadController.showDriveTransferFailureToast());
    });

    test('Should run each enqueued transfer against the selected strategy', () async {
      when(transferRunner.run(
        pending: anyNamed('pending'),
        uploadUri: anyNamed('uploadUri'),
        strategy: anyNamed('strategy'),
      )).thenAnswer((_) async => DriveTransferResult.attached);

      await buildPipeline().transfer([docOf('a'), docOf('b')]);
      await settle();

      verify(transferRunner.run(
        pending: anyNamed('pending'),
        uploadUri: uploadUri!,
        strategy: strategy,
      )).called(2);
    });
  });
}
