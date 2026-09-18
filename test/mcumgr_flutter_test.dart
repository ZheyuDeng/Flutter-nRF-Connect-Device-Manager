import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mcumgr_flutter/method_channel');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'factory awaits native readiness and propagates initialization failure',
    () async {
      final nativeResult = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        await nativeResult.future;
        return null;
      });
      var completed = false;
      final manager = FirmwareUpdateManagerFactory().getUpdateManager('pod');
      final assertion = expectLater(
        manager.whenComplete(() => completed = true),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.message,
            'message',
            'Bluetooth is powered off',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      nativeResult.completeError(
        PlatformException(
          code: 'WrongArguments',
          message: 'Bluetooth is powered off',
        ),
      );
      await assertion;
      expect(calls, ['initializeUpdateManager']);
    },
  );
}
