import 'package:core/data/network/config/dynamic_url_interceptors.dart';
import 'package:dio/dio.dart';
import 'package:core/presentation/resources/image_paths.dart';
import 'package:core/presentation/utils/app_toast.dart';
import 'package:core/presentation/utils/responsive_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jmap_dart_client/jmap/core/id.dart';
import 'package:jmap_dart_client/jmap/core/unsigned_int.dart';
import 'package:mockito/annotations.dart';
import 'package:model/email/attachment.dart';
import 'package:tmail_ui_user/features/caching/caching_manager.dart';
import 'package:tmail_ui_user/features/composer/domain/usecases/upload_attachment_interactor.dart';
import 'package:tmail_ui_user/features/login/data/network/interceptors/authorization_interceptors.dart';
import 'package:tmail_ui_user/features/login/domain/usecases/delete_authority_oidc_interactor.dart';
import 'package:tmail_ui_user/features/login/domain/usecases/delete_credential_interactor.dart';
import 'package:tmail_ui_user/features/manage_account/data/local/language_cache_manager.dart';
import 'package:tmail_ui_user/features/manage_account/domain/usecases/log_out_oidc_interactor.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_task_id.dart';
import 'package:tmail_ui_user/features/upload/presentation/controller/upload_controller.dart';
import 'package:tmail_ui_user/features/upload/presentation/model/upload_file_status.dart';
import 'package:tmail_ui_user/main/bindings/network/binding_tag.dart';
import 'package:tmail_ui_user/main/utils/toast_manager.dart';
import 'package:tmail_ui_user/main/utils/twake_app_manager.dart';
import 'package:uuid/uuid.dart';

import 'upload_controller_drive_progress_test.mocks.dart';

@GenerateNiceMocks([
  MockSpec<UploadAttachmentInteractor>(),
  MockSpec<CachingManager>(),
  MockSpec<LanguageCacheManager>(),
  MockSpec<AuthorizationInterceptors>(),
  MockSpec<DynamicUrlInterceptors>(),
  MockSpec<DeleteCredentialInteractor>(),
  MockSpec<LogoutOidcInteractor>(),
  MockSpec<DeleteAuthorityOidcInteractor>(),
  MockSpec<AppToast>(),
  MockSpec<ImagePaths>(),
  MockSpec<ResponsiveUtils>(),
  MockSpec<Uuid>(),
  MockSpec<ToastManager>(),
  MockSpec<TwakeAppManager>(),
])
void main() {
  late UploadController uploadController;
  const taskId = UploadTaskId('drive-task');

  Attachment attachmentOf(String blobId) => Attachment(
        blobId: Id(blobId),
        name: 'Photo.jpg',
        size: UnsignedInt(2000),
      );

  UploadFileStatus? statusOf(UploadTaskId id) =>
      uploadController.getUploadFileId(id)?.uploadStatus;

  int? progressOf(UploadTaskId id) =>
      uploadController.getUploadFileId(id)?.uploadingProgress;

  setUp(() {
    Get.testMode = true;
    Get.put<CachingManager>(MockCachingManager());
    Get.put<LanguageCacheManager>(MockLanguageCacheManager());
    Get.put<AuthorizationInterceptors>(MockAuthorizationInterceptors());
    Get.put<AuthorizationInterceptors>(
      MockAuthorizationInterceptors(),
      tag: BindingTag.isolateTag,
    );
    Get.put<DynamicUrlInterceptors>(MockDynamicUrlInterceptors());
    Get.put<DeleteCredentialInteractor>(MockDeleteCredentialInteractor());
    Get.put<LogoutOidcInteractor>(MockLogoutOidcInteractor());
    Get.put<DeleteAuthorityOidcInteractor>(MockDeleteAuthorityOidcInteractor());
    Get.put<AppToast>(MockAppToast());
    Get.put<ImagePaths>(MockImagePaths());
    Get.put<ResponsiveUtils>(MockResponsiveUtils());
    Get.put<Uuid>(MockUuid());
    Get.put<ToastManager>(MockToastManager());
    Get.put<TwakeAppManager>(MockTwakeAppManager());

    uploadController = Get.put(UploadController(MockUploadAttachmentInteractor()));
    uploadController.addDownloadingPlaceholder(
      taskId: taskId,
      fileName: 'Photo.jpg',
      fileSize: 2000,
      mimeType: 'image/jpeg',
    );
  });

  tearDown(Get.reset);

  group('UploadController::drive transfer chip::', () {
    test('Should show the placeholder as downloading at zero progress', () {
      expect(statusOf(taskId), UploadFileStatus.fetching);
      expect(progressOf(taskId), 0);
      expect(uploadController.listUploadAttachments, hasLength(1));
    });

    test('Should map a half-received download onto a quarter of the bar', () {
      uploadController.updateDownloadProgress(
        taskId: taskId,
        received: 1000,
        total: 2000,
      );

      expect(progressOf(taskId), 25);
    });

    test('Should map a fully received download onto the halfway mark', () {
      uploadController.updateDownloadProgress(
        taskId: taskId,
        received: 2000,
        total: 2000,
      );

      expect(progressOf(taskId), 50);
      expect(statusOf(taskId), UploadFileStatus.fetching);
    });

    test('Should leave progress untouched when the total length is unknown', () {
      uploadController.updateDownloadProgress(
        taskId: taskId,
        received: 500,
        total: 0,
      );

      expect(progressOf(taskId), 0);
    });

    test('Should hold the bar where it stands when the upload length goes unknown midway', () {
      uploadController.updateUploadProgress(
        taskId: taskId,
        sent: 1200,
        total: 2000,
      );
      expect(progressOf(taskId), 80);

      uploadController.updateUploadProgress(
        taskId: taskId,
        sent: 1400,
        total: 0,
      );

      expect(progressOf(taskId), 80);
    });

    test('Should resume from the halfway mark when the upload starts', () {
      uploadController.updateDownloadProgress(
        taskId: taskId,
        received: 2000,
        total: 2000,
      );
      uploadController.updateUploadProgress(taskId: taskId, sent: 0, total: 2000);

      expect(statusOf(taskId), UploadFileStatus.uploading);
      expect(progressOf(taskId), 50);
    });

    test('Should never drop below the halfway mark while uploading', () {
      uploadController.updateUploadProgress(
        taskId: taskId,
        sent: 500,
        total: 2000,
      );

      expect(progressOf(taskId), greaterThanOrEqualTo(50));
      // A quarter through the upload leg, mapped onto the 50-100 band: 62.5,
      // which `round()` takes away from zero.
      expect(progressOf(taskId), 63);
    });

    test('Should finish at a full bar with the attachment attached', () {
      final attachment = attachmentOf('blob-1');

      uploadController.completeUploadedFile(
        taskId: taskId,
        attachment: attachment,
      );

      expect(statusOf(taskId), UploadFileStatus.succeed);
      expect(progressOf(taskId), 100);
      expect(uploadController.getUploadFileId(taskId)?.attachment, attachment);
      expect(uploadController.attachmentsUploaded, [attachment]);
    });

    test('Should drop the chip when the transfer is deleted', () {
      uploadController.deleteFileUploaded(taskId);

      expect(uploadController.getUploadFileId(taskId), isNull);
      expect(uploadController.listUploadAttachments, isEmpty);
    });
  });

  group('UploadController::progress rebuilds::', () {
    late int emissions;

    setUp(() {
      emissions = 0;
      uploadController.listUploadAttachments.listen((_) => emissions++);
    });

    test('Should rebuild at most once per percent over a chunked download', () async {
      const total = 100000;
      for (var received = 0; received <= total; received += 100) {
        uploadController.updateDownloadProgress(
          taskId: taskId,
          received: received,
          total: total,
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(progressOf(taskId), 50);
      // 1000 callbacks, but the download leg only spans 51 distinct percents.
      expect(emissions, lessThanOrEqualTo(51));
    });

    test('Should not rebuild when a chunk moves nothing the chip renders', () async {
      uploadController.updateDownloadProgress(
        taskId: taskId,
        received: 1000,
        total: 2000,
      );
      await Future<void>.delayed(Duration.zero);
      final emissionsAfterFirst = emissions;

      uploadController.updateDownloadProgress(
        taskId: taskId,
        received: 1000,
        total: 2000,
      );
      await Future<void>.delayed(Duration.zero);

      expect(emissions, emissionsAfterFirst);
    });

    test('Should still rebuild when only the status changes', () async {
      uploadController.updateDownloadProgress(
        taskId: taskId,
        received: 2000,
        total: 2000,
      );
      await Future<void>.delayed(Duration.zero);
      final emissionsAfterDownload = emissions;

      // Same percent, so only the flip to uploading justifies the rebuild.
      uploadController.updateUploadProgress(taskId: taskId, sent: 0, total: 2000);
      await Future<void>.delayed(Duration.zero);

      expect(statusOf(taskId), UploadFileStatus.uploading);
      expect(progressOf(taskId), 50);
      expect(emissions, greaterThan(emissionsAfterDownload));
    });

    test('Should ignore progress for a task that is no longer listed', () {
      uploadController.deleteFileUploaded(taskId);

      expect(
        () => uploadController.updateDownloadProgress(
          taskId: taskId,
          received: 100,
          total: 2000,
        ),
        returnsNormally,
      );
      expect(uploadController.listUploadAttachments, isEmpty);
    });
  });

  group('UploadController::cancel on close::', () {
    const pendingTaskId = UploadTaskId('pending-task');
    const doneTaskId = UploadTaskId('done-task');

    late CancelToken pendingToken;
    late CancelToken doneToken;

    setUp(() {
      pendingToken = CancelToken();
      doneToken = CancelToken();

      uploadController.addDownloadingPlaceholder(
        taskId: pendingTaskId,
        fileName: 'Pending.pdf',
        fileSize: 4000,
        cancelToken: pendingToken,
      );
      uploadController.addDownloadingPlaceholder(
        taskId: doneTaskId,
        fileName: 'Done.pdf',
        fileSize: 4000,
        cancelToken: doneToken,
      );
      uploadController.completeUploadedFile(
        taskId: doneTaskId,
        attachment: attachmentOf('blob-done'),
      );
    });

    test('Should cancel every unfinished transfer when the composer closes', () async {
      await Get.delete<UploadController>();

      expect(pendingToken.isCancelled, isTrue);
    });

    test('Should leave a finished transfer alone when the composer closes', () async {
      await Get.delete<UploadController>();

      expect(doneToken.isCancelled, isFalse);
    });

    test('Should ignore a transfer reporting back after the composer closed', () async {
      await Get.delete<UploadController>();

      expect(
        () {
          uploadController.updateDownloadProgress(
            taskId: pendingTaskId,
            received: 100,
            total: 4000,
          );
          uploadController.deleteFileUploaded(pendingTaskId);
        },
        returnsNormally,
      );
    });
  });
}
