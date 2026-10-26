import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart';
import 'package:mcumgr_flutter/proto/flutter_mcu.pb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Future<void> emit(String uuid, ProtoUpdateStateChanges_FirmwareUpgradeState s) =>
      messenger.handlePlatformMessage('mcumgr_flutter/update_state_event_channel',
          const StandardMethodCodec().encodeSuccessEnvelope(ProtoUpdateStateChangesStreamArg(
              uuid: uuid, updateStateChanges: ProtoUpdateStateChanges(newState: s)).writeToBuffer()), (_) {});

  test('two managers each get their own events, and a kill keeps the other', () async {
    for (final name in ['method_channel', 'update_state_event_channel', 'update_progress_event_channel', 'log_event_channel']) messenger.setMockMethodCallHandler(MethodChannel('mcumgr_flutter/$name'), (_) async => null);
    final factory = FirmwareUpdateManagerFactory();
    final left = await factory.getUpdateManager('L');
    final right = await factory.getUpdateManager('R');
    final leftStates = <FirmwareUpgradeState>[], rightStates = <FirmwareUpgradeState>[];
    left.setup().listen(leftStates.add);
    right.setup().listen(rightStates.add);
    await emit('L', ProtoUpdateStateChanges_FirmwareUpgradeState.UPLOAD);
    await emit('R', ProtoUpdateStateChanges_FirmwareUpgradeState.UPLOAD);
    await right.kill();
    await emit('L', ProtoUpdateStateChanges_FirmwareUpgradeState.SUCCESS);
    await Future<void>.delayed(Duration.zero);
    expect(leftStates, [FirmwareUpgradeState.upload, FirmwareUpgradeState.success]);
    expect(rightStates, [FirmwareUpgradeState.upload]);
    await left.kill();
  });
}
