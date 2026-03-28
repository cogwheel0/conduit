# Temporary Chats Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add ephemeral temporary chats that are never persisted to the server, matching OpenWebUI's behavior, with the ability to save them to permanent history.

**Architecture:** Local-only state controlled by a `temporaryChatEnabledProvider`. When enabled, conversations use `local:{socketId}` IDs which the backend already ignores for persistence. A "Save Chat" action converts temporary chats to permanent ones via the existing `createConversation` API.

**Tech Stack:** Flutter, Riverpod 3.0 (codegen), Hive (local persistence), ARB (localization)

---

### Task 1: Add persistence key and setting field

**Files:**
- Modify: `lib/core/persistence/persistence_keys.dart:31`
- Modify: `lib/core/services/settings_service.dart:451-619` (AppSettings class)
- Modify: `lib/core/services/settings_service.dart:632-747` (AppSettingsNotifier class)

**Step 1: Add preference key**

In `lib/core/persistence/persistence_keys.dart`, add after line 31 (`androidAssistantTrigger`):

```dart
  static const String temporaryChatByDefault = 'temporary_chat_by_default';
```

**Step 2: Add field to AppSettings class**

In `lib/core/services/settings_service.dart`, add after `voiceSilenceDuration` field (line 474):

```dart
  final bool temporaryChatByDefault;
```

Add to constructor (after `this.voiceSilenceDuration = 2000`):

```dart
  this.temporaryChatByDefault = false,
```

Add to `copyWith` method — add parameter:

```dart
  bool? temporaryChatByDefault,
```

And in the return body:

```dart
  temporaryChatByDefault: temporaryChatByDefault ?? this.temporaryChatByDefault,
```

Add to `operator ==`:

```dart
  other.temporaryChatByDefault == temporaryChatByDefault &&
```

Add to `hashCode`:

```dart
  temporaryChatByDefault,
```

**Step 3: Add static get/set to SettingsService**

Add after `setSendOnEnter` (around line 337):

```dart
  static Future<bool> getTemporaryChatByDefault() {
    final value = _preferencesBox().get(
      PreferenceKeys.temporaryChatByDefault,
    ) as bool?;
    return Future.value(value ?? false);
  }

  static Future<void> setTemporaryChatByDefault(bool value) {
    return _preferencesBox().put(
      PreferenceKeys.temporaryChatByDefault,
      value,
    );
  }
```

**Step 4: Add to _loadSettingsSync**

In the `_loadSettingsSync` method, add to the `AppSettings(...)` constructor call:

```dart
  temporaryChatByDefault: (box.get(PreferenceKeys.temporaryChatByDefault) as bool?) ?? false,
```

**Step 5: Add to saveSettings**

In the `saveSettings` method map, add:

```dart
  PreferenceKeys.temporaryChatByDefault: settings.temporaryChatByDefault,
```

**Step 6: Add setter to AppSettingsNotifier**

After `setSendOnEnter` method:

```dart
  Future<void> setTemporaryChatByDefault(bool value) async {
    state = state.copyWith(temporaryChatByDefault: value);
    await SettingsService.setTemporaryChatByDefault(value);
  }
```

**Step 7: Commit**

```bash
git add lib/core/persistence/persistence_keys.dart lib/core/services/settings_service.dart
git commit -m "feat: add temporaryChatByDefault setting to AppSettings"
```

---

### Task 2: Add temporaryChatEnabled provider

**Files:**
- Modify: `lib/core/providers/app_providers.dart` (near `activeConversationProvider`, ~line 1501)

**Step 1: Add the provider**

Add before `activeConversationProvider` (around line 1500):

```dart
/// Whether the current chat session is temporary (not persisted to server).
///
/// When true, conversations use `local:{socketId}` IDs and skip all
/// server persistence. Resets on app restart unless the user has
/// `temporaryChatByDefault` enabled in settings.
final temporaryChatEnabledProvider = StateProvider<bool>((ref) {
  final settings = ref.watch(appSettingsProvider);
  return settings.temporaryChatByDefault;
});
```

**Step 2: Add helper to check if a conversation is temporary**

Add after the provider:

```dart
/// Returns true if the given conversation ID represents a temporary chat.
bool isTemporaryChat(String? id) =>
    id != null && id.startsWith('local:');
```

**Step 3: Commit**

```bash
git add lib/core/providers/app_providers.dart
git commit -m "feat: add temporaryChatEnabledProvider and isTemporaryChat helper"
```

---

### Task 3: Add localization strings

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: All other `lib/l10n/app_*.arb` files (de, es, fr, it, ko, nl, ru, zh, zh_Hant)

**Step 1: Add English strings**

In `lib/l10n/app_en.arb`, add:

```json
  "temporaryChat": "Temporary Chat",
  "@temporaryChat": {
    "description": "Label for the temporary chat toggle."
  },
  "temporaryChatTooltip": "This chat won't appear in history",
  "@temporaryChatTooltip": {
    "description": "Tooltip shown when temporary chat is enabled."
  },
  "saveChat": "Save Chat",
  "@saveChat": {
    "description": "Action to save a temporary chat to history."
  },
  "temporaryChatByDefault": "Temporary Chat by Default",
  "@temporaryChatByDefault": {
    "description": "Setting to make all new chats temporary by default."
  },
  "temporaryChatByDefaultDescription": "New chats won't be saved to history unless you choose to save them",
  "@temporaryChatByDefaultDescription": {
    "description": "Description for the temporary chat by default setting."
  },
  "chatSaved": "Chat saved to history",
  "@chatSaved": {
    "description": "Snackbar message shown after saving a temporary chat."
  },
  "chatSaveFailed": "Failed to save chat",
  "@chatSaveFailed": {
    "description": "Snackbar message shown when saving a temporary chat fails."
  },
```

**Step 2: Add placeholder strings to all other ARB files**

Copy the same English strings to all other ARB files. They can be translated later — the English fallback will work in the meantime.

**Step 3: Run code generation**

```bash
cd /Users/tunap/Development/qonduit && flutter gen-l10n
```

**Step 4: Commit**

```bash
git add lib/l10n/
git commit -m "feat: add localization strings for temporary chats"
```

---

### Task 4: Guard conversation creation in sendMessage

**Files:**
- Modify: `lib/features/chat/providers/chat_providers.dart:1844-1930`

**Step 1: Modify the new conversation creation block**

In `_sendMessageInternal`, find the block starting at line 1844:

```dart
var activeConversation = ref.read(activeConversationProvider);

if (activeConversation == null) {
```

Replace the entire `if (activeConversation == null) { ... }` block with a version that checks `temporaryChatEnabledProvider`:

```dart
var activeConversation = ref.read(activeConversationProvider);

if (activeConversation == null) {
  final pendingFolderId = ref.read(pendingFolderIdProvider);
  final isTemporary = ref.read(temporaryChatEnabledProvider);

  if (isTemporary) {
    // Temporary chat: use local ID, skip server creation entirely
    final socketId =
        ref.read(socketServiceProvider)?.sessionId ?? 'unknown';
    final localConversation = Conversation(
      id: 'local:$socketId',
      title: 'New Chat',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      systemPrompt: userSystemPrompt,
      messages: [userMessage, assistantPlaceholder],
    );

    ref.read(activeConversationProvider.notifier).set(localConversation);
    activeConversation = localConversation;
    ref.read(pendingFolderIdProvider.notifier).clear();
  } else {
    // Existing code for non-temporary conversation creation...
    final localConversation = Conversation(
      id: const Uuid().v4(),
      // ... rest of existing code unchanged
    );
    // ... server creation code unchanged
  }
}
```

Keep the entire existing `else` branch (non-temporary) exactly as-is. The temporary branch simply creates a local conversation with `local:` prefix and skips server calls.

**Step 2: Guard title generation**

Find the `shouldGenerateTitle` logic (around line 1503 and 2229). Wrap it:

```dart
final isTemporary = ref.read(temporaryChatEnabledProvider);
bool shouldGenerateTitle = false;
if (!isTemporary) {
  try {
    final conv = ref.read(activeConversationProvider);
    // ... existing title generation logic
  } catch (_) {}
}
```

Do the same for the second occurrence (~line 2229).

**Step 3: Guard finishStreaming server updates**

In `finishStreaming()` (~line 756-793), find the block that updates `conversationsProvider` and calls `refreshConversationsCache`. Wrap the conversations list update and cache refresh in a temporary check:

```dart
    final activeConversation = ref.read(activeConversationProvider);
    if (activeConversation != null) {
      final updatedActive = activeConversation.copyWith(
        messages: List<ChatMessage>.unmodifiable(state),
        updatedAt: DateTime.now(),
      );
      ref.read(activeConversationProvider.notifier).set(updatedActive);

      // Skip conversations list update for temporary chats
      if (!isTemporaryChat(activeConversation.id)) {
        final conversationsAsync = ref.read(conversationsProvider);
        // ... existing upsert code
      }
    }

    // Skip server cache refresh for temporary chats
    if (!isTemporaryChat(
      ref.read(activeConversationProvider)?.id,
    )) {
      try {
        refreshConversationsCache(ref);
      } catch (_) {}
    }
```

**Step 4: Commit**

```bash
git add lib/features/chat/providers/chat_providers.dart
git commit -m "feat: guard chat flow for temporary chats - skip server persistence"
```

---

### Task 5: Add temporary chat toggle to chat AppBar

**Files:**
- Modify: `lib/features/chat/views/chat_page.dart:1908-1943`

**Step 1: Add the toggle button before the New Chat button**

In the `actions:` list, inside the `if (!_isSelectionMode)` block, add a temporary chat toggle before the existing New Chat button:

```dart
actions: [
  if (!_isSelectionMode) ...[
    // Temporary chat toggle
    Consumer(
      builder: (context, ref, _) {
        final isTemporary = ref.watch(temporaryChatEnabledProvider);
        final activeConversation =
            ref.watch(activeConversationProvider);
        final hasMessages =
            ref.watch(chatMessagesProvider).isNotEmpty;

        // Show toggle when: no conversation, or current is temporary
        final showToggle = activeConversation == null ||
            isTemporaryChat(activeConversation.id);

        if (!showToggle) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(right: Spacing.xs),
          child: AdaptiveTooltip(
            message: isTemporary
                ? AppLocalizations.of(context)!
                      .temporaryChatTooltip
                : AppLocalizations.of(context)!.temporaryChat,
            child: _buildAppBarIconButton(
              context: context,
              onPressed: () {
                HapticFeedback.selectionClick();
                final current = ref.read(
                  temporaryChatEnabledProvider,
                );
                if (!current) {
                  ref
                      .read(
                        temporaryChatEnabledProvider.notifier,
                      )
                      .state = true;
                } else if (hasMessages) {
                  // Toggle OFF with messages = save chat
                  _saveTemporaryChat(ref);
                } else {
                  ref
                      .read(
                        temporaryChatEnabledProvider.notifier,
                      )
                      .state = false;
                }
              },
              fallbackIcon: isTemporary
                  ? Icons.chat_bubble
                  : Icons.chat_bubble_outline,
              sfSymbol: isTemporary
                  ? 'bubble.left.fill'
                  : 'bubble.left',
              color: isTemporary
                  ? context.qonduitTheme.primary
                  : context.qonduitTheme.textPrimary,
            ),
          ),
        );
      },
    ),
    // Save Chat button (visible when temporary chat has messages)
    Consumer(
      builder: (context, ref, _) {
        final isTemporary = ref.watch(temporaryChatEnabledProvider);
        final hasMessages =
            ref.watch(chatMessagesProvider).isNotEmpty;
        final activeConversation =
            ref.watch(activeConversationProvider);

        if (!isTemporary ||
            !hasMessages ||
            activeConversation == null) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.only(right: Spacing.xs),
          child: AdaptiveTooltip(
            message: AppLocalizations.of(context)!.saveChat,
            child: _buildAppBarIconButton(
              context: context,
              onPressed: () => _saveTemporaryChat(ref),
              fallbackIcon: Platform.isIOS
                  ? CupertinoIcons.arrow_down_doc
                  : Icons.save_alt,
              sfSymbol: 'square.and.arrow.down',
              color: context.qonduitTheme.textPrimary,
            ),
          ),
        );
      },
    ),
    // Existing New Chat button
    Padding(
      // ... existing code unchanged
    ),
  ] else ...[
    // ... existing selection mode code unchanged
  ],
],
```

**Step 2: Commit**

```bash
git add lib/features/chat/views/chat_page.dart
git commit -m "feat: add temporary chat toggle and save button to chat AppBar"
```

---

### Task 6: Implement _saveTemporaryChat method

**Files:**
- Modify: `lib/features/chat/views/chat_page.dart`

**Step 1: Add the save method**

Add near `startNewChat()` (around line 82):

```dart
Future<void> _saveTemporaryChat(WidgetRef ref) async {
  final messages = ref.read(chatMessagesProvider);
  if (messages.isEmpty) return;

  final api = ref.read(apiServiceProvider);
  final activeConversation = ref.read(activeConversationProvider);
  if (activeConversation == null) return;

  // Generate title from first user message
  final firstUserMsg = messages.firstWhere(
    (m) => m.role == 'user',
    orElse: () => messages.first,
  );
  final title = firstUserMsg.content.length > 50
      ? '${firstUserMsg.content.substring(0, 50)}...'
      : firstUserMsg.content.isEmpty
          ? 'New Chat'
          : firstUserMsg.content;

  try {
    final selectedModel = ref.read(selectedModelProvider);
    final serverConversation = await api.createConversation(
      title: title,
      messages: messages,
      model: selectedModel?.id ?? '',
      systemPrompt: activeConversation.systemPrompt,
      folderId: activeConversation.folderId,
    );

    // Transition to permanent chat
    final updatedConversation = serverConversation.copyWith(
      messages: messages,
    );
    ref
        .read(activeConversationProvider.notifier)
        .set(updatedConversation);
    ref
        .read(conversationsProvider.notifier)
        .upsertConversation(
          updatedConversation.copyWith(
            messages: const [],
            updatedAt: DateTime.now(),
          ),
        );
    ref.read(temporaryChatEnabledProvider.notifier).state = false;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.chatSaved,
          ),
        ),
      );
    }
  } catch (e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.chatSaveFailed,
          ),
        ),
      );
    }
  }
}
```

**Step 2: Commit**

```bash
git add lib/features/chat/views/chat_page.dart
git commit -m "feat: implement _saveTemporaryChat to persist temporary chats"
```

---

### Task 7: Initialize temporary mode on new chat

**Files:**
- Modify: `lib/features/chat/views/chat_page.dart` (startNewChat method, ~line 82)

**Step 1: Update startNewChat to respect temporaryChatByDefault**

Add at the end of `startNewChat()`:

```dart
void startNewChat() {
  // ... existing code ...

  // Reset temporary chat state based on user preference
  final settings = ref.read(appSettingsProvider);
  ref.read(temporaryChatEnabledProvider.notifier).state =
      settings.temporaryChatByDefault;
}
```

**Step 2: Do the same in `_startNewChatInFolder` in chats_drawer.dart**

In `lib/features/navigation/widgets/chats_drawer.dart`, add the same line at the end of `_startNewChatInFolder()`:

```dart
void _startNewChatInFolder(String folderId) {
  // ... existing code ...

  // Reset temporary chat state based on user preference
  final settings = ref.read(appSettingsProvider);
  ref.read(temporaryChatEnabledProvider.notifier).state =
      settings.temporaryChatByDefault;
}
```

**Step 3: Commit**

```bash
git add lib/features/chat/views/chat_page.dart lib/features/navigation/widgets/chats_drawer.dart
git commit -m "feat: initialize temporary chat mode on new chat based on user setting"
```

---

### Task 8: Add settings toggle in preferences

**Files:**
- Modify: `lib/features/profile/views/app_customization_page.dart`

**Step 1: Add toggle in settings page**

Find the existing toggle section (e.g., near the `sendOnEnter` toggle). Add a new list tile for temporary chat:

```dart
ListTile(
  title: Text(
    AppLocalizations.of(context)!.temporaryChatByDefault,
  ),
  subtitle: Text(
    AppLocalizations.of(context)!
        .temporaryChatByDefaultDescription,
    style: Theme.of(context).textTheme.bodySmall,
  ),
  trailing: AdaptiveSwitch(
    value: settings.temporaryChatByDefault,
    onChanged: (value) => ref
        .read(appSettingsProvider.notifier)
        .setTemporaryChatByDefault(value),
  ),
),
```

**Step 2: Commit**

```bash
git add lib/features/profile/views/app_customization_page.dart
git commit -m "feat: add temporary chat by default toggle in settings"
```

---

### Task 9: Handle edge case — conversation selection clears temporary state

**Files:**
- Modify: `lib/features/navigation/widgets/chats_drawer.dart` (~line 1627, `_selectConversation`)

**Step 1: Clear temporary mode when selecting a conversation**

At the start of `_selectConversation`, add:

```dart
Future<void> _selectConversation(BuildContext context, String id) async {
  if (_isLoadingConversation) return;
  setState(() => _isLoadingConversation = true);

  final container = ProviderScope.containerOf(context, listen: false);

  // Selecting a real conversation exits temporary mode
  container.read(temporaryChatEnabledProvider.notifier).state = false;

  // ... rest of existing code
```

**Step 2: Commit**

```bash
git add lib/features/navigation/widgets/chats_drawer.dart
git commit -m "feat: clear temporary chat mode when selecting a conversation"
```

---

### Task 10: Verify and fix imports

**Files:**
- Modify: All files touched in previous tasks (add missing imports)

**Step 1: Ensure all files import the provider**

Files that reference `temporaryChatEnabledProvider` or `isTemporaryChat` need:

```dart
import 'package:qonduit/core/providers/app_providers.dart';
```

This is likely already imported in most files. Verify and add where missing.

**Step 2: Run analysis**

```bash
cd /Users/tunap/Development/qonduit && flutter analyze
```

Fix any issues found.

**Step 3: Run build_runner for codegen**

```bash
cd /Users/tunap/Development/qonduit && dart run build_runner build --delete-conflicting-outputs
```

**Step 4: Run tests**

```bash
cd /Users/tunap/Development/qonduit && flutter test
```

**Step 5: Commit any fixes**

```bash
git add -A && git commit -m "fix: resolve imports and analysis issues for temporary chats"
```

---

### Task 11: Manual smoke test

**No files to modify — verification only.**

**Step 1: Run the app**

```bash
cd /Users/tunap/Development/qonduit && flutter run
```

**Step 2: Test scenarios**

1. Start a new chat — verify temporary toggle is visible in app bar
2. Toggle temporary ON — verify tooltip shows "This chat won't appear in history"
3. Send a message — verify chat works, no conversation appears in drawer
4. Tap "Save Chat" — verify chat appears in drawer, temporary toggle turns off
5. Start new temporary chat, send messages, then select a conversation from drawer — verify temporary chat is discarded
6. Go to settings, enable "Temporary Chat by Default" — start a new chat and verify it defaults to temporary mode
7. Toggle temporary OFF mid-chat with messages — verify it saves the chat
