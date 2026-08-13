import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/bounded_concurrency_runner.dart';

void main() {
  group('runWithConcurrency::', () {
    test('Should process every item exactly once', () async {
      final processed = <int>[];

      await runWithConcurrency(
        List.generate(100, (index) => index),
        5,
        (item) async {
          processed.add(item);
        },
      );

      expect(processed, hasLength(100));
      expect(processed.toSet(), hasLength(100));
      expect(
        processed.toSet(),
        containsAll(List.generate(100, (index) => index)),
      );
    });

    test('Should never exceed maxConcurrent tasks in flight', () async {
      const maxConcurrent = 3;
      const itemCount = 9;

      var inFlight = 0;
      var peakInFlight = 0;

      final completers = <Completer<void>>[];

      final run = runWithConcurrency(
        List.generate(itemCount, (index) => index),
        maxConcurrent,
        (item) async {
          inFlight++;
          peakInFlight = inFlight > peakInFlight ? inFlight : peakInFlight;

          final completer = Completer<void>();
          completers.add(completer);

          await completer.future;

          inFlight--;
        },
      );

      // Allow the first wave of workers to start.
      await Future<void>.delayed(Duration.zero);

      expect(completers, hasLength(maxConcurrent));
      expect(peakInFlight, maxConcurrent);

      // Release the current tasks so the workers can pick up
      // the next items.
      while (completers.length < itemCount) {
        final pending = completers
            .where((completer) => !completer.isCompleted)
            .toList();

        for (final completer in pending) {
          completer.complete();
        }

        await Future<void>.delayed(Duration.zero);
      }

      // Release the final wave.
      for (final completer in completers) {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }

      await run;

      expect(peakInFlight, lessThanOrEqualTo(maxConcurrent));
      expect(completers, hasLength(itemCount));
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
      final worker1Started = Completer<void>();

      await expectLater(
        runWithConcurrency(
          [0, 1, 2, 3],
          2,
          (item) async {
            if (item == 0) {
              worker1Started.complete();
              throw StateError('boom');
            }

            if (item == 1) {
              processed.add(item);
              await worker1Started.future;
            } else {
              processed.add(item);
            }
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

    test('Should complete when items are empty', () async {
      var taskCalled = false;

      await runWithConcurrency(
        <int>[],
        3,
        (item) async {
          taskCalled = true;
        },
      );

      expect(taskCalled, isFalse);
    });

    test('Should treat negative concurrency as a single worker', () async {
      final processed = <int>[];

      await runWithConcurrency(
        [0, 1, 2],
        -1,
        (item) async => processed.add(item),
      );

      expect(processed, [0, 1, 2]);
    });

    test('Should process all items when maxConcurrent exceeds item count', () async {
      final processed = <int>[];

      await runWithConcurrency(
        [0, 1, 2],
        100,
        (item) async => processed.add(item),
      );

      expect(processed, containsAllInOrder([0, 1, 2]));
      expect(processed, hasLength(3));
    });
  });
}
