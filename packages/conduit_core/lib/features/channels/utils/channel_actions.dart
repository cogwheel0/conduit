import 'package:conduit_core/models/channel.dart';
import 'package:conduit_core/services/api_service.dart';

/// Makes a channel as New Channel does in Conduit: a group channel, which
/// has members (its maker first), with [name], [description] and whether
/// it is [isPrivate]. Returns the channel the server stored; the caller
/// lists it.
Future<Channel> createGroupChannel(
  ApiService api, {
  required String name,
  String? description,
  bool isPrivate = false,
}) async {
  final json = await api.createChannel(
    name: name,
    type: 'group',
    description: description,
    isPrivate: isPrivate,
  );
  return Channel.fromJson(json);
}
