import 'package:flutter/material.dart';
import 'package:mcumgr_flutter_example/src/model/firmware_update_request.dart';
import 'package:mcumgr_flutter_example/src/providers/firmware_update_request_provider.dart';
import 'package:provider/provider.dart';

class FirmwareSelect extends StatelessWidget {
  const FirmwareSelect({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    FirmwareUpdateRequest updateParameters =
        context.watch<FirmwareUpdateRequestProvider>().updateParameters;

    return SizedBox(
      width: double.infinity,
      child: _firmwareInfo(context, updateParameters.firmware),
    );
  }

  Widget _firmwareInfo(BuildContext context, SelectedFirmware? firmware) {
    if (firmware == null) {
      return Container();
    } else if (firmware is LocalFirmware) {
      return _localFirmwareInfo(context, firmware);
    } else if (firmware is RemoteFirmware) {
      return _remoteFirmwareInfo(context, firmware);
    } else {
      return const Text('Unknown firmware type');
    }
  }

  Widget _localFirmwareInfo(BuildContext context, LocalFirmware firmware) {
    return Text('Firmware: ${firmware.name}');
  }

  Widget _remoteFirmwareInfo(BuildContext context, RemoteFirmware firmware) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Version: ${firmware.version.version}'),
        Text('Board: ${firmware.board.name}'),
        Text('Firmware: ${firmware.firmware.name}'),
        const SizedBox(height: 16),
      ],
    );
  }
}
