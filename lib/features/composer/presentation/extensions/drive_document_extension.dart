import 'package:workplace/domain/entity/drive_document.dart';

/// How a picked drive document can be attached.
///
/// The two are exclusive by construction: a document carrying both links is a
/// link, because a live document is worth more than a static copy.
extension DriveDocumentExtension on DriveDocument {
  /// Attachable as a link card pointing back at the live document.
  bool isAttachableAsLink({required bool requireHttps}) {
    final link = sharingLink;
    return link != null && (!requireHttps || link.isScheme('https'));
  }

  /// Attachable only as a downloaded copy: no sharing link to point at.
  bool isAttachableAsDownload({required bool requireHttps}) {
    final link = downloadLink;
    return sharingLink == null &&
        link != null &&
        (!requireHttps || link.isScheme('https'));
  }
}
