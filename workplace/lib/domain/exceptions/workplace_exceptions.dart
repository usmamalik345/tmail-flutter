class WorkplaceCreateIntentException implements Exception {}

class WorkplaceExchangeTokenException implements Exception {}

class DriveIntentErrorException implements Exception {}

class DriveIntentPageLoadException implements Exception {
  final String reason;

  DriveIntentPageLoadException(this.reason);

  @override
  String toString() => 'DriveIntentPageLoadException: $reason';
}

class DriveIntentTimeoutException implements Exception {}

class WorkplaceNoIntentClientException implements Exception {}

class DriveDownloadNullAttachmentException implements Exception {}

class DriveDownloadInsecureLinkException implements Exception {}

class DriveDownloadEmptyResponseException implements Exception {}

/// The browser refused a staging write because the origin's storage quota is
/// exhausted. Distinguished from a network or CORS failure so it can be
/// reported rather than lost among ordinary transfer errors.
class DriveStagingQuotaExceededException implements Exception {
  final Object? cause;

  DriveStagingQuotaExceededException([this.cause]);

  @override
  String toString() => 'DriveStagingQuotaExceededException: $cause';
}

/// The response body ended before the declared `content-length` was reached,
/// so the staged file is a truncated copy of the document.
class DriveDownloadIncompleteException implements Exception {
  final int received;
  final int expected;

  DriveDownloadIncompleteException({
    required this.received,
    required this.expected,
  });

  @override
  String toString() =>
      'DriveDownloadIncompleteException: received $received of $expected bytes';
}
