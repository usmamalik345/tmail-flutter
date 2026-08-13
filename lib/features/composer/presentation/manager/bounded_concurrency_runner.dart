import 'dart:async';

/// Runs [task] over [items] with at most [maxConcurrent] in flight.
///
/// Workers pull from one shared iterator, so a slot frees the instant its
/// current item finishes — no "start a batch, wait for all of it, start the
/// next" stalling. [task] is expected to handle its own failures; an error it
/// lets escape aborts that worker only, and the others keep draining.
Future<void> runWithConcurrency<T>(
  Iterable<T> items,
  int maxConcurrent,
  Future<void> Function(T item) task,
) async {
  final iterator = items.iterator;

  Future<void> worker() async {
    while (iterator.moveNext()) {
      await task(iterator.current);
    }
  }

  final workerCount = maxConcurrent < 1 ? 1 : maxConcurrent;
  await Future.wait(List.generate(workerCount, (_) => worker()));
}
