import 'dart:js_interop';
import 'dart:typed_data';

import 'package:core/utils/app_logger.dart';
import 'package:web/web.dart' as web;
import 'package:workplace/data/datasource/drive_transfer/opfs_file_handle.dart';
import 'package:workplace/data/datasource/drive_transfer/opfs_store.dart';
import 'package:workplace/domain/exceptions/workplace_exceptions.dart';

/// Marks an OPFS entry as this package's, so [OpfsFileOps.sweepStaleTempFiles]
/// leaves the origin's other data alone.
const opfsTempFilePrefix = 'tmail_drive_';

/// `FileSystemDirectoryHandle.keys()` — the only way to enumerate OPFS
/// entries, and `package:web` ships no binding for it.
extension type _DirectoryHandleKeys(JSObject _) implements JSObject {
  external _AsyncStringIterator keys();
}

extension type _AsyncStringIterator(JSObject _) implements JSObject {
  external JSPromise<_AsyncIterationResult> next();
}

/// `package:web`'s `DOMException` is an extension type over [JSObject], so a
/// caught quota error can only be recognised by reading its `name`.
extension type _JsErrorName(JSObject _) implements JSObject {
  external String? get name;
}

extension on Object {
  /// True when this is a JS `DOMException` reporting an exhausted quota.
  bool get isQuotaExceededError {
    final jsError = this;
    if (jsError is! JSObject) return false;
    return _JsErrorName(jsError).name == 'QuotaExceededError';
  }
}

extension type _AsyncIterationResult(JSObject _) implements JSObject {
  external bool get done;

  external String? get value;
}

/// Creating, writing, reading back and removing OPFS staging entries.
class OpfsFileOps implements OpfsStore {
  Future<web.FileSystemDirectoryHandle> _opfsRoot() =>
      web.window.navigator.storage.getDirectory().toDart;

  @override
  Future<web.FileSystemFileHandle> createTempFile(String fileName) async {
    final root = await _opfsRoot();
    return root
        .getFileHandle(fileName, web.FileSystemGetFileOptions(create: true))
        .toDart;
  }

  /// The `web.File` snapshot the uploader sends. Kept here so narrowing
  /// [OpfsFileHandle] to its web type is the bindings' job alone.
  @override
  Future<web.File> getFile(OpfsFileHandle fileHandle) =>
      (fileHandle as web.FileSystemFileHandle).getFile().toDart;

  /// The first [maxBytes] of [file], for charset detection. Sliced rather than
  /// read whole: the staged document is only ever meant to reach the JS heap
  /// one chunk at a time.
  @override
  Future<Uint8List> readFilePrefix(web.File file, int maxBytes) async {
    final buffer = await file.slice(0, maxBytes).arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  }

  @override
  Future<web.FileSystemWritableFileStream> openWritable(
      web.FileSystemFileHandle handle) =>
      handle.createWritable().toDart;

  @override
  Future<void> writeChunk(
          web.FileSystemWritableFileStream stream, Uint8List chunk) =>
      _mappingQuotaError(() => stream.write(chunk.toJS).toDart);

  @override
  Future<void> closeWritable(web.FileSystemWritableFileStream stream) =>
      _mappingQuotaError(() => stream.close().toDart);

  /// A full quota surfaces as a raw JS `DOMException`, indistinguishable at
  /// every layer above from a CORS or DNS failure unless it is typed here.
  /// `package:web`'s `DOMException` is an extension type over `JSObject`, so
  /// this is a name probe rather than a Dart `is` check.
  Future<void> _mappingQuotaError(Future<void> Function() write) async {
    try {
      await write();
    } catch (error) {
      if (error.isQuotaExceededError) {
        throw DriveStagingQuotaExceededException(error);
      }
      rethrow;
    }
  }

  @override
  Future<void> abortWritable(web.FileSystemWritableFileStream stream) =>
      stream.abort().toDart;

  @override
  Future<void> removeTempFile(String fileName) async {
    final root = await _opfsRoot();
    await root.removeEntry(fileName).toDart;
  }

  /// Removes staging entries left behind by a tab that died mid-transfer:
  /// OPFS is persistent, and neither `OpfsStagedFile.dispose()` nor the
  /// stager's failure cleanup runs on a crash.
  ///
  /// [olderThan] keeps the sweep safe while another tab of the same origin is
  /// mid-transfer — its entries are minutes old, orders of magnitude inside the
  /// window even at four hours. Per-entry failures are logged, never rethrown.
  @override
  Future<void> sweepStaleTempFiles({
    Duration olderThan = const Duration(hours: 4),
  }) async {
    final root = await _opfsRoot();
    final cutoff = DateTime.now().subtract(olderThan);
    final staleNames = await _listTempFileNames(
      root,
      where: (name) => _isStaleTempFile(name, cutoff),
    );
    for (final name in staleNames) {
      try {
        await root.removeEntry(name).toDart;
      } catch (e) {
        logWarning('OpfsFileOps: failed to sweep stale temp file $name: $e');
      }
    }
  }

  /// Removes every staging entry regardless of age.
  ///
  /// Staged documents are persistent and origin-scoped, so without this they
  /// outlive a logout and carry into the next account's session. Stays scoped
  /// to [opfsTempFilePrefix] so it can never touch the origin's other data.
  /// An entry another tab holds open fails its removal — logged and skipped;
  /// logout is global by intent.
  Future<void> purgeAllTempFiles() async {
    final root = await _opfsRoot();
    for (final name in await _listTempFileNames(root)) {
      try {
        await root.removeEntry(name).toDart;
      } catch (e) {
        logWarning('OpfsFileOps: failed to purge temp file $name: $e');
      }
    }
  }

  /// Collected before removing anything: removing entries while iterating the
  /// same directory is not guaranteed to leave the iteration stable, which can
  /// skip entries.
  Future<List<String>> _listTempFileNames(
    web.FileSystemDirectoryHandle root, {
    bool Function(String name)? where,
  }) async {
    final iterator = (root as _DirectoryHandleKeys).keys();
    final names = <String>[];
    while (true) {
      final step = await iterator.next().toDart;
      if (step.done) break;
      final name = step.value;
      if (name == null || !name.startsWith(opfsTempFilePrefix)) continue;
      if (where != null && !where(name)) continue;
      names.add(name);
    }
    return names;
  }

  /// Names are `<prefix><microsSinceEpoch>_...`. A name that doesn't parse is
  /// left alone.
  static bool _isStaleTempFile(String name, DateTime cutoff) {
    if (!name.startsWith(opfsTempFilePrefix)) return false;
    final micros = int.tryParse(
        name.substring(opfsTempFilePrefix.length).split('_').first);
    if (micros == null) return false;
    return DateTime.fromMicrosecondsSinceEpoch(micros).isBefore(cutoff);
  }
}
