import 'package:dio/dio.dart';
import 'package:tmail_ui_user/features/upload/domain/model/upload_task_id.dart';

/// What a queued drive file needs to render its chip before its transfer
/// starts. The cancel token is minted with it, so a file can be cancelled
/// while it is still waiting for a slot.
class DriveTransferPlaceholder {
  final UploadTaskId taskId;
  final String fileName;
  final int fileSize;
  final String? mimeType;
  final CancelToken? cancelToken;

  const DriveTransferPlaceholder({
    required this.taskId,
    required this.fileName,
    required this.fileSize,
    this.mimeType,
    this.cancelToken,
  });
}
