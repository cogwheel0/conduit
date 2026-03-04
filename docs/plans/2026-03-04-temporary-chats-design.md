# Temporary Chats Feature Design

## Overview

Add ephemeral, browser-only temporary chats matching OpenWebUI's implementation.
Temporary chats are never persisted to the backend, don't appear in chat history,
and can optionally be saved to become permanent conversations.

## Approach: Local-Only State

The backend already skips persistence for chat IDs prefixed with `local:`.
We leverage this by using `local:{socketId}` as the conversation ID for
temporary chats, requiring no backend changes.

## State Management

- **`temporaryChatEnabledProvider`**: `StateProvider<bool>`, not keepAlive.
  Resets to false on app restart (unless user has "temporary by default" setting).
- **Chat ID format**: `local:{socketService.sessionId}` when temporary.
- **User setting**: `temporaryChatByDefault` field on `UserSettings` model.
  On new chat init, if true, provider is set to true automatically.

## Chat Flow Guards

When `temporaryChatEnabled` is true, the following are **skipped**:

1. Server conversation creation (`api.createConversation()`) — local
   conversation created with `local:{socketId}` ID instead
2. Server message updates (`updateChatById()`)
3. Title generation (`_generateConversationTitle()`)
4. Draft saving
5. Conversations list insertion — temporary chat does NOT appear in drawer

**Still works normally**: streaming, message display, model selection, context
attachments, all in-chat UI interactions.

## UI Components

### Chat AppBar Toggle
- Icon button next to "New Chat" in app bar actions
- Dotted chat bubble (OFF) / checked variant (ON)
- Visible when no active conversation or current chat is temporary
- Shows tooltip "This chat won't appear in history" when toggled ON

### Save Chat Button
- Appears in app bar when temporary chat has messages
- Creates real server conversation from current messages
- Switches from `local:*` ID to real UUID
- Sets `temporaryChatEnabled = false`
- Adds to `conversationsProvider`

### Settings Toggle
- "Temporary Chat by Default" switch in user preferences
- Persists via `UserSettings` model to server

### Disabled Features
- Conversation tile actions (share, archive, folder, pin) — N/A, not in drawer
- Message rating/feedback UI

## Save Chat Flow

1. Collect messages from `chatMessagesProvider`
2. Generate title from first user message (first 50 chars)
3. Call `api.createConversation()` with real UUID, title, messages, model,
   system prompt
4. On success: update `activeConversationProvider`, upsert to conversations
   list, set temporary to false
5. On failure: show error snackbar, chat remains temporary

## Edge Cases

- **App close/kill**: Temporary chat lost (by design)
- **Switch conversation**: Temporary chat discarded, no confirmation
  (matches OpenWebUI)
- **New Chat while temporary**: Previous temporary chat discarded, temporary
  mode stays ON
- **Socket reconnection**: `local:{socketId}` may change; doesn't matter since
  ID is only a local identifier
- **Toggle OFF mid-chat**: Treated as "Save Chat" — persist to server and
  transition to normal
