import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/calendar_settings_pages.dart';
import 'pages/chat_data_settings_pages.dart';
import 'pages/direct_connection_settings_pages.dart';
import 'pages/hermes_job_settings_pages.dart';
import 'pages/hermes_mcp_settings_pages.dart';
import 'pages/hermes_settings_pages.dart';
import 'pages/librechat_memory_settings_pages.dart';
import 'pages/personal_connection_settings_pages.dart';
import 'pages/push_settings_pages.dart';
import 'pages/scheduled_task_settings_pages.dart';
import 'pages/server_address_settings_pages.dart';
import 'pages/webhook_settings_pages.dart';
import 'pages/workspace_knowledge_settings_pages.dart';
import 'pages/workspace_model_settings_pages.dart';
import 'pages/workspace_prompt_settings_pages.dart';
import 'pages/workspace_settings_pages.dart';
import 'pages/workspace_skill_settings_pages.dart';
import 'pages/workspace_tool_settings_pages.dart';

/// A group of Settings pages kept together: which pages it draws, how it
/// fills them in when they appear, and what their rows do.
///
/// The native sheet and the Flutter Settings pages draw a module's pages
/// alike; the hydration service asks the module to fill in a page it owns,
/// and the controller hands it the changes its rows send.
abstract class SettingsPageModule {
  /// Whether page [detailId] is one of this module's.
  bool ownsPage(String detailId);

  /// Fills in page [detailId] as it appears.
  Future<void> hydrate(String detailId, AppLocalizations l10n);

  /// Acts on a row change from one of this module's pages. Returns whether
  /// [id] was one of its rows.
  Future<bool> handleChange(String id, Object? value, AppLocalizations l10n);

  /// Page [detailId] is gone: popped, or closed with Settings. Work it
  /// started that nobody waits for can stop.
  void pageLeft(String detailId) {}

  /// Settings closed, every page of it with it.
  void settingsClosed() {}
}

final settingsPageModulesProvider = Provider<List<SettingsPageModule>>(
  (ref) => [
    WebhookSettingsPages(ref),
    LibreChatMemorySettingsPages(ref),
    ServerAddressSettingsPages(ref),
    ChatDataSettingsPages(ref),
    DirectConnectionSettingsPages(ref),
    HermesSettingsPages(ref),
    HermesJobSettingsPages(ref),
    HermesMcpSettingsPages(ref),
    ScheduledTaskSettingsPages(ref),
    PersonalConnectionSettingsPages(ref),
    PushSettingsPages(ref),
    CalendarSettingsPages(ref),
    WorkspaceSettingsPages(ref),
    WorkspaceModelSettingsPages(ref),
    WorkspaceKnowledgeSettingsPages(ref),
    WorkspacePromptSettingsPages(ref),
    WorkspaceToolSettingsPages(ref),
    WorkspaceSkillSettingsPages(ref),
  ],
);
