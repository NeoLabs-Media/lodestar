import 'dart:typed_data';

import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart' as native;

CommonDatabase openFile(String path, {bool readOnly = false}) =>
    native.sqlite3.open(path, mode: readOnly ? native.OpenMode.readOnly : native.OpenMode.readWriteCreate);

Future<CommonDatabase> openBytes(Uint8List bytes) =>
    throw UnsupportedError('openBytes is only used on the web');
