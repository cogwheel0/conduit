import 'package:conduit_core/network/server_origin.dart';

/// Where a workspace model's profile image comes from, by the address it
/// keeps in `meta.profile_image_url`, as the phone's model editor draws it.
enum WorkspaceModelAvatarSource {
  /// A `data:image` URL: the picture is in the address.
  inline,

  /// The model's server: its profile-image endpoint (the image the model
  /// keeps), or a picture at an address on the server itself. An address
  /// that is neither (none at all, `/static/favicon.png`) leaves the
  /// endpoint to answer, and it answers with no picture of the model's own.
  server,

  /// An http(s) address on another site.
  remote,
}

/// [imageUrl]'s source for a model on the server at [serverBaseUrl].
WorkspaceModelAvatarSource workspaceModelAvatarSource(
  String? imageUrl, {
  String? serverBaseUrl,
}) {
  final url = imageUrl?.trim() ?? '';
  if (url.startsWith('data:image')) return WorkspaceModelAvatarSource.inline;
  if (url.toLowerCase().startsWith('http')) {
    return imageUrlIsServerOrigin(serverBaseUrl, url)
        ? WorkspaceModelAvatarSource.server
        : WorkspaceModelAvatarSource.remote;
  }
  return WorkspaceModelAvatarSource.server;
}
