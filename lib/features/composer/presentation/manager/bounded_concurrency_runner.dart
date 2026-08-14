import 'dart:async';

/// Runs [task] over [items] with at most [maxConcurrent] in flight.
///
/// Workers pull from one shared iterator, so a slot frees the instant its
/// current item finishes — no "start a batch, wait for all of it, start the
/// next" stalling. [task] is expected to handle its own failures; an error it
/// lets escape aborts that worker only, and the others keep draining.
///
/// A worker is only spawned once there is an item for it to own, so an
/// oversized [maxConcurrent] costs nothing: the worker count never exceeds the
/// item count.
Future<void> runWithConcurrency<T>(
  Iterable<T> items,
  int maxConcurrent,
  Future<void> Function(T item) task,
) {
  final iterator = items.iterator;
  final maxWorkers = maxConcurrent < 1 ? 1 : maxConcurrent;
  final workers = <Future<void>>[];
  while (workers.length < maxWorkers && iterator.moveNext()) {
    workers.add(_drainQueue(iterator.current, iterator, task));
  }
  return Future.wait(workers);
}

/// One worker: runs [first], then pulls from the shared [iterator] until it is
/// exhausted.
Future<void> _drainQueue<T>(
  T first,
  Iterator<T> iterator,
  Future<void> Function(T item) task,
) async {
  await task(first);
  while (iterator.moveNext()) {
    await task(iterator.current);
  }
}
