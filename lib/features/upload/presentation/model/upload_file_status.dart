
enum UploadFileStatus {
  waiting,
  /// Staging leg of a drive transfer, before its upload starts.
  fetching,
  uploading,
  uploadFailed,
  succeed
}

extension UploadFileStatusExtension on UploadFileStatus {
  bool get completed =>
      this == UploadFileStatus.uploadFailed || this == UploadFileStatus.succeed;
}