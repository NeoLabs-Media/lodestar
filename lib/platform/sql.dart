// Picks the SQLite backend: native FFI (macOS/iOS/…) or WebAssembly in the browser.
export 'sql_native.dart' if (dart.library.js_interop) 'sql_web.dart';
