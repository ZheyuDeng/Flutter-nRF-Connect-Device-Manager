import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart';
import 'package:mcumgr_flutter/proto/flutter_mcu.pb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('mcumgr_flutter/method_channel');
  const stateChannel = 'mcumgr_flutter/update_state_event_channel';
  const progressChannel = 'mcumgr_flutter/update_progress_event_channel';
  const logChannel = 'mcumgr_flutter/log_event_channel';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMethodCodec();

  Future<void> emit(String channel, List<int> payload) =>
      messenger.handlePlatformMessage(
        channel,
        codec.encodeSuccessEnvelope(Uint8List.fromList(payload)),
        (_) {},
      );

  Future<void> emitState(String uuid, ProtoUpdateStateChanges_FirmwareUpgradeState s) =>
      emit(
        stateChannel,
        ProtoUpdateStateChangesStreamArg(
          uuid: uuid,
          updateStateChanges: ProtoUpdateStateChanges(newState: s),
        ).writeToBuffer(),
      );

  setUp(() {
    messenger.setMockMethodCallHandler(method, (_) async => null);
    for (final name in [stateChannel, progressChannel, logChannel]) {
      messenger.setMockMethodCallHandler(
          MethodChannel(name), (_) async => null);
    }
  });

  test('two managers each receive their own device events', () async {
    final factory = FirmwareUpdateManagerFactory();
    final left = await factory.getUpdateManager('L');
    final right = await factory.getUpdateManager('R');
    final leftStates = <FirmwareUpgradeState>[];
    final rightStates = <FirmwareUpgradeState>[];
    final leftProgress = <int>[];
    final rightProgress = <int>[];
    final leftLogs = <String>[];
    final rightLogs = <String>[];
    left.setup().listen(leftStates.add);
    right.setup().listen(rightStates.add);
    left.progressStream.listen((p) => leftProgress.add(p.bytesSent));
    right.progressStream.listen((p) => rightProgress.add(p.bytesSent));
    left.logger.logMessageStream.listen((m) => leftLogs.add(m.message));
    right.logger.logMessageStream.listen((m) => rightLogs.add(m.message));
    await Future<void>.delayed(Duration.zero);

    await emitState('L', ProtoUpdateStateChanges_FirmwareUpgradeState.UPLOAD);
    await emitState('R', ProtoUpdateStateChanges_FirmwareUpgradeState.UPLOAD);
    for (final uuid in ['L', 'R']) {
      await emit(
        progressChannel,
        ProtoProgressUpdateStreamArg(
          uuid: uuid,
          progressUpdate: ProtoProgressUpdate(
              bytesSent: uuid == 'L' ? Int64(10) : Int64(20),
              imageSize: Int64(100)),
        ).writeToBuffer(),
      );
      await emit(
        logChannel,
        ProtoLogMessageStreamArg(
          uuid: uuid,
          protoLogMessage: ProtoLogMessage(message: 'log $uuid'),
        ).writeToBuffer(),
      );
    }
    await Future<void>.delayed(Duration.zero);

    expect(leftStates, [FirmwareUpgradeState.upload]);
    expect(rightStates, [FirmwareUpgradeState.upload]);
    expect(leftProgress, [10]);
    expect(rightProgress, [20]);
    expect(leftLogs, ['log L']);
    expect(rightLogs, ['log R']);

    // Killing one manager must not silence the other.
    await right.kill();
    await emitState('L', ProtoUpdateStateChanges_FirmwareUpgradeState.SUCCESS);
    await Future<void>.delayed(Duration.zero);
    expect(leftStates.last, FirmwareUpgradeState.success);

    // A retry manager for the same device replaces, not duplicates, events.
    final retry = await factory.getUpdateManager('R');
    final retryStates = <FirmwareUpgradeState>[];
    retry.setup().listen(retryStates.add);
    await Future<void>.delayed(Duration.zero);
    await emitState('R', ProtoUpdateStateChanges_FirmwareUpgradeState.UPLOAD);
    await Future<void>.delayed(Duration.zero);
    expect(retryStates, [FirmwareUpgradeState.upload]);
    expect(rightStates, [FirmwareUpgradeState.upload]);

    // The killed manager's late cancel must not end the retry's stream.
    await emit(
      stateChannel,
      ProtoUpdateStateChangesStreamArg(
        uuid: 'R',
        updateStateChanges: ProtoUpdateStateChanges(canceled: true),
      ).writeToBuffer(),
    );
    await emitState('R', ProtoUpdateStateChanges_FirmwareUpgradeState.RESET);
    await Future<void>.delayed(Duration.zero);
    expect(retryStates.last, FirmwareUpgradeState.reset);
    await left.kill();
    await retry.kill();
  });
}
