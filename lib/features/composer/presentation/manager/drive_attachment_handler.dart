import 'package:core/core.dart';
import 'package:core/utils/html/file_link_card_html_builder.dart';
import 'package:tmail_ui_user/main/localizations/app_localizations.dart';
import 'package:tmail_ui_user/main/routes/route_navigation.dart';
import 'package:tmail_ui_user/main/utils/toast_manager.dart';
import 'package:workplace/domain/entity/drive_document.dart';
import 'package:workplace/presentation/model/drive_pick_state.dart';

/// Inserts [html] into the composer's editor.
typedef InsertHtmlCallback = Future<void> Function(String html);

/// Transfers [docs] as real attachments, returning whether it took them.
typedef TransferDriveDocumentsCallback = Future<bool> Function(List<DriveDocument> docs);

class DriveAttachmentHandler {
  DriveAttachmentHandler();

  static const _fallbackOpenInDriveLabel = 'Open in drive';

  /// Whether non-https sharing/thumbnail links should be rejected.
  bool get requireHttps => BuildUtils.isReleaseMode;

  /// Splits picked documents by how they can be attached and dispatches each
  /// half.
  ///
  /// [transferDriveDocuments] downloads and attaches the documents that carry
  /// only a `downloadLink`. It declines on platforms with no staging strategy,
  /// and those documents then fall back to the "not available yet" message.
  Future<void> handleDrivePickResult(
    List<DriveDocument> result, {
    required InsertHtmlCallback insertHtml,
    required TransferDriveDocumentsCallback transferDriveDocuments,
    AppLocalizations? appLocalizations,
  }) async {
    if (result.isEmpty) {
      getBinding<ToastManager>()?.showMessageFailure(
        DrivePickFailure(
          Exception(),
          message: appLocalizations?.driveNoValidAttachment,
        ),
      );
      return;
    }
    final linkDocs = result.where((doc) {
      final link = doc.sharingLink;
      return link != null && (!requireHttps || link.isScheme('https'));
    }).toList();
    // Exclusive with linkDocs by construction: a document carrying both links
    // is a link, because a live document is worth more than a static copy.
    final downloadableDocs = result.where((doc) {
      final downloadLink = doc.downloadLink;
      return doc.sharingLink == null &&
          downloadLink != null &&
          (!requireHttps || downloadLink.isScheme('https'));
    }).toList();

    // Both halves are dispatched: a mixed pick inserts its links and transfers
    // its downloadable docs.
    if (linkDocs.isNotEmpty) {
      await insertDriveLinkHtml(
        linkDocs,
        insertHtml: insertHtml,
        appLocalizations: appLocalizations,
      );
    }

    final transfersStarted = downloadableDocs.isNotEmpty &&
        await transferDriveDocuments(downloadableDocs);

    if (linkDocs.isNotEmpty || transfersStarted) return;

    getBinding<ToastManager>()?.showMessageFailure(DrivePickFailure(
      Exception(),
      message: appLocalizations?.driveAttachmentInDevelopment,
    ));
  }

  Future<void> insertDriveLinkHtml(
    List<DriveDocument> docs, {
    required InsertHtmlCallback insertHtml,
    AppLocalizations? appLocalizations,
  }) async {
    await insertHtml(
      buildDriveLinksHtml(docs, appLocalizations: appLocalizations),
    );
  }

  String buildDriveLinksHtml(
    List<DriveDocument> docs, {
    AppLocalizations? appLocalizations,
  }) {
    final cards = docs
        .map(
          (doc) => _driveFileCard(
            doc,
            appLocalizations: appLocalizations,
          ),
        )
        .nonNulls
        .toList();
    return FileLinkCardHtmlBuilder.wrapFileCardsHtml(cards);
  }

  String? _driveFileCard(
    DriveDocument doc, {
    AppLocalizations? appLocalizations,
  }) {
    final link = doc.sharingLink;
    if (link == null) return null;
    if (requireHttps && !link.isScheme('https')) return null;

    final openInDriveLabel =
        appLocalizations?.openInDrive ?? _fallbackOpenInDriveLabel;
    final trustedThumbnailUrl = _trustedThumbnailUrl(doc);

    return FileLinkCardHtmlBuilder.buildFileLinkCard(
      FileLinkCardContent(
        href: link.toString(),
        title: doc.name,
        actionLabel: openInDriveLabel,
        iconZoneHtml: FileLinkCardHtmlBuilder.buildFileCardIconZone(
          imageUrl: trustedThumbnailUrl?.toString(),
        ),
      ),
    );
  }

  Uri? _trustedThumbnailUrl(DriveDocument doc) {
    final thumbnailUrl = doc.thumbnail?.link;
    if (thumbnailUrl == null) return null;
    if (!thumbnailUrl.isScheme('https') && requireHttps) {
      return null;
    }

    return thumbnailUrl;
  }
}
