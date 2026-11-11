import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import 'package:conduit_core/features/librechat/models/librechat_server.dart';
import 'package:conduit_core/features/librechat/models/librechat_session.dart';

/// One LibreChat user on one server, saved on this device.
///
/// The session (token and cookies) is kept apart, per account, in secure
/// storage; this is what the Accounts page shows and switches between, and
/// it outlives a session that ended.
@immutable
final class LibreChatAccount {
  const LibreChatAccount({
    required this.id,
    required this.server,
    required this.userId,
    this.serverTitle,
    this.name,
    this.username,
    this.email,
    this.avatar,
    this.role,
    this.lastUsedAt,
  });

  /// Builds the account [user] signed in as on [server].
  factory LibreChatAccount.forUser(
    LibreChatServer server,
    LibreChatUser user, {
    String? serverTitle,
    DateTime? lastUsedAt,
  }) => LibreChatAccount(
    id: idFor(server.baseUrl, user.id),
    server: server,
    userId: user.id,
    serverTitle: serverTitle,
    name: user.name,
    username: user.username,
    email: user.email,
    avatar: user.avatar,
    role: user.role,
    lastUsedAt: lastUsedAt,
  );

  /// `librechat:` and a digest of the server and user, so the same user on
  /// the same server is one account however often they sign in, and the id
  /// says nothing about either.
  ///
  /// The prefix keeps LibreChat ids apart from Open WebUI account ids in the
  /// stores both use (summaries, account-scoped preferences).
  static String idFor(String baseUrl, String userId) {
    final digest = sha256.convert(utf8.encode('$baseUrl\u0000$userId'));
    return '$idPrefix${digest.toString().substring(0, 32)}';
  }

  static const String idPrefix = 'librechat:';

  /// Whether [id] names a LibreChat account.
  static bool isLibreChatAccountId(String? id) =>
      id != null && id.startsWith(idPrefix);

  final String id;
  final LibreChatServer server;
  final String userId;

  /// The server's name for itself (its `appTitle`), when it has one.
  final String? serverTitle;

  final String? name;
  final String? username;
  final String? email;
  final String? avatar;
  final String? role;
  final DateTime? lastUsedAt;

  /// What to call the account.
  String get displayName =>
      [name, username, email].firstWhere(
        (value) => value != null && value.trim().isNotEmpty,
        orElse: () => null,
      ) ??
      userId;

  /// The server's host, for a subtitle.
  String get host => Uri.parse(server.baseUrl).host;

  LibreChatAccount copyWith({
    LibreChatServer? server,
    String? serverTitle,
    String? name,
    String? username,
    String? email,
    String? avatar,
    String? role,
    DateTime? lastUsedAt,
  }) => LibreChatAccount(
    id: id,
    server: server ?? this.server,
    userId: userId,
    serverTitle: serverTitle ?? this.serverTitle,
    name: name ?? this.name,
    username: username ?? this.username,
    email: email ?? this.email,
    avatar: avatar ?? this.avatar,
    role: role ?? this.role,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );

  /// This account with the profile [user] now has. The server sends the
  /// whole profile, so a field it no longer has is cleared here too.
  LibreChatAccount withUser(LibreChatUser user) => LibreChatAccount(
    id: id,
    server: server,
    userId: userId,
    serverTitle: serverTitle,
    name: user.name,
    username: user.username,
    email: user.email,
    avatar: user.avatar,
    role: user.role,
    lastUsedAt: lastUsedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'server': server.toJson(),
    'userId': userId,
    'serverTitle': ?serverTitle,
    'name': ?name,
    'username': ?username,
    'email': ?email,
    'avatar': ?avatar,
    'role': ?role,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toUtc().toIso8601String(),
  };

  static LibreChatAccount? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final userId = json['userId'];
    final server = LibreChatServer.fromJson(json['server']);
    if (id is! String ||
        !isLibreChatAccountId(id) ||
        userId is! String ||
        userId.isEmpty ||
        server == null) {
      return null;
    }
    String? text(String key) => json[key] is String ? json[key] as String : null;
    final lastUsed = text('lastUsedAt');
    return LibreChatAccount(
      id: id,
      server: server,
      userId: userId,
      serverTitle: text('serverTitle'),
      name: text('name'),
      username: text('username'),
      email: text('email'),
      avatar: text('avatar'),
      role: text('role'),
      lastUsedAt: lastUsed == null ? null : DateTime.tryParse(lastUsed),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LibreChatAccount &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Every LibreChat account saved on this device, and which is in use.
@immutable
final class LibreChatRegistry {
  const LibreChatRegistry({
    this.accounts = const <LibreChatAccount>[],
    this.activeId,
  });

  static const int version = 1;

  final List<LibreChatAccount> accounts;

  /// The account LibreChat chats use when LibreChat is the primary backend.
  /// It stays set while another backend is primary, so switching back
  /// returns to it.
  final String? activeId;

  LibreChatAccount? get active =>
      accounts.where((account) => account.id == activeId).firstOrNull;

  LibreChatAccount? byId(String id) =>
      accounts.where((account) => account.id == id).firstOrNull;

  /// [account] added, or replacing the saved one with its id.
  LibreChatRegistry upsert(LibreChatAccount account, {bool activate = false}) {
    final index = accounts.indexWhere((saved) => saved.id == account.id);
    final next = [...accounts];
    if (index < 0) {
      next.add(account);
    } else {
      next[index] = account;
    }
    return LibreChatRegistry(
      accounts: List.unmodifiable(next),
      activeId: activate ? account.id : activeId,
    );
  }

  /// Without account [id]. Its being active passes to no account.
  LibreChatRegistry remove(String id) => LibreChatRegistry(
    accounts: List.unmodifiable(accounts.where((account) => account.id != id)),
    activeId: activeId == id ? null : activeId,
  );

  LibreChatRegistry withActive(String? id) => LibreChatRegistry(
    accounts: accounts,
    activeId: id != null && byId(id) == null ? activeId : id,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'accounts': [for (final account in accounts) account.toJson()],
    'activeId': ?activeId,
  };

  /// The registry in [json]; empty when it is missing or from a version
  /// this build cannot read.
  static LibreChatRegistry fromJson(Object? json) {
    if (json is! Map || json['version'] != version) {
      return const LibreChatRegistry();
    }
    final list = json['accounts'];
    final accounts = <LibreChatAccount>[
      if (list is List)
        for (final item in list) ?LibreChatAccount.fromJson(item),
    ];
    final activeId = json['activeId'];
    return LibreChatRegistry(
      accounts: List.unmodifiable(accounts),
      activeId:
          activeId is String && accounts.any((account) => account.id == activeId)
          ? activeId
          : null,
    );
  }
}
