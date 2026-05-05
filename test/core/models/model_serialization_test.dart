import 'package:checks/checks.dart';
import 'package:conduit/core/models/backend_config.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/folder.dart';
import 'package:conduit/core/models/knowledge_base.dart';
import 'package:conduit/core/models/knowledge_base_file.dart';
import 'package:conduit/core/models/model.dart';
import 'package:conduit/core/models/prompt.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/models/socket_health.dart';
import 'package:conduit/core/models/socket_transport_availability.dart';
import 'package:conduit/core/models/toggle_filter.dart';
import 'package:conduit/core/models/tool.dart';
import 'package:conduit/core/models/user.dart';
import 'package:conduit/core/models/user_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('User', () {
    test('fromJson with snake_case fields', () {
      final user = User.fromJson({
        'id': 'u1',
        'username': 'alice',
        'email': 'alice@example.com',
        'name': 'Alice',
        'profile_image_url': 'https://img.example.com/a.png',
        'role': 'admin',
        'is_active': true,
      });

      check(user.id).equals('u1');
      check(user.username).equals('alice');
      check(user.email).equals('alice@example.com');
      check(user.name).equals('Alice');
      check(user.profileImage).equals('https://img.example.com/a.png');
      check(user.role).equals('admin');
      check(user.isActive).isTrue();
    });

    test('fromJson with camelCase fields', () {
      final user = User.fromJson({
        'id': 'u2',
        'username': 'bob',
        'email': 'bob@example.com',
        'profileImage': 'https://img.example.com/b.png',
        'isActive': false,
      });

      check(user.profileImage).equals('https://img.example.com/b.png');
      check(user.isActive).isFalse();
    });

    test('fromJson defaults', () {
      final user = User.fromJson({'id': 'u3'});

      check(user.username).equals('');
      check(user.email).equals('');
      check(user.role).equals('user');
      check(user.isActive).isTrue();
    });

    test('toJson produces correct output', () {
      final user = User(
        id: 'u1',
        username: 'alice',
        email: 'alice@example.com',
        name: 'Alice',
        profileImage: 'https://img.example.com/a.png',
        role: 'admin',
        isActive: true,
      );
      final json = user.toJson();

      check(json['id']).equals('u1');
      check(json['username']).equals('alice');
      check(json['profile_image_url']).equals('https://img.example.com/a.png');
      check(json['is_active']).equals(true);
    });

    test('username falls back to name when missing', () {
      final user = User.fromJson({
        'id': 'u4',
        'name': 'FallbackName',
        'email': 'x@y.com',
      });
      check(user.username).equals('FallbackName');
    });
  });

  group('Model', () {
    test('fromJson minimal', () {
      final model = Model.fromJson({'id': 'gpt-4', 'name': 'GPT-4'});

      check(model.id).equals('gpt-4');
      check(model.name).equals('GPT-4');
      check(model.isMultimodal).isFalse();
    });

    test('fromJson with capabilities vision', () {
      final model = Model.fromJson({
        'id': 'gpt-4v',
        'name': 'GPT-4 Vision',
        'info': {
          'meta': {
            'capabilities': {'vision': true},
          },
        },
        'architecture': {'modality': 'text+image'},
      });

      check(model.isMultimodal).isTrue();
    });

    test('name defaults to id when blank', () {
      final model = Model.fromJson({'id': 'my-model', 'name': ''});
      check(model.name).equals('my-model');
    });

    test('missing id throws ArgumentError', () {
      check(() => Model.fromJson({'name': 'test'})).throws<ArgumentError>();
    });

    test('toJson round-trip preserves id and name', () {
      final model = Model.fromJson({'id': 'rt', 'name': 'RoundTrip'});
      final json = model.toJson();

      check(json['id']).equals('rt');
      check(json['name']).equals('RoundTrip');
    });

    test('extracts toolIds from info.meta.toolIds', () {
      final model = Model.fromJson({
        'id': 'tooled',
        'name': 'Tooled',
        'info': {
          'meta': {
            'toolIds': ['t1', 't2'],
          },
        },
      });
      check(model.toolIds).isNotNull().deepEquals(['t1', 't2']);
    });

    test('detects OpenWebUI hidden models from info.meta.hidden', () {
      final model = Model.fromJson({
        'id': 'hidden-model',
        'name': 'Hidden Model',
        'info': {
          'meta': {'hidden': true},
        },
      });

      check(model.isHidden).isTrue();
    });

    test('detects hidden models after cached round-trip', () {
      final model = Model.fromJson({
        'id': 'hidden-model',
        'name': 'Hidden Model',
        'info': {
          'meta': {'hidden': 'true'},
        },
      });
      final restored = Model.fromJson(model.toJson());

      check(restored.isHidden).isTrue();
    });
  });

  group('Prompt', () {
    test('command normalization adds leading slash', () {
      final prompt = Prompt.fromJson({
        'command': 'summarize',
        'title': 'Summarize',
        'content': 'Summarize this',
      });
      check(prompt.command).equals('/summarize');
    });

    test('command normalization preserves existing slash', () {
      final prompt = Prompt.fromJson({
        'command': '/translate',
        'title': 'Translate',
        'content': 'Translate this',
      });
      check(prompt.command).equals('/translate');
    });

    test('empty command stays empty', () {
      final prompt = Prompt.fromJson({
        'command': '',
        'title': 'T',
        'content': 'C',
      });
      check(prompt.command).equals('');
    });

    test('toJson round-trip', () {
      final prompt = Prompt.fromJson({
        'command': 'test',
        'title': 'Test',
        'content': 'Test content',
        'user_id': 'uid1',
        'timestamp': 1000,
      });
      final json = prompt.toJson();

      check(json['command']).equals('/test');
      check(json['title']).equals('Test');
      check(json['content']).equals('Test content');
      check(json['user_id']).equals('uid1');
      check(json['timestamp']).equals(1000);
    });
  });

  group('ToggleFilter', () {
    test('fromJson with has_user_valves', () {
      final filter = ToggleFilter.fromJson({
        'id': 'f1',
        'name': 'Grammar',
        'has_user_valves': true,
      });

      check(filter.id).equals('f1');
      check(filter.name).equals('Grammar');
      check(filter.hasUserValves).isTrue();
    });

    test('toJson round-trip', () {
      final filter = ToggleFilter.fromJson({
        'id': 'f2',
        'name': 'Tone',
        'description': 'Adjusts tone',
        'has_user_valves': false,
      });
      final json = filter.toJson();

      check(json['id']).equals('f2');
      check(json['name']).equals('Tone');
      check(json['description']).equals('Adjusts tone');
      check(json['has_user_valves']).equals(false);
    });

    test('defaults hasUserValves to false', () {
      final filter = ToggleFilter.fromJson({'id': 'f3', 'name': 'Simple'});
      check(filter.hasUserValves).isFalse();
    });
  });

  group('Tool', () {
    test('fromJson with user_id', () {
      final tool = Tool.fromJson({
        'id': 'tool1',
        'name': 'Calculator',
        'description': 'Does math',
        'user_id': 'owner1',
        'meta': {'version': 2},
      });

      check(tool.id).equals('tool1');
      check(tool.name).equals('Calculator');
      check(tool.description).equals('Does math');
      check(tool.userId).equals('owner1');
      check(tool.meta).isNotNull().deepEquals({'version': 2});
    });

    test('toJson round-trip', () {
      final tool = Tool.fromJson({
        'id': 'tool2',
        'name': 'Search',
        'user_id': 'u1',
      });
      final json = tool.toJson();

      check(json['id']).equals('tool2');
      check(json['name']).equals('Search');
      check(json['user_id']).equals('u1');
    });
  });

  group('Folder', () {
    test('fromJson with conversation_ids list', () {
      final folder = Folder.fromJson({
        'id': 'folder1',
        'name': 'Work',
        'conversation_ids': ['c1', 'c2', 'c3'],
      });

      check(folder.id).equals('folder1');
      check(folder.name).equals('Work');
      check(folder.conversationIds).deepEquals(['c1', 'c2', 'c3']);
    });

    test('fromJson extracting IDs from items.chats', () {
      final folder = Folder.fromJson({
        'id': 'folder2',
        'name': 'Personal',
        'items': {
          'chats': [
            {'id': 'chat1'},
            {'id': 'chat2'},
          ],
        },
      });

      check(folder.conversationIds).deepEquals(['chat1', 'chat2']);
    });

    test('conversation_ids takes precedence over items.chats', () {
      final folder = Folder.fromJson({
        'id': 'f3',
        'name': 'Mixed',
        'conversation_ids': ['explicit1'],
        'items': {
          'chats': [
            {'id': 'implicit1'},
          ],
        },
      });

      check(folder.conversationIds).deepEquals(['explicit1']);
    });

    test('toJson round-trip', () {
      final folder = Folder.fromJson({
        'id': 'f4',
        'name': 'Archived',
        'conversation_ids': ['a1'],
      });
      final json = folder.toJson();

      check(json['id']).equals('f4');
      check(json['name']).equals('Archived');
      check(json['conversation_ids'] as List).deepEquals(['a1']);
    });
  });

  group('KnowledgeBase', () {
    test('fromJson with snake_case (created_at as int)', () {
      final kb = KnowledgeBase.fromJson({
        'id': 'kb1',
        'name': 'Docs',
        'created_at': 1700000000,
        'updated_at': 1700001000,
        'file_count': 5,
      });

      check(kb.id).equals('kb1');
      check(kb.name).equals('Docs');
      check(kb.itemCount).equals(5);
      check(
        kb.createdAt,
      ).equals(DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    });

    test('fromJson with camelCase (createdAt as string)', () {
      final kb = KnowledgeBase.fromJson({
        'id': 'kb2',
        'name': 'Notes',
        'createdAt': '2024-01-15T10:00:00.000Z',
        'updatedAt': '2024-01-16T10:00:00.000Z',
        'itemCount': 3,
      });

      check(kb.id).equals('kb2');
      check(kb.name).equals('Notes');
      check(kb.itemCount).equals(3);
      check(kb.createdAt).equals(DateTime.utc(2024, 1, 15, 10, 0, 0));
    });

    test('defaults itemCount to 0', () {
      final kb = KnowledgeBase.fromJson({
        'id': 'kb3',
        'name': 'Empty',
        'created_at': 1700000000,
        'updated_at': 1700000000,
      });
      check(kb.itemCount).equals(0);
    });
  });

  group('KnowledgeBaseFile', () {
    test('extracts filename from top-level field', () {
      final file = KnowledgeBaseFile.fromJson({
        'id': 'f1',
        'filename': 'report.pdf',
        'created_at': 1700000000,
      });
      check(file.filename).equals('report.pdf');
    });

    test('extracts filename from meta.name', () {
      final file = KnowledgeBaseFile.fromJson({
        'id': 'f2',
        'meta': {'name': 'notes.txt'},
        'created_at': '2024-01-15T10:00:00.000Z',
      });
      check(file.filename).equals('notes.txt');
    });

    test('falls back to Unknown when no filename', () {
      final file = KnowledgeBaseFile.fromJson({
        'id': 'f3',
        'created_at': 1700000000,
      });
      check(file.filename).equals('Unknown');
    });

    test('parses contentHash from hash field', () {
      final file = KnowledgeBaseFile.fromJson({
        'id': 'f4',
        'filename': 'data.csv',
        'created_at': 1700000000,
        'hash': 'abc123',
      });
      check(file.contentHash).equals('abc123');
    });
  });

  group('ServerConfig', () {
    test('fromJson/toJson round-trip', () {
      final json = {
        'id': 'srv1',
        'name': 'Production',
        'url': 'https://api.example.com',
        'apiKey': 'key123',
        'customHeaders': {'X-Custom': 'value'},
        'lastConnected': '2024-06-15T12:00:00.000Z',
        'isActive': true,
        'allowSelfSignedCertificates': false,
        'mtlsCertificateChainPem':
            '-----BEGIN CERTIFICATE-----\ncert\n-----END CERTIFICATE-----',
        'mtlsCertificateLabel': 'client-cert.pem',
        'mtlsPrivateKeyPem':
            '-----BEGIN PRIVATE KEY-----\nkey\n-----END PRIVATE KEY-----',
        'mtlsPrivateKeyLabel': 'client-key.pem',
        'mtlsPrivateKeyPassword': 'secret',
      };

      final config = ServerConfig.fromJson(json);
      check(config.id).equals('srv1');
      check(config.name).equals('Production');
      check(config.url).equals('https://api.example.com');
      check(config.apiKey).equals('key123');
      check(config.isActive).isTrue();
      check(config.allowSelfSignedCertificates).isFalse();
      check(config.mtlsCertificateLabel).equals('client-cert.pem');
      check(config.mtlsPrivateKeyLabel).equals('client-key.pem');
      check(config.mtlsPrivateKeyPassword).equals('secret');
      check(config.hasMutualTlsCredentials).isTrue();

      final output = config.toJson();
      check(output['id']).equals('srv1');
      check(output['name']).equals('Production');
      check(output['url']).equals('https://api.example.com');
      check(output['isActive']).equals(true);
      check(output['mtlsCertificateLabel']).equals('client-cert.pem');
      check(output['mtlsPrivateKeyLabel']).equals('client-key.pem');
    });

    test('defaults', () {
      final config = ServerConfig.fromJson({
        'id': 's2',
        'name': 'Dev',
        'url': 'http://localhost',
      });
      check(config.isActive).isFalse();
      check(config.allowSelfSignedCertificates).isFalse();
      check(config.customHeaders).deepEquals({});
      check(config.hasMutualTlsCredentials).isFalse();
    });
  });

  group('UserSettings', () {
    test('fromJson with defaults (empty map)', () {
      final settings = UserSettings.fromJson({});

      check(settings.showReadReceipts).isTrue();
      check(settings.enableNotifications).isTrue();
      check(settings.enableSounds).isFalse();
      check(settings.theme).equals('auto');
      check(settings.temperature).equals(0.7);
      check(settings.maxTokens).equals(2048);
      check(settings.streamResponses).isFalse();
      check(settings.density).equals('comfortable');
      check(settings.fontSize).equals(14.0);
      check(settings.language).equals('en');
      check(settings.reduceMotion).isFalse();
      check(settings.hapticFeedback).isTrue();
    });

    test('fromJson/toJson round-trip', () {
      final json = {
        'showReadReceipts': false,
        'enableNotifications': false,
        'enableSounds': true,
        'theme': 'dark',
        'temperature': 0.9,
        'maxTokens': 4096,
        'streamResponses': true,
        'webSearchEnabled': true,
        'saveConversations': false,
        'shareUsageData': true,
        'density': 'compact',
        'fontSize': 16.0,
        'language': 'fr',
        'reduceMotion': true,
        'hapticFeedback': false,
        'defaultModelId': 'gpt-4',
        'customSettings': {'key': 'val'},
      };

      final settings = UserSettings.fromJson(json);
      check(settings.theme).equals('dark');
      check(settings.temperature).equals(0.9);
      check(settings.maxTokens).equals(4096);
      check(settings.defaultModelId).equals('gpt-4');

      final output = settings.toJson();
      check(output['theme']).equals('dark');
      check(output['temperature']).equals(0.9);
      check(output['maxTokens']).equals(4096);
      check(output['defaultModelId']).equals('gpt-4');
      check(output['customSettings'] as Map).deepEquals({'key': 'val'});
    });
  });

  group('BackendConfig', () {
    test('fromJson canonical format', () {
      final config = BackendConfig.fromJson({
        'enable_websocket': true,
        'enable_audio_input': true,
        'enable_audio_output': false,
        'stt_provider': 'whisper',
        'tts_provider': 'elevenlabs',
        'tts_voice': 'Rachel',
        'tts_split_on': 'paragraphs',
        'tts_voices': [
          {'id': 'alloy', 'name': 'Alloy', 'locale': 'en-US'},
        ],
        'default_stt_locale': 'en-US',
        'audio_sample_rate': 16000,
        'audio_frame_size': 320,
        'vad_enabled': true,
        'enable_ldap': false,
        'enable_login_form': true,
      });

      check(config.enableWebsocket).equals(true);
      check(config.enableAudioInput).equals(true);
      check(config.enableAudioOutput).equals(false);
      check(config.sttProvider).equals('whisper');
      check(config.ttsProvider).equals('elevenlabs');
      check(config.ttsVoice).equals('Rachel');
      check(config.ttsSplitOn).equals('paragraphs');
      check(config.ttsVoices.length).equals(1);
      check(config.ttsVoices.first.id).equals('alloy');
      check(config.defaultSttLocale).equals('en-US');
      check(config.audioSampleRate).equals(16000);
      check(config.audioFrameSize).equals(320);
      check(config.vadEnabled).equals(true);
      check(config.enableLdap).isFalse();
      check(config.enableLoginForm).isTrue();
    });

    test('toJson produces expected keys', () {
      final config = BackendConfig(
        enableWebsocket: true,
        sttProvider: 'whisper',
        ttsVoices: const [BackendTtsVoice(id: 'alloy', name: 'Alloy')],
      );
      final json = config.toJson();

      check(json['enable_websocket']).equals(true);
      check(json['stt_provider']).equals('whisper');
      check(json.containsKey('tts_split_on')).isTrue();
      check((json['tts_voices'] as List).length).equals(1);
    });

    test('OAuthProviders hasAnyProvider true', () {
      final providers = OAuthProviders.fromJson({'google': 'Google'});
      check(providers.hasAnyProvider).isTrue();
      check(providers.enabledProviders).contains('google');
    });

    test('OAuthProviders hasAnyProvider false', () {
      final providers = OAuthProviders.fromJson({});
      check(providers.hasAnyProvider).isFalse();
      check(providers.enabledProviders).isEmpty();
    });

    test('OAuthProviders round-trip', () {
      final providers = OAuthProviders(google: 'Google', github: 'GitHub');
      final json = providers.toJson();
      check(json['google']).equals('Google');
      check(json['github']).equals('GitHub');
      check(json.containsKey('microsoft')).isFalse();
    });

    test('fromJson with nested features format', () {
      final config = BackendConfig.fromJson({
        'features': {
          'enable_websocket': false,
          'enable_audio_input': true,
          'tts_split_on': 'none',
        },
      });
      check(config.enableWebsocket).equals(false);
      check(config.enableAudioInput).equals(true);
      check(config.ttsSplitOn).equals('none');
    });

    test('websocketOnly and pollingOnly', () {
      final wsOnly = BackendConfig(enableWebsocket: true);
      check(wsOnly.websocketOnly).isTrue();
      check(wsOnly.pollingOnly).isFalse();

      final pollOnly = BackendConfig(enableWebsocket: false);
      check(pollOnly.websocketOnly).isFalse();
      check(pollOnly.pollingOnly).isTrue();
    });

    test('fromJson parses OAuth providers', () {
      final config = BackendConfig.fromJson({
        'oauth': {
          'providers': {'google': 'Google', 'oidc': 'Corporate SSO'},
        },
      });
      check(config.oauthProviders.hasAnyProvider).isTrue();
      check(config.oauthProviders.google).equals('Google');
      check(config.oauthProviders.oidc).equals('Corporate SSO');
    });
  });

  group('SocketHealth', () {
    test('fromJson', () {
      final health = SocketHealth.fromJson({
        'latencyMs': 42,
        'isConnected': true,
        'transport': 'websocket',
        'reconnectCount': 1,
        'lastHeartbeat': '2024-06-15T12:00:00.000Z',
      });

      check(health.latencyMs).equals(42);
      check(health.isConnected).isTrue();
      check(health.transport).equals('websocket');
      check(health.reconnectCount).equals(1);
      check(health.lastHeartbeat).isNotNull();
    });

    test('toJson round-trip', () {
      final health = SocketHealth(
        latencyMs: 100,
        isConnected: true,
        transport: 'websocket',
        reconnectCount: 0,
      );
      final json = health.toJson();

      check(json['latencyMs']).equals(100);
      check(json['isConnected']).equals(true);
      check(json['transport']).equals('websocket');
      check(json['reconnectCount']).equals(0);
      check(json['lastHeartbeat']).isNull();
    });

    test('isWebSocket returns true for websocket transport', () {
      final health = SocketHealth(
        latencyMs: 50,
        isConnected: true,
        transport: 'websocket',
        reconnectCount: 0,
      );
      check(health.isWebSocket).isTrue();
      check(health.isPolling).isFalse();
    });

    test('quality thresholds', () {
      check(
        SocketHealth(
          latencyMs: -1,
          isConnected: false,
          transport: 'unknown',
          reconnectCount: 0,
        ).quality,
      ).equals('unknown');

      check(
        SocketHealth(
          latencyMs: 50,
          isConnected: true,
          transport: 'websocket',
          reconnectCount: 0,
        ).quality,
      ).equals('excellent');

      check(
        SocketHealth(
          latencyMs: 200,
          isConnected: true,
          transport: 'websocket',
          reconnectCount: 0,
        ).quality,
      ).equals('good');

      check(
        SocketHealth(
          latencyMs: 500,
          isConnected: true,
          transport: 'polling',
          reconnectCount: 0,
        ).quality,
      ).equals('fair');

      check(
        SocketHealth(
          latencyMs: 2000,
          isConnected: true,
          transport: 'polling',
          reconnectCount: 0,
        ).quality,
      ).equals('poor');
    });

    test('defaults for missing fields', () {
      final health = SocketHealth.fromJson({});
      check(health.latencyMs).equals(-1);
      check(health.isConnected).isFalse();
      check(health.transport).equals('unknown');
      check(health.reconnectCount).equals(0);
      check(health.lastHeartbeat).isNull();
    });
  });

  group('SocketTransportAvailability', () {
    test('fromJson/toJson round-trip', () {
      final json = {'allowPolling': true, 'allowWebsocketOnly': false};

      final avail = SocketTransportAvailability.fromJson(json);
      check(avail.allowPolling).isTrue();
      check(avail.allowWebsocketOnly).isFalse();

      final output = avail.toJson();
      check(output['allowPolling']).equals(true);
      check(output['allowWebsocketOnly']).equals(false);
    });

    test('defaults to false for missing fields', () {
      final avail = SocketTransportAvailability.fromJson({});
      check(avail.allowPolling).isFalse();
      check(avail.allowWebsocketOnly).isFalse();
    });
  });

  group('Conversation', () {
    test('minimal fromJson', () {
      final conv = Conversation.fromJson({
        'id': 'conv1',
        'title': 'Hello World',
        'createdAt': '2024-06-15T12:00:00.000Z',
        'updatedAt': '2024-06-15T13:00:00.000Z',
      });

      check(conv.id).equals('conv1');
      check(conv.title).equals('Hello World');
      check(conv.messages).isEmpty();
      check(conv.metadata).isEmpty();
      check(conv.pinned).isFalse();
      check(conv.archived).isFalse();
      check(conv.tags).isEmpty();
    });

    test('fromJson with optional fields', () {
      final conv = Conversation.fromJson({
        'id': 'conv2',
        'title': 'Test',
        'createdAt': '2024-06-15T12:00:00.000Z',
        'updatedAt': '2024-06-15T13:00:00.000Z',
        'model': 'gpt-4',
        'pinned': true,
        'archived': true,
        'shareId': 'share1',
        'folderId': 'folder1',
        'tags': ['important', 'work'],
      });

      check(conv.model).equals('gpt-4');
      check(conv.pinned).isTrue();
      check(conv.archived).isTrue();
      check(conv.shareId).equals('share1');
      check(conv.folderId).equals('folder1');
      check(conv.tags).deepEquals(['important', 'work']);
    });
  });
}
