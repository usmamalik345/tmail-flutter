import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jmap_dart_client/jmap/core/id.dart';
import 'package:jmap_dart_client/jmap/core/unsigned_int.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:model/email/attachment.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/drive_document_transfer_runner.dart';
import 'package:tmail_ui_user/features/upload/presentation/controller/upload_controller.dart';
import 'package:tmail_ui_user/features/upload/presentation/model/drive_transfer_placeholder.dart';
import 'package:uuid/uuid.dart';
import 'package:workplace/data/datasource/drive_transfer/drive_transfer_strategy.dart';
import 'package:workplace/data/datasource/drive_transfer/staged_drive_file.dart';
import 'package:workplace/domain/entity/drive_document.dart';

import 'drive_document_transfer_runner_test.mocks.dart';

/// Drives one transfer from the test: [onTransfer] receives the request the
/// runner built, so a test can replay progress or throw from either leg.
class _ScriptedStrategy extends DriveTransferStrategy<StagedDriveFile> {
  final Future<Attachment> Function(DriveTransferRequest request) onTransfer;

  int transferCalls = 0;

  _ScriptedStrategy(this.onTransfer);

  @override
  Future<Attachment> transfer(DriveTransferRequest request) {
    transferCalls++;
    return onTransfer(request);
  }

  @override
  Future<StagedDriveFile> stage({
    required DriveDocument doc,
    required onDownloadProgress,
    required CancelToken cancelToken,
  }) =>
      throw UnimplementedError();

  @override
  Future<Attachment> upload(DriveUploadRequest<StagedDriveFile> request) =>
      throw UnimplementedError();
}

@GenerateNiceMocks([
  MockSpec<UploadController>(),
  MockSpec<Uuid>(),
])
void main() {
  late MockUploadController uploadController;
  late MockUuid uuid;
  late String? authHeader;
  late int nextId;

  final attachment = Attachment(
    blobId: Id('blob-1'),
    name: 'Report.pdf',
    size: UnsignedInt(2000),
  );

  DriveDocument docOf({int size = 2000}) => DriveDocument(
        id: 'doc-1',
        name: 'Report.pdf',
        size: size,
        mimeType: 'application/pdf',
      );

  DriveDocumentTransferRunner buildRunner() => DriveDocumentTransferRunner(
        uploadController: uploadController,
        uuid: uuid,
        resolveAuthHeader: () => authHeader,
      );

  /// Enqueues [doc] and returns the handle the runner minted for it.
  PendingDriveTransfer enqueueOne(
    DriveDocumentTransferRunner runner,
    DriveDocument doc,
  ) =>
      runner.enqueue([doc]).single;

  setUp(() {
    uploadController = MockUploadController();
    uuid = MockUuid();
    authHeader = 'Bearer token';
    nextId = 0;
    when(uuid.v4()).thenAnswer((_) => 'task-${nextId++}');
  });

  group('DriveDocumentTransferRunner::canAuthenticate::', () {
    test('Should be false when there is no header', () {
      authHeader = null;
      expect(buildRunner().canAuthenticate, isFalse);
    });

    test('Should be false when the header is blank', () {
      authHeader = '   ';
      expect(buildRunner().canAuthenticate, isFalse);
    });

    test('Should be true when there is a header to send', () {
      expect(buildRunner().canAuthenticate, isTrue);
    });
  });

  group('DriveDocumentTransferRunner::enqueue::', () {
    test('Should put a chip up for every document with its own identity', () {
      final docs = List.generate(
        3,
        (index) => DriveDocument(
          id: 'doc-$index',
          name: 'File-$index.pdf',
          size: 1000,
          mimeType: 'application/pdf',
        ),
      );

      final pendingTransfers = buildRunner().enqueue(docs);

      expect(pendingTransfers, hasLength(3));
      expect(
        pendingTransfers.map((pending) => pending.taskId).toSet(),
        hasLength(3),
      );

      final placeholders =
          verify(uploadController.addDownloadingPlaceholders(captureAny))
              .captured
              .single as List<DriveTransferPlaceholder>;
      expect(placeholders, hasLength(3));
      expect(placeholders.first.fileName, 'File-0.pdf');
      expect(placeholders.first.fileSize, 1000);
      expect(placeholders.first.mimeType, 'application/pdf');
      expect(placeholders.first.cancelToken, pendingTransfers.first.cancelToken);
    });

    test('Should add the whole batch in one call', () {
      buildRunner().enqueue(List.generate(
        10,
        (index) => DriveDocument(
          id: 'doc-$index',
          name: 'File-$index.pdf',
          size: 1000,
          mimeType: 'application/pdf',
        ),
      ));

      verify(uploadController.addDownloadingPlaceholders(any)).called(1);
    });
  });

  group('DriveDocumentTransferRunner::run::', () {
    test('Should attach the document and complete its chip', () async {
      final runner = buildRunner();
      final pending = enqueueOne(runner, docOf());
      final strategy = _ScriptedStrategy((_) async => attachment);

      final attached = await runner.run(
        pending: pending,
        uploadUri: Uri.parse('https://jmap.example.com/upload'),
        strategy: strategy,
      );

      expect(attached, isTrue);
      verify(uploadController.completeUploadedFile(
        taskId: pending.taskId,
        attachment: attachment,
      )).called(1);
    });

    test('Should forward both legs of progress under the same task', () async {
      final runner = buildRunner();
      final pending = enqueueOne(runner, docOf());
      final strategy = _ScriptedStrategy((request) async {
        request.onDownloadProgress(1000, 2000);
        request.onUploadProgress(500, 2000);
        return attachment;
      });

      await runner.run(
        pending: pending,
        uploadUri: Uri.parse('https://jmap.example.com/upload'),
        strategy: strategy,
      );

      verify(uploadController.updateDownloadProgress(
        taskId: pending.taskId,
        received: 1000,
        total: 2000,
      )).called(1);
      verify(uploadController.updateUploadProgress(
        taskId: pending.taskId,
        sent: 500,
        total: 2000,
      )).called(1);
    });

    test('Should never start a transfer cancelled while it was queued', () async {
      final runner = buildRunner();
      final pending = enqueueOne(runner, docOf());
      final strategy = _ScriptedStrategy((_) async => attachment);
      pending.cancelToken.cancel();

      final attached = await runner.run(
        pending: pending,
        uploadUri: Uri.parse('https://jmap.example.com/upload'),
        strategy: strategy,
      );

      expect(attached, isFalse);
      expect(strategy.transferCalls, 0);
    });
  });

  group('DriveDocumentTransferRunner::run::oversize abort::', () {
    test('Should stop a download that outgrows the declared size', () async {
      final runner = buildRunner();
      final pending = enqueueOne(runner, docOf(size: 2000));
      final strategy = _ScriptedStrategy((request) async {
        request.onDownloadProgress(3000, 4000);
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(),
          reason: request.cancelToken.cancelError,
        );
      });

      final attached = await runner.run(
        pending: pending,
        uploadUri: Uri.parse('https://jmap.example.com/upload'),
        strategy: strategy,
      );

      expect(attached, isFalse);
      expect(pending.cancelToken.isCancelled, isTrue);
      // Not the silent delete: an oversized link is an error the user must see.
      verify(uploadController.failDriveTransfer(pending.taskId)).called(1);
      verifyNever(uploadController.updateDownloadProgress(
        taskId: anyNamed('taskId'),
        received: anyNamed('received'),
        total: anyNamed('total'),
      ));
    });

    test('Should fall back to the response length when nothing was declared', () async {
      final runner = buildRunner();
      final pending = enqueueOne(runner, docOf(size: 0));
      final strategy = _ScriptedStrategy((request) async {
        request.onDownloadProgress(1500, 2000);
        return attachment;
      });

      final attached = await runner.run(
        pending: pending,
        uploadUri: Uri.parse('https://jmap.example.com/upload'),
        strategy: strategy,
      );

      expect(attached, isTrue);
      expect(pending.cancelToken.isCancelled, isFalse);
      verify(uploadController.updateDownloadProgress(
        taskId: pending.taskId,
        received: 1500,
        total: 2000,
      )).called(1);
    });
  });

  group('DriveDocumentTransferRunner::run::failure paths::', () {
    Future<bool> runFailing(
      DriveDocumentTransferRunner runner,
      PendingDriveTransfer pending,
      Object error,
    ) =>
        runner.run(
          pending: pending,
          uploadUri: Uri.parse('https://jmap.example.com/upload'),
          strategy: _ScriptedStrategy((_) async => throw error),
        );

    test('Should drop a user-cancelled transfer without a toast', () async {
      final runner = buildRunner();
      final pending = enqueueOne(runner, docOf());
      final strategy = _ScriptedStrategy((request) async {
        request.cancelToken.cancel();
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(),
          reason: request.cancelToken.cancelError,
        );
      });

      final attached = await runner.run(
        pending: pending,
        uploadUri: Uri.parse('https://jmap.example.com/upload'),
        strategy: strategy,
      );

      expect(attached, isFalse);
      verify(uploadController.deleteFileUploaded(pending.taskId)).called(1);
      verifyNever(uploadController.failDriveTransfer(any));
    });

    test('Should toast a transfer that failed on its own', () async {
      final runner = buildRunner();
      final pending = enqueueOne(runner, docOf());

      final attached = await runFailing(
        runner,
        pending,
        DioException.connectionError(
          requestOptions: RequestOptions(),
          reason: 'gone',
        ),
      );

      expect(attached, isFalse);
      verify(uploadController.failDriveTransfer(pending.taskId)).called(1);
    });

    const unusableHeaders = <String, String?>{
      'the session lost its header': null,
      'the header went blank': '   ',
    };

    unusableHeaders.forEach((reason, header) {
      test('Should fail the transfer when $reason', () async {
        final runner = buildRunner();
        final pending = enqueueOne(runner, docOf());
        authHeader = header;

        final attached = await runner.run(
          pending: pending,
          uploadUri: Uri.parse('https://jmap.example.com/upload'),
          strategy: _ScriptedStrategy((_) async => attachment),
        );

        expect(attached, isFalse);
        verify(uploadController.failDriveTransfer(pending.taskId)).called(1);
      });
    });
  });
}
