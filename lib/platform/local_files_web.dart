import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:web/web.dart' as web;

/// Named blobs in IndexedDB (photos are too large for localStorage).
class LocalFiles {
  LocalFiles._();

  static const _dbName = 'fitme';
  static const _storeName = 'files';
  static Future<web.IDBDatabase>? _database;

  static Future<web.IDBDatabase> _open() {
    return _database ??= () {
      final done = Completer<web.IDBDatabase>();
      final request = web.window.indexedDB.open(_dbName, 1);
      request.onupgradeneeded = ((web.Event _) {
        (request.result as web.IDBDatabase).createObjectStore(_storeName);
      }).toJS;
      request.onsuccess = ((web.Event _) {
        done.complete(request.result as web.IDBDatabase);
      }).toJS;
      request.onerror = ((web.Event _) {
        _database = null;
        done.completeError(StateError('IndexedDB is not available'));
      }).toJS;
      return done.future;
    }();
  }

  static Future<web.IDBObjectStore> _store(String mode) async {
    final db = await _open();
    return db.transaction(_storeName.toJS, mode).objectStore(_storeName);
  }

  static Future<JSAny?> _result(web.IDBRequest request) {
    final done = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) => done.complete(request.result)).toJS;
    request.onerror = ((web.Event _) {
      done.completeError(StateError('IndexedDB request failed'));
    }).toJS;
    return done.future;
  }

  static Future<bool> exists(String name) async {
    final store = await _store('readonly');
    return (await _result(store.getKey(name.toJS))) != null;
  }

  static Future<Uint8List?> readBytes(String name) async {
    final store = await _store('readonly');
    final value = await _result(store.get(name.toJS));
    return value == null ? null : (value as JSUint8Array).toDart;
  }

  static Future<void> writeBytes(String name, List<int> bytes) async {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final store = await _store('readwrite');
    await _result(store.put(data.toJS, name.toJS));
  }

  static Future<void> delete(String name) async {
    final store = await _store('readwrite');
    await _result(store.delete(name.toJS));
  }

  static Future<void> rename(String from, String to) async {
    final bytes = await readBytes(from);
    if (bytes == null) return;
    await writeBytes(to, bytes);
    await delete(from);
  }

  static Future<List<String>> list(String prefix) async {
    final store = await _store('readonly');
    final keys = (await _result(store.getAllKeys())) as JSArray<JSString>;
    return keys.toDart.map((k) => k.toDart).where((k) => k.startsWith(prefix)).toList();
  }

  /// The saved photo as an XFile, or null when it does not exist.
  static Future<XFile?> open(String name) async {
    final bytes = await readBytes(name);
    if (bytes == null) return null;
    final mime = name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    return XFile.fromData(bytes, name: name, mimeType: mime);
  }
}

/// Removes `?key=...` from the address bar once the key has been saved.
void clearBrowserQuery() {
  final location = web.window.location;
  web.window.history.replaceState(null, '', '${location.pathname}${location.hash}');
}
