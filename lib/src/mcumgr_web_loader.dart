import 'dart:async';

import 'package:web/web.dart' as web;

class McuMgrWebLoader {
  static bool _initialized = false;

  /// Call once at app startup, before any BLE scanning, to install the
  /// requestDevice intercept that caches BluetoothDevice objects.
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await _loadScript(
      'assets/packages/mcumgr_flutter/lib/src/mcumgr_web/mcumgr_setup.js',
    );
  }

  static Future<void> loadJs() async {
    print('Attempting to load web scripts...');
    if (web.document.querySelector('script[src*="mcumgr_interop.js"]') != null &&
        web.document.querySelector('script[src*="mcumgr.js"]') != null &&
        web.document.querySelector('script[src*="cbor.js"]') != null) {
      print('All mcumgr scripts already loaded');
      return;
    }

    final v = DateTime.now().millisecondsSinceEpoch;
    await _loadScript(
      'assets/packages/mcumgr_flutter/lib/src/mcumgr_web/cbor.js?v=$v',
    );
    await _loadScript(
      'assets/packages/mcumgr_flutter/lib/src/mcumgr_web/mcumgr.js?v=$v',
    );
    await _loadScript(
      'assets/packages/mcumgr_flutter/lib/src/mcumgr_web/mcumgr_interop.js?v=$v',
      type: 'module',
    );
  }

  static Future<void> _loadScript(String src, {String? type}) {
    final completer = Completer<void>();
    final script =
        web.document.createElement('script') as web.HTMLScriptElement;
    script.src = src;
    if (type != null) script.type = type;
    script.onLoad.listen((_) {
      print('Loaded script: $src');
      completer.complete();
    });
    script.onError.listen((e) {
      print('Failed to load script: $src');
      completer.completeError('Failed to load $src');
    });
    web.document.head!.appendChild(script);
    return completer.future;
  }
}
