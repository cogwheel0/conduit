# Conduit Privacy Policy

Effective date: 2026-07-11

Conduit is an open‑source mobile client for Open‑WebUI and directly connected AI providers. This app acts as a client to services you choose and configure. This policy describes how the app itself handles data on your device. Open WebUI servers and AI providers may collect, process, and store data under their own policies; please review their privacy terms separately.

## Information We Collect
- Device-stored data: minimal settings and preferences (e.g., theme, UI options) saved locally on your device.
- Authentication tokens, API keys, and direct-connection credentials: stored securely on your device using platform secure storage.
- User-provided content: messages, files, images, and voice input you choose to send are transmitted directly from your device to the Open WebUI server or AI provider selected for that chat. The app does not operate its own backend.
- Diagnostic information: transient error logs in memory for troubleshooting within a session. The app does not include third‑party analytics.

## How We Use Information
- Operate core features such as chat, file uploads, and voice input.
- Remember your preferences and sign‑in state on this device.
- Improve reliability (e.g., displaying error information to you).

## Data Storage and Transfer
- Local storage: preferences and credentials are stored on your device. Access tokens are stored using secure storage where available.
- Network transfer: when you interact with the app, your data is sent to the Open WebUI server or direct AI provider you selected. Direct model requests are not relayed through Open WebUI or any developer‑controlled server.
- Direct chat history: by default, a direct chat is also synchronized to your active Open WebUI server when you are signed in. You can instead keep direct chat history only on this device. Changing this setting applies to new chats and does not automatically upload existing on-device chats.

## Permissions
Depending on how you use Conduit, the app may request:
- Microphone: to capture voice input when you opt in.
- Photos/Files: to let you pick and upload attachments.
- Network access: to connect to your configured Open WebUI server or AI provider, including local-network services such as Ollama.
- Location: to optionally attach your approximate location to chat requests
  when you enable the location feature; requested only when you opt in and
  sent only to your configured server.
- Camera: to capture photos for attachments when you choose the camera option.
- Speech recognition: to transcribe voice input on-device when you use voice
  features; your speech is converted to text on your device when available.

## Third‑Party Services
The app does not include third‑party analytics or advertising SDKs. Open WebUI servers, AI providers, or extensions you use may rely on third‑party services subject to their own terms.

## Security
We use platform‑provided secure storage for sensitive credentials where supported. No security can be guaranteed; protect access to your device and server credentials.

## Data Retention
- On device: preferences and cached media may persist until you clear app data or uninstall. You can revoke sign‑in by logging out.
- On Open WebUI servers and AI providers: retention is determined by each service you use; consult that service’s policy. A provider may retain direct model requests independently of Conduit's optional chat-history sync.

## Your Choices
- You can change servers, remove direct connection profiles, log out, choose on-device-only history for new direct chats, or clear app data in your device settings.
- You can choose not to grant optional permissions; some features may not work without them.

## Children’s Privacy
Conduit is not directed to children under 13 (or the minimum age required in your jurisdiction). Do not use the app if you do not meet the applicable age requirements.

## Changes to This Policy
We may update this policy to reflect improvements or legal requirements. Material changes will be reflected in the app bundle and version notes.

## Contact
For questions or requests about this policy, please contact the app maintainer(s) through the project repository.

