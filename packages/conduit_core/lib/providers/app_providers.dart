/// Application-wide providers: the server connection and its API client,
/// the model catalogue and selection, the conversation store, and the user's
/// account, settings and feature availability.
///
/// This file is the library root and holds nothing but its imports and its
/// `part` directives. The implementation lives in the parts, split by the
/// domain each group of providers serves.
///
/// They are `part` files rather than separate libraries because these
/// providers lean on library-private helpers across every seam, and because
/// a part is not separately importable -- so none of the several hundred
/// call sites had to change.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:conduit_core/services/api_service.dart';

import 'package:conduit_core/services/attachment_upload_queue.dart';

import 'package:conduit_core/auth/auth_state_manager.dart';

import 'package:conduit_core/auth/openwebui_account_owner_marker.dart';

import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';

import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/backend_config.dart';
import 'package:conduit_core/models/folder.dart';
import 'package:conduit_core/models/file_info.dart';
import 'package:conduit_core/models/server_about_info.dart';
import 'package:conduit_core/models/server_memory.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/models/tool.dart';
import 'package:conduit_core/models/user_settings.dart';
import 'package:conduit_core/models/knowledge_base.dart';

import 'package:conduit_core/services/settings_service.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/secure_credential_storage.dart';
import 'package:conduit_core/services/socket_service.dart';

import 'package:conduit_core/services/connectivity_service.dart';

import 'package:conduit_core/services/conversation_parsing.dart';

import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/persistence/persistence_keys.dart';

import 'package:conduit_core/utils/debug_logger.dart';

import 'package:conduit_core/utils/server_version_compat.dart';

import 'package:conduit_core/services/worker_manager.dart';

import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_session_provenance.dart';
import 'package:conduit_core/features/direct_connections/direct_connections.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';

import 'package:conduit_core/providers/backend_mode_providers.dart';

import 'package:conduit_core/models/socket_transport_availability.dart';

import 'package:conduit_core/providers/storage_providers.dart';

import 'package:drift/drift.dart' show Value;

import 'package:conduit_core/database/app_database.dart';

import 'package:conduit_core/database/database_provider.dart';

import 'package:conduit_core/providers/host_ports.dart';

import 'package:conduit_core/database/chat_database_repository.dart';

import 'package:conduit_core/database/local_conversation_loader.dart';

import 'package:conduit_core/database/mappers/conversation_assembler.dart';

import 'package:conduit_core/sync/chat_locks.dart';
import 'package:conduit_core/sync/pull_sync.dart';
import 'package:conduit_core/sync/sync_engine.dart';

export 'package:conduit_core/providers/storage_providers.dart';

part 'app_providers_active_chats_sync.dart';
part 'app_providers_active_conversation.dart';
part 'app_providers_api_service.dart';
part 'app_providers_conversation_identity.dart';
part 'app_providers_conversations.dart';
part 'app_providers_current_user.dart';
part 'app_providers_default_model.dart';
part 'app_providers_feature_availability.dart';
part 'app_providers_model_selection.dart';
part 'app_providers_models.dart';
part 'app_providers_openwebui_ownership.dart';
part 'app_providers_search.dart';
part 'app_providers_server_config.dart';
part 'app_providers_sign_out.dart';
part 'app_providers_socket.dart';
part 'app_providers_user_settings.dart';
part 'app_providers_workspace_content.dart';
part 'app_providers.g.dart';
