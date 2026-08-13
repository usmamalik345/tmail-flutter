
enum UploadFileStatus {
  waiting,
  /// Staging leg of a drive transfer, before its upload starts. Only drive
  /// attachments enter this state.
  downloading,
  uploading,
  uploadFailed,
  succeed
}

extension UploadFileStatusExtension on UploadFileStatus {
  bool get completed =>
      this == UploadFileStatus.uploadFailed || this == UploadFileStatus.succeed;
}