@TestOn('chrome')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:workplace/data/datasource/drive_transfer/opfs_file_ops.dart';
import 'package:workplace/domain/exceptions/workplace_exceptions.dart';

class _OpfsFileOpsUnderTest extends OpfsFileOps {}

Future<web.FileSystemDirectoryHandle> _opfsRoot() =>
    web.window.navigator.storage.getDirectory().toDart;

Future<List<String>> _rootEntryNames() async {
  final root = await _opfsRoot();
  final iterator = (root as JSObject).callMethod<JSObject>('keys'.toJS);
  final names = <String>[];
  while (true) {
    final step =
        await (iterator.callMethod<JSPromise<JSObject>>('next'.toJS)).toDart;
    if ((step['done'] as JSBoolean).toDart) break;
    names.add((step['value'] as JSString).toDart);
  }
  return names;
}

void main() {
  late _OpfsFileOpsUnderTest fileOps;

  setUp(() => fileOps = _OpfsFileOpsUnderTest());

  Future<void> createEntry(String name) async {
    final handle = await fileOps.createTempFile(name);
    final writable = await fileOps.openWritable(handle);
    await fileOps.writeChunk(writable, Uint8List.fromList([1, 2, 3]));
    await fileOps.closeWritable(writable);
  }

  group('OpfsFileOps.purgeAllTempFiles', () {
    test('Should remove staging entries whatever their age', () async {
      final freshName = '$opfsTempFilePrefix${DateTime.now().microsecondsSinceEpoch}_fresh';
      await createEntry(freshName);
      expect(await _rootEntryNames(), contains(freshName));

      await fileOps.purgeAllTempFiles();

      expect(await _rootEntryNames(), isNot(contains(freshName)));
    });

    test('Should leave entries this package does not own alone', () async {
      const foreignName = 'someone_elses_data';
      final root = await _opfsRoot();
      await root
          .getFileHandle(foreignName, web.FileSystemGetFileOptions(create: true))
          .toDart;
      addTearDown(() async => (await _opfsRoot()).removeEntry(foreignName).toDart);

      await fileOps.purgeAllTempFiles();

      expect(await _rootEntryNames(), contains(foreignName));
    });
  });

  group('OpfsFileOps quota probe', () {
    test('Should surface a non-quota write failure unchanged', () async {
      final handle = await fileOps.createTempFile(
          '$opfsTempFilePrefix${DateTime.now().microsecondsSinceEpoch}_closed');
      final writable = await fileOps.openWritable(handle);
      await fileOps.closeWritable(writable);
      addTearDown(fileOps.purgeAllTempFiles);

      // Writing to a closed stream is a TypeError, not a quota failure: it
      // must not be mistaken for exhausted storage.
      await expectLater(
        fileOps.writeChunk(writable, Uint8List.fromList([1])),
        throwsA(isNot(isA<DriveStagingQuotaExceededException>())),
      );
    });
  });
}
