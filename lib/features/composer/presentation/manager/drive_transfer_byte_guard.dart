import 'package:tmail_ui_user/main/utils/app_config.dart';
import 'package:workplace/domain/exceptions/workplace_exceptions.dart';

/// Budgets the bytes a batch actually receives, across all of its concurrent
/// downloads.
///
/// The declared-size gate runs on `DriveDocument.size`, which is backend
/// metadata and can lie — an export-on-demand document may report `0` — so
/// what actually arrives is budgeted too.
///
/// Each file reports progress *cumulatively for itself*, so a shared total can
/// only be kept by adding each file's delta: summing raw cumulative values
/// would double-count and abort valid downloads early. [trackFile] hands each
/// file the small piece of state that turns its cumulative counts into deltas.
class DriveTransferByteGuard {
  DriveTransferByteGuard({required int? budgetBytes})
      : budgetBytes = budgetBytes ?? fallbackBudgetBytes;

  /// Budget when the server advertises no `maxSizeAttachmentsPerEmail`: with
  /// no cap *and* an unreliable declared size, a download would otherwise be
  /// unbounded.
  ///
  /// Scoped to this guard — it bounds one batch's received bytes, and does not
  /// make the email-size check (`AttachmentSizeLimitPolicy`) capped-when-absent
  /// for any attachment source.
  static const int fallbackBudgetBytes =
      AppConfig.fallbackMaxAttachmentsPerEmailInMegabytes * 1024 * 1024;

  final int budgetBytes;

  int _receivedBytes = 0;

  DriveTransferFileByteProgress trackFile() =>
      DriveTransferFileByteProgress(this);

  /// Check and increment run with no `await` between them, so on Dart's
  /// single-threaded event loop concurrent files cannot interleave — the
  /// worst overshoot is one in-flight chunk per file.
  void _add(int deltaBytes) {
    _receivedBytes += deltaBytes;
    if (_receivedBytes > budgetBytes) {
      throw DriveTransferBudgetExceededException(
        receivedBytes: _receivedBytes,
        budgetBytes: budgetBytes,
      );
    }
  }
}

/// One file's contribution to its batch's [DriveTransferByteGuard].
class DriveTransferFileByteProgress {
  DriveTransferFileByteProgress(this._guard);

  final DriveTransferByteGuard _guard;
  int _previousReceivedBytes = 0;

  /// Throws [DriveTransferBudgetExceededException] once the batch passes its
  /// budget, which the pipeline catches as an ordinary per-file failure.
  ///
  /// The baseline only ever moves up: a callback reporting less than the
  /// highest value seen is ignored, so bytes already charged are not charged
  /// again when progress recovers.
  void record(int cumulativeReceivedBytes) {
    final delta = cumulativeReceivedBytes - _previousReceivedBytes;
    if (delta <= 0) return;

    _previousReceivedBytes = cumulativeReceivedBytes;
    _guard._add(delta);
  }
}
