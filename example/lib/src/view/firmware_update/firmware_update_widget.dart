import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mcumgr_flutter_example/src/bloc/bloc/update_bloc.dart';
import 'package:mcumgr_flutter_example/src/model/firmware_update_request.dart';
import 'package:mcumgr_flutter_example/src/providers/firmware_update_request_provider.dart';
import 'package:mcumgr_flutter_example/src/view/firmware_select/firmware_list.dart';
import 'package:mcumgr_flutter_example/src/view/peripheral_select/peripheral_list.dart';
import 'package:mcumgr_flutter_example/src/view/stepper_view/firmware_select.dart';
import 'package:mcumgr_flutter_example/src/view/stepper_view/update_view.dart';

class FirmwareUpdateWidget extends StatefulWidget {
  const FirmwareUpdateWidget({super.key});

  @override
  State<FirmwareUpdateWidget> createState() => _FirmwareUpdateWidgetState();
}

class _FirmwareUpdateWidgetState extends State<FirmwareUpdateWidget> {
  @override
  Widget build(BuildContext context) {
    final provider = context.watch<FirmwareUpdateRequestProvider>();
    final parameters = provider.updateParameters;
    final hasUpdateParameters =
        parameters.firmware != null && parameters.peripheral != null;

    final stepper = Stepper(
      currentStep: provider.currentStep,
      onStepContinue: () {
        setState(() {
          provider.nextStep();
        });
      },
      onStepCancel: () {
        setState(() {
          provider.previousStep();
        });
      },
      controlsBuilder: _controlBuilder,
      steps: [
        Step(
          title: const Text('Firmware'),
          subtitle: parameters.firmware != null
              ? Text(
                  parameters.firmware!.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                )
              : null,
          content: const FirmwareSelect(),
          isActive: provider.currentStep == 0,
          state: provider.currentStep > 0
              ? StepState.complete
              : StepState.indexed,
        ),
        Step(
          title: const Text('Device'),
          subtitle: parameters.peripheral != null
              ? Text(
                  parameters.peripheral!.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                )
              : null,
          content: const SizedBox(height: 16),
          isActive: provider.currentStep == 1,
          state: provider.currentStep > 1
              ? StepState.complete
              : StepState.indexed,
        ),
        Step(
          title: const Text('Update'),
          content: parameters.firmware != null && parameters.peripheral != null
              ? const UpdateStepView()
              : const Text('Please select firmware and device first.'),
          isActive: provider.currentStep == 2,
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Firmware Update'),
      ),
      body: hasUpdateParameters
            ? BlocProvider(
                key: ValueKey(
                  '${parameters.firmware.hashCode}-${parameters.peripheral.hashCode}',
                ),
                create: (context) =>
                    UpdateBloc(firmwareUpdateRequest: parameters),
                child: stepper,
              )
            : stepper,
    );
  }

  Widget _controlBuilder(BuildContext context, ControlsDetails details) {
    final provider = context.watch<FirmwareUpdateRequestProvider>();
    FirmwareUpdateRequest parameters = provider.updateParameters;
    switch (provider.currentStep) {
      case 0:
        return Row(
          children: [
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => FirmwareList()),
                );
              },
              child: Text(parameters.firmware == null ? 'Select' : 'Change'),
            ),
            if (parameters.firmware != null) ...[
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: details.onStepContinue,
                child: const Text('Next'),
              ),
            ],
          ],
        );
      case 1:
        return Row(
          children: [
            ElevatedButton(
              onPressed: details.onStepCancel,
              child: const Text('Back'),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => const PeripheralList()),
                );
              },
              child: Text(parameters.peripheral == null ? 'Select' : 'Change'),
            ),
            if (parameters.peripheral != null) ...[
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: details.onStepContinue,
                child: const Text('Next'),
              ),
            ],
          ],
        );
      case 2:
        return BlocBuilder<UpdateBloc, UpdateState>(
          builder: (context, state) {
            final bool isComplete =
                state is UpdateFirmwareStateHistory && state.isComplete;
            final bool isInProgress =
                state is UpdateFirmwareStateHistory && !isComplete;

            return Row(
              children: [
                if (!isComplete && !isInProgress)
                  ElevatedButton(
                    onPressed: details.onStepCancel,
                    child: const Text('Back'),
                  ),
                if (state is UpdateInitial) ...[
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () {
                      context.read<UpdateBloc>().add(BeginUpdateProcess());
                    },
                    child: const Text('Start'),
                  ),
                ],
                if (isComplete)
                  ElevatedButton(
                    onPressed: () {
                      BlocProvider.of<UpdateBloc>(context).add(ResetUpdate());
                      provider.reset();
                    },
                    child: const Text('Retry'),
                  ),
              ],
            );
          },
        );
      default:
        throw Exception('Unknown step');
    }
  }
}
