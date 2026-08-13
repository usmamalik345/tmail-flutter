import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/bounded_concurrency_runner.dart';

void main() {
  group('runWithConcurrency::', () {
    test('Should process every item', () async {
      final processed = <int>[];

      await runWithConcurrency(
        List.generate(10, (index) => index),
        3,
        (item) async {
          processed.add(item);
        },
      );

      expect(processed..sort(), List.generate(10, (index) => index));
    });

    test('Should never exceed maxConcurrent tasks in flight', () async {
      var inFlight = 0;
      var peakInFlight = 0;
      final completers = <Completer<void>>[];

      final run = runWithConcurrency(
        List.generate(9, (index) => index),
        3,
        (item) async {
          inFlight++;
          peakInFlight = inFlight > peakInFlight ? inFlight : peakInFlight;
          final completer = Completer<void>();
          completers.add(completer);
          await completer.future;
          inFlight--;
        },
      );

      // Release the tasks in waves so the pool has to refill its slots.
      while (completers.length < 9 || completers.any((c) => !c.isCompleted)) {
        final pending = completers.where((c) => !c.isCompleted).toList();
        if (pending.isEmpty) break;
        for (final completer in pending) {
          completer.complete();
        }
        await Future<void>.delayed(Duration.zero);
      }
      await run;

      expect(peakInFlight, lessThanOrEqualTo(3));
      expect(completers, hasLength(9));
    });

    test('Should start a queued item as soon as a slot frees', () async {
      final started = <int>[];
      final gate = Completer<void>();

      final run = runWithConcurrency(
        [0, 1, 2],
        1,
        (item) async {
          started.add(item);
          if (item == 0) await gate.future;
        },
      );

      await Future<void>.delayed(Duration.zero);
      expect(started, [0], reason: 'the single slot is taken by the first item');

      gate.complete();
      await run;
      expect(started, [0, 1, 2]);
    });

    test('Should keep other workers running when one task throws', () async {
      final processed = <int>[];

      await expectLater(
        runWithConcurrency(
          [0, 1, 2, 3],
          2,
          (item) async {
            if (item == 0) throw StateError('boom');
            processed.add(item);
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(processed, containsAll([1, 2, 3]));
    });

    test('Should treat a concurrency below one as a single worker', () async {
      final processed = <int>[];

      await runWithConcurrency([0, 1], 0, (item) async => processed.add(item));

      expect(processed, [0, 1]);
    });
  });
}
