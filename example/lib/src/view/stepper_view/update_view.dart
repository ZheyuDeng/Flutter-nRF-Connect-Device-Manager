import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:mcumgr_flutter_example/src/providers/firmware_update_request_provider.dart';
import 'package:mcumgr_flutter_example/src/view/logger_screen/logger_screen.dart';

import '../../bloc/bloc/update_bloc.dart';

class UpdateStepView extends StatelessWidget {
  const UpdateStepView({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: BlocBuilder<UpdateBloc, UpdateState>(
        builder: (context, state) {
          switch (state) {
            case UpdateInitial():
              return Container();
            case UpdateFirmwareStateHistory():
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var state in state.history)
                    Row(
                      children: [
                        _stateIcon(state),
                        const SizedBox(width: 8),
                        Text(state.stage),
                      ],
                    ),
                  if (state.currentState != null)
                    Row(
                      children: [
                        const SizedBox(width: 3),
                        const CircularProgressIndicator(
                          constraints:
                              BoxConstraints(minWidth: 17.0, minHeight: 17.0),
                          strokeWidth: 2.0,
                        ),
                        const SizedBox(width: 12),
                        _currentState(state),
                      ],
                    ),
                  if (state.isComplete && state.updateManager?.logger != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16.0),
                      child: ElevatedButton(
                          onPressed: () {
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (context) => LoggerScreen(
                                          logger: state.updateManager!.logger,
                                        )));
                          },
                          child: const Text('Show Log')),
                    ),
                ],
              );
            default:
              return const Text('Unknown state');
          }
        },
      ),
    );
  }

  Icon _stateIcon(UpdateFirmware state) {
    if (state is UpdateCompleteFailure) {
      return const Icon(Icons.error_outline, color: Colors.red);
    } else {
      return const Icon(Icons.check_circle_outline, color: Colors.green);
    }
  }

  Text _currentState(UpdateFirmwareStateHistory state) {
    final currentState = state.currentState;
    if (currentState == null) {
      return const Text('Unknown state');
    } else if (currentState is UpdateProgressFirmware) {
      return Text("Uploading ${currentState.progress}%");
    } else {
      return Text(currentState.stage);
    }
  }
}
