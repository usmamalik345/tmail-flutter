import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tmail_ui_user/features/composer/presentation/manager/bounded_concurrency_runner.dart';

/// Completes every completer that is still pending, on a snapshot of the list
/// so a task started by one completion cannot mutate it mid-iteration.
void _completePending(List<Completer<void>> completers) {
  for (final completer in List.of(completers)) {
    if (!completer.isCompleted) completer.complete();
  }
}

/// Runs [items] at [maxConcurrent] and returns them in completion order.
Future<List<int>> _collectProcessed(List<int> items, int maxConcurrent) async {
  final processed = <int>[];
  await runWithConcurrency(items, maxConcurrent, (item) async => processed.add(item));
  return processed;
}

/// Yields two items and then fails, so the failure lands while the runner is
/// still spawning its first wave of workers.
Iterable<int> _itemsThatFailWhileSpawning() sync* {
  yield 0;
  yield 1;
  throw const FormatException('iterable boom');
}

/// Runs [body] with its uncaught async errors captured instead of crashing the
/// test, and returns them. The trailing settle lets a future that failed with
/// no listener be reported before the zone is torn down.
Future<List<Object>> _escapedErrorsOf(Future<void> Function() body) async {
  final escaped = <Object>[];
  await runZonedGuarded(
    () async {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    },
    (error, _) => escaped.add(error),
  );
  return escaped;
}

void main() {
  group('runWithConcurrency::', () {
    test('Should process every item exactly once', () async {
      final processed =
          await _collectProcessed(List.generate(100, (index) => index), 5);

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
      // the next items. A regression that stops pulling queued items would
      // spin here forever, so cap the waves rather than hang the suite.
      var waves = 0;
      while (completers.length < itemCount) {
        expect(
          waves++,
          lessThan(itemCount),
          reason: 'workers stopped pulling queued items',
        );

        _completePending(completers);

        await Future<void>.delayed(Duration.zero);
      }

      // Release the final wave.
      _completePending(completers);

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

    // Workers share one iterator, so a lazy source must be pulled exactly once
    // per item — never restarted, never double-produced.
    test('Should pull a lazy iterable once per item', () async {
      var produced = 0;

      Iterable<int> lazyItems() sync* {
        for (var index = 0; index < 5; index++) {
          produced++;
          yield index;
        }
      }

      final processed = <int>[];
      await runWithConcurrency(
        lazyItems(),
        2,
        (item) async => processed.add(item),
      );

      expect(produced, 5);
      expect(processed, hasLength(5));
      expect(processed.toSet(), hasLength(5));
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

    // A concurrency outside [1, itemCount] must still drain the batch exactly
    // once, whether it is clamped up to one worker or down to one per item.
    const outOfRangeConcurrencies = {
      0: 'below one',
      -1: 'negative',
      100: 'above the item count',
      1 << 30: 'huge',
    };

    for (final entry in outOfRangeConcurrencies.entries) {
      test('Should drain every item when maxConcurrent is ${entry.value}', () async {
        final processed = await _collectProcessed([0, 1, 2], entry.key);

        expect(processed, containsAllInOrder([0, 1, 2]));
        expect(processed, hasLength(3));
      });
    }

    test('Should drain a large batch under a large concurrency', () async {
      const itemCount = 20000;
      const maxConcurrent = 2000;

      var inFlight = 0;
      var peakInFlight = 0;
      final processed = <int>[];

      await runWithConcurrency(
        List.generate(itemCount, (index) => index),
        maxConcurrent,
        (item) async {
          inFlight++;
          peakInFlight = inFlight > peakInFlight ? inFlight : peakInFlight;

          await Future<void>.delayed(Duration.zero);
          processed.add(item);

          inFlight--;
        },
      );

      expect(processed, hasLength(itemCount));
      expect(processed.toSet(), hasLength(itemCount));
      // Exactly the cap, not merely under it: the first wave of workers is
      // spawned synchronously, so a runner that quietly went serial fails here.
      expect(peakInFlight, maxConcurrent);
    });
  });

  // What a failure does to the rest of the batch. These lock in the current
  // contract — a task is expected to handle its own failures — so a change of
  // heart about that has to change these tests too.
  group('runWithConcurrency error contract::', () {
    test('Should keep the other workers draining when one task throws',
        () async {
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

      // The dead worker's share of the queue is picked up by the survivor, and
      // the item it died on is never retried.
      expect(processed, [1, 2, 3]);
    });

    // The runner has no worker of its own to fall back on: once every worker
    // has thrown, whatever is left in the iterator is silently abandoned. The
    // caller is what must keep its task from throwing.
    test('Should abandon the queue when every worker has died', () async {
      final processed = <int>[];

      await expectLater(
        runWithConcurrency(
          [0, 1, 2, 3, 4, 5],
          2,
          (item) async {
            processed.add(item);
            if (item < 2) throw StateError('boom$item');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(processed, [0, 1], reason: 'items 2..5 are dropped, not retried');
    });

    // Same rule at its harshest: one worker means one throw ends the batch,
    // however far in the queue it happens.
    test('Should abandon the queue when the only worker dies mid-drain',
        () async {
      final processed = <int>[];

      await expectLater(
        runWithConcurrency(
          [0, 1, 2, 3],
          1,
          (item) async {
            processed.add(item);
            if (item == 2) throw StateError('boom');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(processed, [0, 1, 2], reason: 'item 3 is dropped, not retried');
    });

    // Only one failure can come back through a single future. The one that
    // surfaces is the first to *arrive*, not the first in item order, and the
    // rest are consumed rather than left to crash the zone.
    test('Should surface the first error to arrive and consume the rest',
        () async {
      final slowItemGate = Completer<void>();
      Object? surfaced;

      final escaped = await _escapedErrorsOf(() async {
        final run = runWithConcurrency(
          [0, 1],
          2,
          (item) async {
            if (item == 0) {
              await slowItemGate.future;
              throw StateError('slow failure, first item');
            }
            throw const FormatException('fast failure, second item');
          },
        );

        // Let the second item fail before the first one is released.
        await Future<void>.delayed(Duration.zero);
        slowItemGate.complete();

        try {
          await run;
        } catch (error) {
          surfaced = error;
        }
      });

      expect(surfaced, isA<FormatException>());
      expect(escaped, isEmpty);
    });

    test('Should report a task that throws synchronously through the future',
        () async {
      final processed = <int>[];

      await expectLater(
        runWithConcurrency(
          [0, 1, 2],
          2,
          // Not an `async` closure: it throws before ever returning a future.
          (item) {
            if (item == 0) throw StateError('sync boom');
            processed.add(item);
            return Future<void>.value();
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(processed, [1, 2]);
    });

    // A failure raised by the iterable itself (a lazy source, not the
    // materialised list callers are expected to pass) surfaces through the
    // returned future like any other spawn-time error, and the workers
    // already started for the items pulled before it are drained rather than
    // left to fail into the zone.
    test(
        'Should drain already-started workers when the iterable fails while spawning',
        () async {
      final processed = <int>[];

      final escaped = await _escapedErrorsOf(() async {
        await expectLater(
          runWithConcurrency(
            _itemsThatFailWhileSpawning(),
            4,
            (item) async {
              processed.add(item);
              await Future<void>.delayed(Duration.zero);
              if (item == 0) throw StateError('must not escape');
            },
          ),
          throwsA(isA<FormatException>()),
        );
      });

      expect(processed, [0, 1], reason: 'both workers had already started');
      expect(escaped, isEmpty,
          reason: 'already-started workers are drained, not orphaned');
    });

    // The shared iterator is a plain list iterator, so mutating the source
    // mid-run kills the worker that notices.
    test('Should surface a concurrent modification of the source list',
        () async {
      final items = [0, 1, 2, 3, 4];
      final processed = <int>[];

      await expectLater(
        runWithConcurrency(
          items,
          1,
          (item) async {
            processed.add(item);
            if (item == 0) items.removeLast();
          },
        ),
        throwsA(isA<ConcurrentModificationError>()),
      );

      expect(processed, [0]);
    });
  });
}
