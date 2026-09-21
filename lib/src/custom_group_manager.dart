part of mcumgr_flutter;

class ConnectionState {
  final String remoteId;
  final bool connected;

  const ConnectionState(this.remoteId, {required this.connected});
}

abstract class CustomGroupManager {
  late final String remoteId;

  static final Map<String, CustomGroupManager> _cache = {};

  factory CustomGroupManager(String remoteId) {
    return _cache.putIfAbsent(remoteId, () => _CustomGroupManagerImpl._internal(remoteId));
  }

  Stream<ConnectionState> get connectionStates;

  /// Configures the SMP transport decorator for this device.
  ///
  /// All parameters are optional; omit a parameter to leave the corresponding
  /// SMP header field or suffix unchanged.
  ///
  /// [suffix]        Bytes appended to every outgoing SMP packet.
  /// [opOverride]    Overrides byte 0 (op) of the SMP header.
  /// [flagsOverride] Overrides byte 1 (flags) of the SMP header.
  Future<void> setupDecorator({Uint8List? suffix, int? opOverride, int? flagsOverride});

  /// Sends a generic SMP command and returns the raw response payload.
  ///
  /// The 8-byte SMP header is stripped from the response before returning.
  ///
  /// [groupId]   SMP group ID (e.g. `0x41` for a vendor-specific group).
  /// [commandId] Command index within the group.
  /// [op]        SMP operation code (`0` = read, `2` = write).
  /// [payload]   String-keyed map CBOR-encoded as the request body.
  Future<Uint8List> sendCustomCommand({
    required int groupId,
    required int commandId,
    required int op,
    Map<String?, Object?> payload = const {},
  });

  Future<void> kill();
}

class _CustomGroupManagerImpl implements CustomGroupManager {
  @override
  String remoteId;

  final CustomGroupManagerApi _api = CustomGroupManagerApi();

  _CustomGroupManagerImpl._internal(this.remoteId);

  @override
  Stream<ConnectionState> get connectionStates => getConnectionStateEvents()
      .where((e) => e.remoteId == remoteId)
      .map((e) => ConnectionState(e.remoteId, connected: e.connected));

  @override
  Future<void> setupDecorator({Uint8List? suffix, int? opOverride, int? flagsOverride}) {
    return _api.setupDecorator(remoteId, suffix, opOverride, flagsOverride);
  }

  @override
  Future<Uint8List> sendCustomCommand({
    required int groupId,
    required int commandId,
    required int op,
    Map<String?, Object?> payload = const {},
  }) {
    return _api.sendCustomCommand(remoteId, groupId, commandId, op, payload);
  }

  @override
  Future<void> kill() {
    CustomGroupManager._cache.remove(remoteId);
    return _api.kill(remoteId);
  }
}
