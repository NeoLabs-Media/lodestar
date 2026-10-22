import 'dart:typed_data';

import 'package:sqlite3/wasm.dart';
import 'package:typed_data/typed_buffers.dart';

WasmSqlite3? _sqlite;
InMemoryFileSystem? _fs;

CommonDatabase openFile(String path, {bool readOnly = false}) =>
    throw UnsupportedError('Files are not available in the browser');

/// Opens a catalog.db held in memory (fetched as an asset) with sqlite3 compiled to WebAssembly.
Future<CommonDatabase> openBytes(Uint8List bytes) async {
  _sqlite ??= await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  if (_fs == null) {
    _fs = InMemoryFileSystem();
    _sqlite!.registerVirtualFileSystem(_fs!, makeDefault: true);
  }
  final buf = Uint8Buffer()..addAll(bytes);
  _fs!.fileData['/catalog.db'] = buf;
  return _sqlite!.open('/catalog.db', mode: OpenMode.readOnly);
}
