import 'package:core/core.dart';
import 'package:core/utils/html/file_link_card_html_builder.dart';
import 'package:tmail_ui_user/features/composer/presentation/extensions/drive_document_extension.dart';
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
      _showFailureToast(appLocalizations?.driveNoValidAttachment);
      return;
    }
    final linkDocs = <DriveDocument>[];
    final downloadableDocs = <DriveDocument>[];
    for (final doc in result) {
      if (doc.isAttachableAsLink(requireHttps: requireHttps)) linkDocs.add(doc);
      if (doc.isAttachableAsDownload(requireHttps: requireHttps)) {
        downloadableDocs.add(doc);
      }
    }

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

    _showFailureToast(appLocalizations?.driveAttachmentInDevelopment);
  }

  /// Toasts [message], or logs when there is no [ToastManager] bound: a pick
  /// that ends with nothing attached must not also end silently.
  void _showFailureToast(String? message) {
    final toastManager = getBinding<ToastManager>();
    if (toastManager == null) {
      logWarning(
        'DriveAttachmentHandler::_showFailureToast: no ToastManager bound, '
        'failure not shown to the user',
      );
      return;
    }
    toastManager.showMessageFailure(
      DrivePickFailure(Exception(), message: message),
    );
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
    if (!doc.isAttachableAsLink(requireHttps: requireHttps)) return null;
    final link = doc.sharingLink!;

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
