import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core/data/network/dio_client.dart';
import 'package:core/utils/file_utils.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:model/upload/file_info.dart';
import 'package:tmail_ui_user/features/upload/data/network/file_uploader.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_attachment.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_task_id.dart';
import 'package:tmail_ui_user/features/upload/domain/state/attachment_upload_state.dart';
import 'package:tmail_ui_user/main/exceptions/thrower/exception_thrower.dart';

class _RethrowExceptionThrower extends ExceptionThrower {
  @override
  throwException(dynamic error, dynamic stackTrace) => throw error;
}

void main() {
  Future<HttpServer> startStalledUploadServer({
    required Completer<void> requestReceived,
    required Completer<void> releaseResponse,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      if (!requestReceived.isCompleted) {
        requestReceived.complete();
      }
      await releaseResponse.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'accountId': 'account-id',
        'blobId': 'blob-id',
        'type': 'application/pdf',
        'size': 0,
      }));
      await request.response.close();
    });
    addTearDown(() async {
      if (!releaseResponse.isCompleted) {
        releaseResponse.complete();
      }
      await server.close(force: true);
    });
    return server;
  }

  test('reports a cancelled upload as CancelAttachmentUploadState, not an error', () async {
    final sourceBytes = List<int>.generate(2048, (index) => index % 256);
    final directory = await Directory.systemTemp.createTemp('cancel-attachment-');
    addTearDown(() async {
      await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/a.pdf');
    await file.writeAsBytes(sourceBytes);

    final requestReceived = Completer<void>();
    final releaseResponse = Completer<void>();
    final server = await startStalledUploadServer(
      requestReceived: requestReceived,
      releaseResponse: releaseResponse,
    );
    final cancelToken = CancelToken();
    const uploadTaskId = UploadTaskId('upload-cancel');
    final uploadAttachment = UploadAttachment(
      uploadTaskId,
      FileInfo(fileName: 'a.pdf', fileSize: sourceBytes.length, filePath: file.path),
      Uri.parse('http://${server.address.address}:${server.port}/upload/account-id'),
      FileUploader(DioClient(Dio()), FileUtils()),
      _RethrowExceptionThrower(),
      cancelToken: cancelToken,
    );

    final statesFuture = uploadAttachment.progressState.toList();
    uploadAttachment.upload();

    await requestReceived.future.timeout(const Duration(seconds: 30));
    cancelToken.cancel();

    final states = await statesFuture.timeout(const Duration(seconds: 30));
    final emittedStates = <Object?>[];
    for (final state in states) {
      state.fold(emittedStates.add, emittedStates.add);
    }

    // Cancelling now aborts the socket, so a real DioExceptionType.cancel
    // reaches UploadAttachment instead of the upload running to completion.
    expect(emittedStates.whereType<ErrorAttachmentUploadState>(), isEmpty);
    expect(emittedStates.last, isA<CancelAttachmentUploadState>());
    expect(
      (emittedStates.last as CancelAttachmentUploadState).uploadId,
      uploadTaskId,
    );
  });
}
