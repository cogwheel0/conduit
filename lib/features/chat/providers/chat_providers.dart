/// Providers for the chat feature: the message transcript, the turn
/// pipelines for all three backends, and the conversation mutations.
///
/// This file is the library root and holds nothing but its imports and its
/// `part` directives. The implementation lives in the parts, which are split
/// by domain rather than by layer -- a turn pipeline touches state, storage
/// and transport together, so cutting it any other way would just scatter it.
///
/// They are `part` files rather than separate libraries on purpose. The code
/// leans hard on library-private helpers across every seam (the `ref` readers
/// in `chat_context_readers.dart` are reached from all of them), so making it
/// libraries would mean promoting that scaffolding to public API. Parts keep
/// privacy intact and keep every importer's path unchanged.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:conduit_core/utils/openwebui_request_variables.dart';
import 'package:conduit_core/ports/app_lifecycle.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:yaml/yaml.dart' as yaml;

import 'package:conduit_core/auth/auth_state_manager.dart';

import 'package:conduit_core/auth/api_auth_interceptor.dart';
import 'package:conduit_core/auth/openwebui_account_owner_marker.dart';

import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/openwebui_chat_prompt.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/server_config.dart';

import 'package:conduit_core/database/account_storage_isolation.dart';
// Re-exported because it used to live in this library and a dozen callers
// still reach it through here. An imported symbol is not re-exported, so
// moving it to the core without this turns every one of those into an error.
export 'package:conduit_core/database/account_storage_isolation.dart'
    show conversationUsesOpenWebUiStorage;
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/daos/outbox_dao.dart';
import 'package:conduit_core/database/database_manager.dart';

import 'package:conduit_core/database/database_provider.dart';

import 'package:conduit_core/database/chat_database_repository.dart';

import 'package:conduit_core/database/local_conversation_loader.dart';

import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:conduit_core/database/mappers/conversation_assembler.dart';
import 'package:conduit_core/database/models/chat_transcript_window.dart';

import 'package:conduit_core/providers/host_ports.dart';

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/sync/chat_locks.dart';

import 'package:conduit_core/sync/clock.dart';

import 'package:conduit_core/sync/id_remapper.dart';

import 'package:conduit_core/sync/outbox_drainer.dart'
    show OutboxDeferralException;
import 'package:conduit_core/sync/sync_engine.dart';
import 'package:conduit_core/sync/sync_api_client.dart'
    show SyncTerminalException;

import 'package:conduit_core/services/chat_completion_transport.dart';

import 'package:conduit_core/services/api_service.dart';

import '../../../core/services/location_service.dart';

import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/socket_service.dart';
import 'package:conduit_core/services/streaming_response_controller.dart';

import 'package:conduit_core/services/streaming_helper.dart';

import 'package:conduit_core/services/performance_profiler.dart';

import 'package:conduit_core/services/conversation_parsing.dart';

import 'package:conduit_core/services/worker_manager.dart';
import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/utils/json_normalization.dart';

import 'package:conduit_core/utils/message_tree_utils.dart' as message_tree;

import 'package:conduit_core/utils/openwebui_message_payload.dart';
import 'package:conduit_core/utils/persisted_message_content.dart';

import 'package:conduit_markdown/conduit_markdown.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import '../utils/follow_ups_socket_event.dart';

import 'package:conduit_core/features/hermes/models/hermes_chat_input.dart';
import 'package:conduit_core/features/hermes/models/hermes_capabilities.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';

import '../../hermes/controllers/hermes_busy_turn_controller.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_backend_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_local_document_trust_store.dart';
import 'package:conduit_core/features/hermes/services/hermes_message_mapper.dart';
import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_client.dart';

import '../models/chat_context_attachment.dart';
import '../providers/context_attachments_provider.dart';
import '../providers/reasoning_effort_provider.dart';

import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/utils/system_prompt.dart';
import 'package:conduit_core/features/direct_connections/services/direct_chat_storage.dart';

import '../services/chat_transport_dispatch.dart';
import '../services/chat_history_reader.dart';
import '../services/file_attachment_service.dart';
import '../services/reviewer_mode_service.dart';
import '../../../shared/theme/theme_providers.dart';

part 'chat_attachments.dart';
part 'chat_capability_providers.dart';
part 'chat_composer_providers.dart';
part 'chat_context_readers.dart';
part 'chat_conversation_mutations.dart';
part 'chat_direct_routing.dart';
part 'chat_direct_turns.dart';
part 'chat_feature_defaults.dart';
part 'chat_generation_control.dart';
part 'chat_headless_completion.dart';
part 'chat_hermes_projection_store.dart';
part 'chat_hermes_replay.dart';
part 'chat_hermes_turns.dart';
part 'chat_message_structure.dart';
part 'chat_messages_notifier.dart';
part 'chat_mutation_ownership.dart';
part 'chat_openapi_tools.dart';
part 'chat_openwebui_requests.dart';
part 'chat_regeneration.dart';
part 'chat_send_message.dart';
part 'chat_send_placeholder.dart';
part 'chat_session_lifecycle.dart';
part 'chat_streaming_content.dart';
part 'chat_transcript_paging.dart';
part 'chat_providers.g.dart';
