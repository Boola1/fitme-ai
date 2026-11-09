/// Photos and settings kept on the device: files on Android, IndexedDB in the browser.
///
/// Both versions export the same API: `LocalFiles` and `clearBrowserQuery`.
library;

export 'local_files_io.dart' if (dart.library.js_interop) 'local_files_web.dart';
