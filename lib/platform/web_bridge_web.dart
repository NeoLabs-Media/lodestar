import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

String? takePendingImport() {
  final v = globalContext.getProperty<JSAny?>('__lodestarImport'.toJS);
  if (v == null || v.isUndefinedOrNull) return null;
  globalContext.setProperty('__lodestarImport'.toJS, null);
  return (v as JSString).toDart;
}

void openInNewTab(String relativeUrl) =>
    web.window.open(Uri.base.resolve(relativeUrl).toString(), '_blank');
