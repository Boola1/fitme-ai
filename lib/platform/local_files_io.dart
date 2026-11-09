import 'dart:io';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Named files in the app documents folder.
class LocalFiles {
  LocalFiles._();

  static Future<File> _file(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  static Future<bool> exists(String name) async => (await _file(name)).exists();

  static Future<Uint8List?> readBytes(String name) async {
    final file = await _file(name);
    return await file.exists() ? file.readAsBytes() : null;
  }

  static Future<void> writeBytes(String name, List<int> bytes) async {
    await (await _file(name)).writeAsBytes(bytes, flush: true);
  }

  static Future<void> delete(String name) async {
    final file = await _file(name);
    if (await file.exists()) await file.delete();
  }

  static Future<void> rename(String from, String to) async {
    await (await _file(from)).rename((await _file(to)).path);
  }

  static Future<List<String>> list(String prefix) async {
    final dir = await getApplicationDocumentsDirectory();
    return [
      await for (final entity in dir.list())
        if (entity is File && entity.uri.pathSegments.last.startsWith(prefix))
          entity.uri.pathSegments.last,
    ];
  }

  /// The saved file as an XFile, or null when it does not exist.
  static Future<XFile?> open(String name) async {
    final file = await _file(name);
    return await file.exists() ? XFile(file.path) : null;
  }
}

/// Only the browser has an address bar to clean up.
void clearBrowserQuery() {}
