import 'dart:typed_data';

import 'native_generated/api/contract.dart';

abstract interface class ChatGptRuntimeClient {
  Stream<RuntimeEvent> get events;

  Future<void> initialize();
  Future<AuthStateInfo> authState();
  Future<DeviceCodeChallenge> beginDeviceCodeLogin();
  Future<void> cancelDeviceCodeLogin();
  Future<List<ModelInfo>> listModels();
  Future<RunInfo> startTurn(TurnRequest request);
  Future<void> interruptTurn(String runId);
  Future<void> disconnectAccount();
  Future<void> shutdown();
}

abstract interface class ChatGptAuthSnapshotStore {
  Future<Uint8List?> read();
  Future<void> write(Uint8List snapshot);
  Future<void> delete();
}
