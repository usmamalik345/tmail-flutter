import 'package:flutter_test/flutter_test.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/drive_transfer_byte_guard.dart';
import 'package:workplace/domain/exceptions/workplace_exceptions.dart';

void main() {
  group('DriveTransferByteGuard::', () {
    test('Should allow up to the fallback budget when the server advertises no cap', () {
      final progress = DriveTransferByteGuard(budgetBytes: null).trackFile();

      expect(
        () => progress.record(DriveTransferByteGuard.fallbackBudgetBytes),
        returnsNormally,
      );
    });

    test('Should enforce the fallback budget when the server advertises no cap', () {
      final progress = DriveTransferByteGuard(budgetBytes: null).trackFile();

      expect(
        () => progress.record(DriveTransferByteGuard.fallbackBudgetBytes + 1),
        throwsA(isA<DriveTransferBudgetExceededException>()),
      );
    });

    test('Should allow a file that stays inside the budget', () {
      final progress = DriveTransferByteGuard(budgetBytes: 100).trackFile();

      progress.record(40);
      progress.record(80);

      expect(() => progress.record(100), returnsNormally);
    });

    test('Should throw once a single file passes the budget', () {
      final progress = DriveTransferByteGuard(budgetBytes: 100).trackFile();

      progress.record(90);

      expect(
        () => progress.record(101),
        throwsA(isA<DriveTransferBudgetExceededException>()),
      );
    });

    test('Should count each file once, not its cumulative reports', () {
      // Both files report cumulatively for themselves. Summing raw cumulative
      // values would reach 30+30+60+60 = 180 and abort a batch that only ever
      // received 120 bytes.
      final guard = DriveTransferByteGuard(budgetBytes: 150);
      final first = guard.trackFile();
      final second = guard.trackFile();

      first.record(30);
      second.record(30);
      first.record(60);

      expect(() => second.record(60), returnsNormally);
    });

    test('Should budget concurrent files against one shared total', () {
      final guard = DriveTransferByteGuard(budgetBytes: 100);
      final first = guard.trackFile();
      final second = guard.trackFile();

      first.record(60);

      // Fits on its own, but not alongside its sibling.
      expect(
        () => second.record(50),
        throwsA(isA<DriveTransferBudgetExceededException>()),
      );
    });

    test('Should ignore a progress report that does not advance', () {
      final guard = DriveTransferByteGuard(budgetBytes: 100);
      final progress = guard.trackFile();

      progress.record(100);
      // A repeated or out-of-order callback must not re-add bytes already
      // counted, which would trip the guard on a download that fit.
      expect(() => progress.record(100), returnsNormally);
      expect(() => progress.record(90), returnsNormally);
    });

    test('Should not re-charge bytes when progress dips then recovers', () {
      final guard = DriveTransferByteGuard(budgetBytes: 100);
      final progress = guard.trackFile();

      progress.record(100);
      progress.record(90);
      // Only 100 bytes ever arrived, so climbing back to 100 must not push the
      // batch over its budget.
      expect(() => progress.record(100), returnsNormally);
    });

    test('Should report both sides of the breach', () {
      final progress = DriveTransferByteGuard(budgetBytes: 100).trackFile();

      expect(
        () => progress.record(150),
        throwsA(
          isA<DriveTransferBudgetExceededException>()
              .having((e) => e.receivedBytes, 'receivedBytes', 150)
              .having((e) => e.budgetBytes, 'budgetBytes', 100),
        ),
      );
    });
  });
}
