# Conduit Privacy Policy

Effective date: 2026-11-12

Conduit is an open‑source client for Open‑WebUI and directly connected AI providers, on mobile and on the Mac (Conduit Desktop). This app acts as a client to services you choose and configure. This policy describes how the app itself handles data on your device. Open WebUI servers and AI providers may collect, process, and store data under their own policies; please review their privacy terms separately.

## Information We Collect
- Device-stored data: minimal settings and preferences (e.g., theme, UI options) saved locally on your device.
- Authentication tokens, API keys, and direct-connection credentials: stored securely on your device using platform secure storage.
- User-provided content: messages, files, images, and voice input you choose to send are transmitted directly from your device to the Open WebUI server or AI provider selected for that chat. The app does not operate a backend that receives your content. The only developer-operated service is the optional push notification relay described below, and it only carries encrypted notifications it cannot read.
- Diagnostic information: transient error logs in memory for troubleshooting within a session. The app does not include third‑party analytics.

## How We Use Information
- Operate core features such as chat, file uploads, and voice input.
- Remember your preferences and sign‑in state on this device.
- Improve reliability (e.g., displaying error information to you).

## Data Storage and Transfer
- Local storage: preferences and credentials are stored on your device. Access tokens are stored using secure storage where available.
- Network transfer: when you interact with the app, your data is sent to the Open WebUI server, Hermes server, or direct AI provider you selected. Direct model requests are not relayed through Open WebUI or any developer‑controlled server.
- Direct chat history: by default, a direct chat is also synchronized to your active Open WebUI server when you are signed in. You can instead keep direct chat history only on this device. Changing this setting applies to new chats and does not automatically upload existing on-device chats.
- Apple On-Device: when you select Apple On-Device, model inference runs locally through Apple's Foundation Models framework. Prompt and response content is not sent to an AI provider by Conduit, though optional Open WebUI history synchronization remains a separate setting.
- Apple Private Cloud Compute: when you select the Apple PCC provider, Conduit sends the conversation content and selected images needed for that request to Apple's Private Cloud Compute service. Conduit does not operate an intermediary server. If you enable on-device fallback, a PCC network failure may instead be retried with Apple's on-device model. Apple's processing and retention terms apply separately from Conduit's optional Open WebUI history synchronization.
- On-device web search: when you turn on web search for a direct model that has no web search of its own, Conduit searches from your device. The search queries the model writes are sent directly to a public search engine: by default DuckDuckGo, then Brave, Bing, Mojeek or Wikipedia if it does not answer, or only the engine you pick in settings. When the model opens a result, or a link you wrote in your message, that page is downloaded directly from your device. These requests carry your device's IP address and your chosen region and safe-search setting, and are not sent through Open WebUI or any developer-controlled server. Search results and page text are then sent to the AI provider as part of the conversation.

## Push Notifications (optional)
Push notifications are off until you turn them on. When you do:
- Your device creates a key pair and secret for each Open WebUI account and Hermes connection, and keeps the private parts in platform secure storage on this device only.
- Conduit gives your own server the public key, the secret, a random device id, a device label, and a delivery address. Open WebUI stores them with the Conduit Push function, which an administrator installs; Hermes stores them with its Conduit plugin.
- Your server encrypts each notification (a title and a preview of at most 200 characters) so that only your device can read it.
- On iOS, and on Android when you use Google's delivery service, the encrypted notification passes through the Conduit push relay operated by the developer, and then Apple Push Notification service or Firebase Cloud Messaging. The relay sees your device's push token, your device's IP address when it registers, your server's IP address, the time, and the notification's size class, but never its content, your account, or your server's name or URL. It keeps no database and no access logs. Apple and Google see the push token, the time, and the encrypted notification.
- On Android you can instead use a UnifiedPush distributor you choose; then the relay is not involved.
- Turning push notifications off, signing out, or removing an account deletes that device's keys and asks your server to forget the device.

Details: docs/push/THREAT_MODEL.md in the source repository.

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
- Notifications: to alert you when a reply, channel message, or scheduled
  task finishes; requested only when you turn notifications on.

## Third‑Party Services
The app does not include third‑party analytics or advertising SDKs. The Android build distributed through Google Play includes Firebase Cloud Messaging, used only to deliver encrypted push notifications after you turn them on; Firebase Analytics is not included and Firebase is not started before then. The FOSS Android build contains no Google services. Open WebUI servers, AI providers, or extensions you use may rely on third‑party services subject to their own terms. When you use on-device web search, the search engines and websites your device contacts process those requests under their own privacy policies.

## Security
We use platform‑provided secure storage for sensitive credentials where supported. No security can be guaranteed; protect access to your device and server credentials.

## Data Retention
- On device: preferences and cached media may persist until you clear app data or uninstall. You can revoke sign‑in by logging out.
- On Open WebUI servers and AI providers: retention is determined by each service you use; consult that service’s policy. A provider may retain direct model requests independently of Conduit's optional chat-history sync.

## Your Choices
- You can change servers, remove direct connection profiles, log out, choose on-device-only history for new direct chats, or clear app data in your device settings.
- You can turn web search off for a chat, and choose which search engine on-device web search uses, in the Direct Connections settings.
- You can turn push notifications on or off, and choose which accounts and kinds of notification use them, in Notifications settings.
- You can choose not to grant optional permissions; some features may not work without them.

## Conduit Desktop (macOS)
Conduit Desktop is the app for Apple Silicon Macs. Everything above applies to it as well; this section covers what is specific to the Mac.
- Local data: your accounts, settings, preferences and the chats downloaded to your Mac are kept in `~/Library/Application Support/Conduit`. The app runs a helper process (`conduitd`) that keeps this data and talks to your servers; the app reaches it only over the loopback interface (127.0.0.1) with a secret that changes on every launch, so other devices cannot connect to it.
- Credentials: sign-in tokens, API keys and other secrets are kept in an encrypted store in that folder. Its encryption key is created on your Mac and kept in the macOS Keychain (item `app.cogwheel.conduit.desktop`); it is never written to disk unencrypted and never leaves your Mac.
- Logs and diagnostics: the app and the helper write diagnostic logs (and a crash report if the app crashes) to `~/Library/Logs/Conduit`. They stay on your Mac and are never uploaded; the logs are rotated, and only the ten newest crash reports are kept. Settings › About › Export diagnostics saves the logs and a redacted configuration to a zip file on your Mac and shows it in Finder; nothing is sent anywhere unless you choose to share that file.
- Notifications: if you allow them, the notification that an answer has finished, here or on another device signed in to the same account, shows only the chat's title and “Answer ready”, never the text of your messages or the answer, because notifications can appear on the lock screen and on shared screens. Channel notifications follow your Settings › Notifications choices. Conduit Desktop does not use a push notification service: the app learns of new answers and messages over its own connection to your server while it runs.
- Microphone and speech recognition: the app uses the microphone only while you dictate or are in a voice call. When you choose On This Mac for dictation, the Mac's speech recognizer runs on your Mac only; the app does not use Apple's server-based recognition. When you choose your server's speech-to-text, the recording is sent to your Open WebUI server, as on mobile. A dictation's recording is kept with your unsent draft on your Mac until you send or discard it.
- Local transcription (Whisper): if you choose a local Whisper model, the app downloads it once, when you ask for it, from Hugging Face (`huggingface.co`), which receives your IP address as with any download. Transcription with it then happens on your Mac.
- Location: the app asks macOS for your location only when a prompt or request names `{{USER_LOCATION}}` and your account's location setting is on. Your approximate position is then filled into that prompt and goes to your server with the request, as on mobile.
- Local network: macOS asks before the app reaches your local network. The app uses it only to connect to servers you add there, such as a self-hosted Open WebUI, a model provider or an MCP tool server.
- Camera: Continuity Camera in the + menu takes a photo, scan or sketch with your iPhone or iPad when you choose it; the result is attached to your message like any other file. The Mac app does not use the Mac's own camera.
- Remote pictures and PDFs: pictures and PDF links in answers that point to a site other than your server are not loaded until you click Load Image (or Load Preview for a PDF), or you allow that site (Always Load Images from …, listed in Settings › Chats › Remote Content). The helper then downloads them directly from that site, without your server's credentials, cookies or a referrer; that site receives your IP address. Addresses on your Mac itself or link-local addresses are never fetched this way. Diagrams and charts in answers are drawn on your Mac, with no network access.
- Sharing into Conduit: the Share extension copies what you share into a folder in `~/Library/Caches` that only the app reads; the app removes each share ten minutes after taking it, and shares never opened after a day.
- Widget, Shortcuts and Services: the desktop widget shows your newest chats' titles and times from a small file the app writes into its own App Group container (never message text, and no chats while you are signed out). Shortcuts, Spotlight and Siri can list your chats by title through the app's actions, and run Ask Conduit, which sends the text you give it to your server like any message. The Services menu's items open Conduit with the text you selected; nothing is sent until you send it.
- Hermes: when you sign in to a Hermes dashboard, its session cookies are kept in the helper's encrypted store and sent only to that dashboard. A voice call with a Hermes agent that uses live voice connects your Mac directly to the voice service your Hermes gateway names (WebRTC, possibly through the relays it names), which receives your audio and IP address.
- No telemetry: the app includes no analytics, advertising or crash-reporting services.
- Update checks: the app uses Sparkle to check for updates once a day, and when you choose Check for Updates…. Each check downloads the update feed from GitHub, which receives your IP address and the app's name and version, as with any download. Sparkle's optional system profile is turned off, so no hardware or system details are sent. Updates are downloaded from GitHub Releases and installed only if they carry the developer's update signature and a valid Apple code signature. You can turn automatic checks off in Settings › About. Only stable releases are offered.
- Your choices on the Mac: Settings › Data signs you out or clears local data (the old data is moved aside, not deleted). Deleting the app, the two folders above and any `Conduit (reset …)` folders a clear left beside them removes Conduit's data from your Mac; the Keychain item can be removed in Keychain Access.

## Children’s Privacy
Conduit is not directed to children under 13 (or the minimum age required in your jurisdiction). Do not use the app if you do not meet the applicable age requirements.

## Changes to This Policy
We may update this policy to reflect improvements or legal requirements. Material changes will be reflected in the app bundle and version notes.

## Contact
For questions or requests about this policy, please contact the app maintainer(s) through the project repository.
