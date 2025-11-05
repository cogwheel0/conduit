import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_it.dart';
import 'app_localizations_kr.dart';
import 'app_localizations_nl.dart';
import 'app_localizations_ru.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('de'),
    Locale('fr'),
    Locale('it'),
    Locale('zh'),
    Locale('ru'),
    Locale('nl'),
    Locale('es'),
    Locale('kr'),
  ];

  /// Application name displayed in the app and OS UI.
  ///
  /// In en, this message translates to:
  /// **'Conduit'**
  String get appTitle;

  /// Button label to try an action again.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// Back navigation label/tooltip.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// Profile tab title.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// Progress message while fetching profile data.
  ///
  /// In en, this message translates to:
  /// **'Loading profile...'**
  String get loadingProfile;

  /// Error title shown when profile request fails.
  ///
  /// In en, this message translates to:
  /// **'Unable to load profile'**
  String get unableToLoadProfile;

  /// Generic connectivity hint after an error.
  ///
  /// In en, this message translates to:
  /// **'Please check your connection and try again'**
  String get pleaseCheckConnection;

  /// Title shown when the configured server is unreachable
  ///
  /// In en, this message translates to:
  /// **'Can\'t reach your server'**
  String get connectionIssueTitle;

  /// Subtitle explaining available actions when the server cannot be reached
  ///
  /// In en, this message translates to:
  /// **'Reconnect to continue or sign out to choose a different server.'**
  String get connectionIssueSubtitle;

  /// Title shown when the app takes too long to connect
  ///
  /// In en, this message translates to:
  /// **'Connection Timeout'**
  String get connectionTimeout;

  /// Message explaining why the connection is taking longer than expected
  ///
  /// In en, this message translates to:
  /// **'The app is taking longer than expected to connect. This might be due to a slow connection or server timeout.'**
  String get connectionTimeoutMessage;

  /// Section header for account-related options.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// Section header inviting the user to financially support the project.
  ///
  /// In en, this message translates to:
  /// **'Support Conduit'**
  String get supportConduit;

  /// Subtitle explaining why donations are helpful.
  ///
  /// In en, this message translates to:
  /// **'Keep Conduit independent by funding ongoing development.'**
  String get supportConduitSubtitle;

  /// Tile title linking to the GitHub Sponsors page.
  ///
  /// In en, this message translates to:
  /// **'GitHub Sponsors'**
  String get githubSponsorsTitle;

  /// Subtitle explaining the impact of recurring sponsorship.
  ///
  /// In en, this message translates to:
  /// **'Become a recurring sponsor to fund roadmap items.'**
  String get githubSponsorsSubtitle;

  /// Tile title linking to the Buy Me a Coffee page.
  ///
  /// In en, this message translates to:
  /// **'Buy Me a Coffee'**
  String get buyMeACoffeeTitle;

  /// Subtitle encouraging one-time donations via Buy Me a Coffee.
  ///
  /// In en, this message translates to:
  /// **'Make a one-time donation to say thanks.'**
  String get buyMeACoffeeSubtitle;

  /// Button/title for signing out of the app.
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get signOut;

  /// Subtitle explaining the sign-out action.
  ///
  /// In en, this message translates to:
  /// **'End your session'**
  String get endYourSession;

  /// Label for choosing a default AI model.
  ///
  /// In en, this message translates to:
  /// **'Default Model'**
  String get defaultModel;

  /// Option to let the app pick a suitable model automatically.
  ///
  /// In en, this message translates to:
  /// **'Auto-select'**
  String get autoSelect;

  /// Progress message while fetching model list.
  ///
  /// In en, this message translates to:
  /// **'Loading models...'**
  String get loadingModels;

  /// Error message shown when model list cannot be retrieved.
  ///
  /// In en, this message translates to:
  /// **'Failed to load models'**
  String get failedToLoadModels;

  /// Header above a list of models to select from.
  ///
  /// In en, this message translates to:
  /// **'Available Models'**
  String get availableModels;

  /// Capability chip label for models that support multimodal input.
  ///
  /// In en, this message translates to:
  /// **'Multimodal'**
  String get modelCapabilityMultimodal;

  /// Capability chip label for models that support reasoning features.
  ///
  /// In en, this message translates to:
  /// **'Reasoning'**
  String get modelCapabilityReasoning;

  /// Shown when a search returns no matches.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// Hint text for model search input.
  ///
  /// In en, this message translates to:
  /// **'Search models...'**
  String get searchModels;

  /// Generic error message for unexpected failures.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get errorMessage;

  /// Accessible label for a generic Close button.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeButtonSemantic;

  /// Shown while loading page content.
  ///
  /// In en, this message translates to:
  /// **'Loading content'**
  String get loadingContent;

  /// Short loading label used for accessibility.
  ///
  /// In en, this message translates to:
  /// **'Loading'**
  String get loadingShort;

  /// Screen reader announcement when loading a resource.
  ///
  /// In en, this message translates to:
  /// **'Loading: {message}'**
  String loadingAnnouncement(String message);

  /// Screen reader announcement for an error.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}'**
  String errorAnnouncement(String error);

  /// Screen reader announcement for an error with a follow-up suggestion.
  ///
  /// In en, this message translates to:
  /// **'Error: {error}. {suggestion}'**
  String errorAnnouncementWithSuggestion(String error, String suggestion);

  /// Screen reader announcement for successful actions.
  ///
  /// In en, this message translates to:
  /// **'Success: {message}'**
  String successAnnouncement(String message);

  /// Placeholder text when a list is empty.
  ///
  /// In en, this message translates to:
  /// **'No items'**
  String get noItems;

  /// Alternative empty-state description.
  ///
  /// In en, this message translates to:
  /// **'No items to display'**
  String get noItemsToDisplay;

  /// Section for knowledge base content.
  ///
  /// In en, this message translates to:
  /// **'Knowledge Base'**
  String get knowledgeBase;

  /// Header above list of attached files in compose area.
  ///
  /// In en, this message translates to:
  /// **'Attachments'**
  String get attachments;

  /// Action to open camera and capture a new photo.
  ///
  /// In en, this message translates to:
  /// **'Take a photo'**
  String get takePhoto;

  /// Generic document label used in UI.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get document;

  /// Button/back label to return to server configuration flow.
  ///
  /// In en, this message translates to:
  /// **'Back to server setup'**
  String get backToServerSetup;

  /// Status label indicating a successful server connection.
  ///
  /// In en, this message translates to:
  /// **'Connected to Server'**
  String get connectedToServer;

  /// Button/heading for sign-in flows.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get signIn;

  /// Instructional text on the sign-in screen.
  ///
  /// In en, this message translates to:
  /// **'Enter your credentials to access your AI conversations'**
  String get enterCredentials;

  /// Header for credential input section.
  ///
  /// In en, this message translates to:
  /// **'Credentials'**
  String get credentials;

  /// Label for API key input field.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKey;

  /// Label for username/email input field.
  ///
  /// In en, this message translates to:
  /// **'Username or Email'**
  String get usernameOrEmail;

  /// Label for password input field.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// Alternative sign-in method using an API key.
  ///
  /// In en, this message translates to:
  /// **'Sign in with API Key'**
  String get signInWithApiKey;

  /// Call-to-action button for server connection.
  ///
  /// In en, this message translates to:
  /// **'Connect to Server'**
  String get connectToServer;

  /// Instruction telling user to provide server URL to begin.
  ///
  /// In en, this message translates to:
  /// **'Enter your Open-WebUI server address to get started'**
  String get enterServerAddress;

  /// Label for server URL field.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get serverUrl;

  /// Hint text showing example server URL format.
  ///
  /// In en, this message translates to:
  /// **'https://your-server.com'**
  String get serverUrlHint;

  /// Semantic/ARIA label instructing to enter server URL or IP.
  ///
  /// In en, this message translates to:
  /// **'Enter your server URL or IP address'**
  String get enterServerUrlSemantic;

  /// Label for custom header key.
  ///
  /// In en, this message translates to:
  /// **'Header Name'**
  String get headerName;

  /// Label for custom header value.
  ///
  /// In en, this message translates to:
  /// **'Header Value'**
  String get headerValue;

  /// Hint text with example header values, including API key or Bearer token.
  ///
  /// In en, this message translates to:
  /// **'api-key-123 or Bearer token'**
  String get headerValueHint;

  /// Button to add a new custom header row.
  ///
  /// In en, this message translates to:
  /// **'Add header'**
  String get addHeader;

  /// Warning when custom header limit is reached.
  ///
  /// In en, this message translates to:
  /// **'Maximum headers reached'**
  String get maximumHeadersReached;

  /// Action to remove a custom header row.
  ///
  /// In en, this message translates to:
  /// **'Remove header'**
  String get removeHeader;

  /// Status while attempting to connect to server.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get connecting;

  /// Primary action button to initiate server connection.
  ///
  /// In en, this message translates to:
  /// **'Connect to Server'**
  String get connectToServerButton;

  /// Banner/text indicating the app runs in demo mode.
  ///
  /// In en, this message translates to:
  /// **'Demo Mode Active'**
  String get demoModeActive;

  /// CTA to bypass server configuration and enter demo mode.
  ///
  /// In en, this message translates to:
  /// **'Skip server setup and try the demo'**
  String get skipServerSetupTryDemo;

  /// Button to enter demo mode.
  ///
  /// In en, this message translates to:
  /// **'Enter Demo'**
  String get enterDemo;

  /// Small badge label for demo content.
  ///
  /// In en, this message translates to:
  /// **'Demo'**
  String get demoBadge;

  /// Validation error when the server does not resemble Open-WebUI.
  ///
  /// In en, this message translates to:
  /// **'This does not appear to be an Open-WebUI server.'**
  String get serverNotOpenWebUI;

  /// Validation message for empty server URL.
  ///
  /// In en, this message translates to:
  /// **'Server URL cannot be empty'**
  String get serverUrlEmpty;

  /// Validation message when URL format is incorrect.
  ///
  /// In en, this message translates to:
  /// **'Invalid URL format. Please check your input.'**
  String get invalidUrlFormat;

  /// Validation note restricting protocols to HTTP/HTTPS.
  ///
  /// In en, this message translates to:
  /// **'Only HTTP and HTTPS protocols are supported.'**
  String get onlyHttpHttps;

  /// Validation hint providing examples for server addresses.
  ///
  /// In en, this message translates to:
  /// **'Server address is required (e.g., 192.168.1.10 or example.com).'**
  String get serverAddressRequired;

  /// Validation message for allowed port range.
  ///
  /// In en, this message translates to:
  /// **'Port must be between 1 and 65535.'**
  String get portRange;

  /// Validation message for IP addresses with example.
  ///
  /// In en, this message translates to:
  /// **'Invalid IP address format. Use format like 192.168.1.10.'**
  String get invalidIpFormat;

  /// Generic failure when connecting to the server.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t connect. Double-check the address and try again.'**
  String get couldNotConnectGeneric;

  /// Connectivity error with hints to verify server status.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t reach the server. Check your connection and that the server is running.'**
  String get weCouldntReachServer;

  /// Timeout error while connecting to server.
  ///
  /// In en, this message translates to:
  /// **'Connection timed out. The server might be busy or blocked by a firewall.'**
  String get connectionTimedOut;

  /// Note instructing the user to include protocol in URL.
  ///
  /// In en, this message translates to:
  /// **'Use http:// or https:// only.'**
  String get useHttpOrHttpsOnly;

  /// Title for failed login attempts.
  ///
  /// In en, this message translates to:
  /// **'Login failed'**
  String get loginFailed;

  /// Detailed message when authentication fails.
  ///
  /// In en, this message translates to:
  /// **'Invalid username or password. Please try again.'**
  String get invalidCredentials;

  /// Warning about HTTP→HTTPS redirect issues.
  ///
  /// In en, this message translates to:
  /// **'The server is redirecting requests. Check your server\'s HTTPS configuration.'**
  String get serverRedirectingHttps;

  /// Generic server connection failure message.
  ///
  /// In en, this message translates to:
  /// **'Unable to connect to server. Please check your connection.'**
  String get unableToConnectServer;

  /// Timeout while waiting for a server response.
  ///
  /// In en, this message translates to:
  /// **'The request timed out. Please try again.'**
  String get requestTimedOut;

  /// Fallback sign-in error when no specific cause is known.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t sign you in. Check your credentials and server settings.'**
  String get genericSignInFailed;

  /// Onboarding: skip current step.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// Onboarding: go to the next step.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// Onboarding: finish the flow.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// Onboarding card: start chatting title.
  ///
  /// In en, this message translates to:
  /// **'Hello, {username}'**
  String onboardStartTitle(String username);

  /// Onboarding card: brief guidance to begin a chat.
  ///
  /// In en, this message translates to:
  /// **'Choose a model to get started. Tap New Chat anytime.'**
  String get onboardStartSubtitle;

  /// Bullet: how to switch models.
  ///
  /// In en, this message translates to:
  /// **'Tap the model name in the top bar to switch models'**
  String get onboardStartBullet1;

  /// Bullet: how to reset context.
  ///
  /// In en, this message translates to:
  /// **'Use New Chat to reset context'**
  String get onboardStartBullet2;

  /// Onboarding card: attach context title.
  ///
  /// In en, this message translates to:
  /// **'Add context'**
  String get onboardAttachTitle;

  /// Onboarding card: why attaching context helps.
  ///
  /// In en, this message translates to:
  /// **'Ground replies with content from Workspace or photos.'**
  String get onboardAttachSubtitle;

  /// Bullet: types of workspace files.
  ///
  /// In en, this message translates to:
  /// **'Workspace: PDFs, docs, datasets'**
  String get onboardAttachBullet1;

  /// Bullet: photo sources supported.
  ///
  /// In en, this message translates to:
  /// **'Photos: camera or library'**
  String get onboardAttachBullet2;

  /// Onboarding card: voice input title.
  ///
  /// In en, this message translates to:
  /// **'Speak naturally'**
  String get onboardSpeakTitle;

  /// Onboarding card: how voice input works.
  ///
  /// In en, this message translates to:
  /// **'Tap the mic to dictate with live waveform feedback.'**
  String get onboardSpeakSubtitle;

  /// Bullet: stop dictation preserves text.
  ///
  /// In en, this message translates to:
  /// **'Stop anytime; partial text is preserved'**
  String get onboardSpeakBullet1;

  /// Bullet: benefits of voice input.
  ///
  /// In en, this message translates to:
  /// **'Great for quick notes or long prompts'**
  String get onboardSpeakBullet2;

  /// Onboarding card: quick actions title.
  ///
  /// In en, this message translates to:
  /// **'Quick actions'**
  String get onboardQuickTitle;

  /// Onboarding card: how to use the app menu.
  ///
  /// In en, this message translates to:
  /// **'Open the menu to switch between Chats, Workspace, and Profile.'**
  String get onboardQuickSubtitle;

  /// Bullet: menu access to sections.
  ///
  /// In en, this message translates to:
  /// **'Tap the menu to access Chats, Workspace, Profile'**
  String get onboardQuickBullet1;

  /// Bullet: actions available in the top bar.
  ///
  /// In en, this message translates to:
  /// **'Start New Chat or manage models from the top bar'**
  String get onboardQuickBullet2;

  /// Label shown beside attachment chips in messages.
  ///
  /// In en, this message translates to:
  /// **'Attachment'**
  String get attachmentLabel;

  /// Header for a tools/actions section.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get tools;

  /// Label for voice input feature.
  ///
  /// In en, this message translates to:
  /// **'Voice input'**
  String get voiceInput;

  /// Title for the voice input bottom sheet.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get voice;

  /// Indicates the app is actively listening during voice input.
  ///
  /// In en, this message translates to:
  /// **'Listening…'**
  String get voiceStatusListening;

  /// Indicates the app is recording audio for speech recognition.
  ///
  /// In en, this message translates to:
  /// **'Recording…'**
  String get voiceStatusRecording;

  /// Toggle label for hold-to-talk mode in voice input.
  ///
  /// In en, this message translates to:
  /// **'Hold to talk'**
  String get voiceHoldToTalk;

  /// Toggle label for automatically sending the final transcript.
  ///
  /// In en, this message translates to:
  /// **'Auto-send'**
  String get voiceAutoSend;

  /// Label above the transcribed voice input text.
  ///
  /// In en, this message translates to:
  /// **'Transcript'**
  String get voiceTranscript;

  /// Placeholder prompting the user to start speaking.
  ///
  /// In en, this message translates to:
  /// **'Speak now…'**
  String get voicePromptSpeakNow;

  /// Placeholder instructing the user to tap Start to begin recording.
  ///
  /// In en, this message translates to:
  /// **'Tap Start to begin'**
  String get voicePromptTapStart;

  /// Button label to stop voice recording.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get voiceActionStop;

  /// Button label to start voice recording.
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get voiceActionStart;

  /// Title displayed on the voice call screen.
  ///
  /// In en, this message translates to:
  /// **'Voice Call'**
  String get voiceCallTitle;

  /// Button label to pause a voice call.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get voiceCallPause;

  /// Button label to resume a paused voice call.
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get voiceCallResume;

  /// Button label to stop the active voice call.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get voiceCallStop;

  /// Button label to end the voice call session.
  ///
  /// In en, this message translates to:
  /// **'End Call'**
  String get voiceCallEnd;

  /// Status label shown when the voice call is ready to start.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get voiceCallReady;

  /// Status label shown while the voice call is connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get voiceCallConnecting;

  /// Status label shown while the call is listening for input.
  ///
  /// In en, this message translates to:
  /// **'Listening'**
  String get voiceCallListening;

  /// Status label shown when the call is paused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get voiceCallPaused;

  /// Status label shown while the call processes a response.
  ///
  /// In en, this message translates to:
  /// **'Thinking...'**
  String get voiceCallProcessing;

  /// Status label shown while the assistant is speaking.
  ///
  /// In en, this message translates to:
  /// **'Speaking'**
  String get voiceCallSpeaking;

  /// Status label shown when the voice call has ended or disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get voiceCallDisconnected;

  /// Guidance shown when the voice call encounters an error.
  ///
  /// In en, this message translates to:
  /// **'Please check:\n• Microphone permissions are granted\n• Speech recognition is available on your device\n• You are connected to the server'**
  String get voiceCallErrorHelp;

  /// Accessibility label for the message input.
  ///
  /// In en, this message translates to:
  /// **'Message input'**
  String get messageInputLabel;

  /// Hint shown in the message input field.
  ///
  /// In en, this message translates to:
  /// **'Type your message'**
  String get messageInputHint;

  /// Short placeholder text in the message input.
  ///
  /// In en, this message translates to:
  /// **'Ask Conduit'**
  String get messageHintText;

  /// Action to stop the assistant's response generation.
  ///
  /// In en, this message translates to:
  /// **'Stop generating'**
  String get stopGenerating;

  /// Primary action to send a message.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// Snack bar message confirming code was copied.
  ///
  /// In en, this message translates to:
  /// **'Code copied to clipboard.'**
  String get codeCopiedToClipboard;

  /// Semantic label for sending a message.
  ///
  /// In en, this message translates to:
  /// **'Send message'**
  String get sendMessage;

  /// A file item or attachment type label.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// Action label prompting the user to pick another file.
  ///
  /// In en, this message translates to:
  /// **'Choose Different File'**
  String get chooseDifferentFile;

  /// A photo item or attachment type label.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get photo;

  /// Camera source label.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get camera;

  /// Shown when backend API service is unavailable.
  ///
  /// In en, this message translates to:
  /// **'API service not available'**
  String get apiUnavailable;

  /// General failure to load an image.
  ///
  /// In en, this message translates to:
  /// **'Unable to load image'**
  String get unableToLoadImage;

  /// Error when a referenced file is not an image.
  ///
  /// In en, this message translates to:
  /// **'Not an image file: {fileName}'**
  String notAnImageFile(String fileName);

  /// Error including the underlying reason when image loading fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to load image: {error}'**
  String failedToLoadImage(String error);

  /// Error for malformed data: URLs.
  ///
  /// In en, this message translates to:
  /// **'Invalid data URL format'**
  String get invalidDataUrl;

  /// Error when decoding image bytes/base64.
  ///
  /// In en, this message translates to:
  /// **'Failed to decode image'**
  String get failedToDecodeImage;

  /// Error when image type/format is not supported.
  ///
  /// In en, this message translates to:
  /// **'Invalid image format'**
  String get invalidImageFormat;

  /// Error when image data buffer is empty.
  ///
  /// In en, this message translates to:
  /// **'Empty image data'**
  String get emptyImageData;

  /// Confirmation button label.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// Button label to continue an action or flow.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueAction;

  /// Cancel button label.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// Generic OK button label.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// Label for navigating to the previous item.
  ///
  /// In en, this message translates to:
  /// **'Prev'**
  String get previousLabel;

  /// Label for navigating to the next item.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get nextLabel;

  /// Accessibility label describing an input field.
  ///
  /// In en, this message translates to:
  /// **'Input field'**
  String get inputField;

  /// CTA to verify network connectivity.
  ///
  /// In en, this message translates to:
  /// **'Check Connection'**
  String get checkConnection;

  /// CTA to open device or app settings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get openSettings;

  /// CTA to navigate back.
  ///
  /// In en, this message translates to:
  /// **'Go Back'**
  String get goBack;

  /// Expandable section label to show error details or logs.
  ///
  /// In en, this message translates to:
  /// **'Technical Details'**
  String get technicalDetails;

  /// Label text indicating a required field.
  ///
  /// In en, this message translates to:
  /// **'{label} *'**
  String requiredFieldLabel(String label);

  /// Helper text indicating that the field is required.
  ///
  /// In en, this message translates to:
  /// **'Required field'**
  String get requiredFieldHelper;

  /// Semantic label when a switch is enabled.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get switchOnLabel;

  /// Semantic label when a switch is disabled.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get switchOffLabel;

  /// Semantic label describing the dialog title.
  ///
  /// In en, this message translates to:
  /// **'Dialog: {title}'**
  String dialogSemanticLabel(String title);

  /// Primary action to save changes.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Button/label to choose a model.
  ///
  /// In en, this message translates to:
  /// **'Choose Model'**
  String get chooseModel;

  /// Developer/reviewer mode indicator.
  ///
  /// In en, this message translates to:
  /// **'REVIEWER MODE'**
  String get reviewerMode;

  /// Dialog title to pick application language.
  ///
  /// In en, this message translates to:
  /// **'Select Language'**
  String get selectLanguage;

  /// Action to create a new folder.
  ///
  /// In en, this message translates to:
  /// **'New Folder'**
  String get newFolder;

  /// Label for entering a folder's name.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get folderName;

  /// Action to start a new chat.
  ///
  /// In en, this message translates to:
  /// **'New Chat'**
  String get newChat;

  /// Opens additional actions or content.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get more;

  /// Action to clear input or selection.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// Search input hint scoped to conversations.
  ///
  /// In en, this message translates to:
  /// **'Search conversations...'**
  String get searchConversations;

  /// Primary action to create a resource.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// Error notice when folder creation fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to create folder'**
  String get failedToCreateFolder;

  /// Error notice when moving a chat fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to move chat'**
  String get failedToMoveChat;

  /// Error notice when fetching chat list fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to load chats'**
  String get failedToLoadChats;

  /// Error notice when updating pin star/flag fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to update pin'**
  String get failedToUpdatePin;

  /// Error notice when deleting a chat fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete chat'**
  String get failedToDeleteChat;

  /// Context action to manage an item.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get manage;

  /// Context action to rename an item.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// Context action to delete an item.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// Dialog title to rename a chat.
  ///
  /// In en, this message translates to:
  /// **'Rename Chat'**
  String get renameChat;

  /// Input hint/label for new chat name.
  ///
  /// In en, this message translates to:
  /// **'Enter chat name'**
  String get enterChatName;

  /// Error notice when renaming chat fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to rename chat'**
  String get failedToRenameChat;

  /// Error notice when archiving/unarchiving fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to update archive'**
  String get failedToUpdateArchive;

  /// Action to unarchive an item.
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get unarchive;

  /// Action to archive an item.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get archive;

  /// Action to pin/star an item.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get pin;

  /// Action to remove pin from an item.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get unpin;

  /// List filter for recently used items.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get recent;

  /// Option indicating the device/system default.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// Language name: English.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// Language name: German.
  ///
  /// In en, this message translates to:
  /// **'Deutsch'**
  String get deutsch;

  /// Language name: French.
  ///
  /// In en, this message translates to:
  /// **'Français'**
  String get francais;

  /// Language name: Italian.
  ///
  /// In en, this message translates to:
  /// **'Italiano'**
  String get italiano;

  /// Language name: Spanish.
  ///
  /// In en, this message translates to:
  /// **'Español'**
  String get espanol;

  /// Language name: Dutch.
  ///
  /// In en, this message translates to:
  /// **'Nederlands'**
  String get nederlands;

  /// Language name: Russian.
  ///
  /// In en, this message translates to:
  /// **'Русский'**
  String get russian;

  /// Language name: Chinese.
  ///
  /// In en, this message translates to:
  /// **'中文'**
  String get chinese;

  /// Language name: Korean.
  ///
  /// In en, this message translates to:
  /// **'한국어'**
  String get korean;

  /// Dialog title asking to confirm deletion of messages.
  ///
  /// In en, this message translates to:
  /// **'Delete Messages'**
  String get deleteMessagesTitle;

  /// Confirmation prompt asking to delete a number of messages.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} messages?'**
  String deleteMessagesMessage(int count);

  /// Displayed when navigation fails to find a route name.
  ///
  /// In en, this message translates to:
  /// **'Route not found: {routeName}'**
  String routeNotFound(String routeName);

  /// Dialog title asking to confirm deletion of a chat.
  ///
  /// In en, this message translates to:
  /// **'Delete Chat'**
  String get deleteChatTitle;

  /// Warning that deleting a chat cannot be undone.
  ///
  /// In en, this message translates to:
  /// **'This chat will be permanently deleted.'**
  String get deleteChatMessage;

  /// Dialog title asking to confirm deletion of a folder.
  ///
  /// In en, this message translates to:
  /// **'Delete Folder'**
  String get deleteFolderTitle;

  /// Warning that deleting a folder will remove it and its associations.
  ///
  /// In en, this message translates to:
  /// **'This folder and its assignment references will be removed.'**
  String get deleteFolderMessage;

  /// Error notice when deleting a folder fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete folder'**
  String get failedToDeleteFolder;

  /// Settings tile title to view app information.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get aboutApp;

  /// Subtitle/description for the About section.
  ///
  /// In en, this message translates to:
  /// **'Conduit information and links'**
  String get aboutAppSubtitle;

  /// Tab/section label for web features.
  ///
  /// In en, this message translates to:
  /// **'Web'**
  String get web;

  /// Short label for image generation section/tab.
  ///
  /// In en, this message translates to:
  /// **'Image Gen'**
  String get imageGen;

  /// Filter/tab for pinned items.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinned;

  /// Tab listing chat folders.
  ///
  /// In en, this message translates to:
  /// **'Folders'**
  String get folders;

  /// Filter/tab for archived chats.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get archived;

  /// Label for choosing the app's display language.
  ///
  /// In en, this message translates to:
  /// **'App Language'**
  String get appLanguage;

  /// Label for toggling dark theme.
  ///
  /// In en, this message translates to:
  /// **'Dark Mode'**
  String get darkMode;

  /// Feature toggle/section for web search.
  ///
  /// In en, this message translates to:
  /// **'Web Search'**
  String get webSearch;

  /// Explains that responses can include citations from the web.
  ///
  /// In en, this message translates to:
  /// **'Search the web and cite sources in replies.'**
  String get webSearchDescription;

  /// Feature toggle/section for image generation.
  ///
  /// In en, this message translates to:
  /// **'Image Generation'**
  String get imageGeneration;

  /// Explains creating images via model prompts.
  ///
  /// In en, this message translates to:
  /// **'Create images from your prompts.'**
  String get imageGenerationDescription;

  /// Action to copy text to clipboard.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// Action to play the assistant message using text to speech
  ///
  /// In en, this message translates to:
  /// **'Listen'**
  String get ttsListen;

  /// Action to stop text to speech playback
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get ttsStop;

  /// Action to edit an item/message.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// Action to request a new assistant response.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get regenerate;

  /// Empty state when the user has no chats.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get noConversationsYet;

  /// Hint text for username/email input.
  ///
  /// In en, this message translates to:
  /// **'Enter your username or email'**
  String get usernameOrEmailHint;

  /// Hint text for password input.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get passwordHint;

  /// Hint text for API key input.
  ///
  /// In en, this message translates to:
  /// **'Enter your API key'**
  String get enterApiKey;

  /// Status message shown while signing in.
  ///
  /// In en, this message translates to:
  /// **'Signing in...'**
  String get signingIn;

  /// Section that contains additional/optional configuration.
  ///
  /// In en, this message translates to:
  /// **'Advanced Settings'**
  String get advancedSettings;

  /// Section title for adding custom HTTP headers.
  ///
  /// In en, this message translates to:
  /// **'Custom Headers'**
  String get customHeaders;

  /// Helper text explaining use-cases for custom headers.
  ///
  /// In en, this message translates to:
  /// **'Add custom HTTP headers for authentication, API keys, or special server requirements.'**
  String get customHeadersDescription;

  /// Toggle label that allows trusting self-signed TLS certificates for the configured server.
  ///
  /// In en, this message translates to:
  /// **'Trust self-signed certificates'**
  String get allowSelfSignedCertificates;

  /// Helper text clarifying the risks of enabling the self-signed certificate toggle.
  ///
  /// In en, this message translates to:
  /// **'Accept this server\'s TLS certificate even if it is self-signed. Enable only for servers you trust.'**
  String get allowSelfSignedCertificatesDescription;

  /// Validation message for empty header name.
  ///
  /// In en, this message translates to:
  /// **'Header name cannot be empty'**
  String get headerNameEmpty;

  /// Validation message for header name length.
  ///
  /// In en, this message translates to:
  /// **'Header name too long (max 64 characters)'**
  String get headerNameTooLong;

  /// Validation message for invalid characters in header name.
  ///
  /// In en, this message translates to:
  /// **'Invalid header name. Use only letters, numbers, and these symbols: !#\$&-^_`|~'**
  String get headerNameInvalidChars;

  /// Error when attempting to override a reserved HTTP header {key}.
  ///
  /// In en, this message translates to:
  /// **'Cannot override reserved header \"{key}\"'**
  String headerNameReserved(String key);

  /// Validation message for empty header value.
  ///
  /// In en, this message translates to:
  /// **'Header value cannot be empty'**
  String get headerValueEmpty;

  /// Validation message for header value length.
  ///
  /// In en, this message translates to:
  /// **'Header value too long (max 1024 characters)'**
  String get headerValueTooLong;

  /// Validation message for invalid characters in header value.
  ///
  /// In en, this message translates to:
  /// **'Header value contains invalid characters. Use only printable ASCII.'**
  String get headerValueInvalidChars;

  /// Security warning for suspicious header values.
  ///
  /// In en, this message translates to:
  /// **'Header value appears to contain potentially unsafe content'**
  String get headerValueUnsafe;

  /// Error when a custom header with key {key} already exists.
  ///
  /// In en, this message translates to:
  /// **'Header \"{key}\" already exists. Remove it first to update.'**
  String headerAlreadyExists(String key);

  /// Explains the upper limit of custom headers.
  ///
  /// In en, this message translates to:
  /// **'Maximum of 10 custom headers allowed. Remove some to add more.'**
  String get maxHeadersReachedDetail;

  /// Shown when model list is empty or failed to load.
  ///
  /// In en, this message translates to:
  /// **'No models available'**
  String get noModelsAvailable;

  /// Indicates the app is following the system theme ("Dark"/"Light").
  ///
  /// In en, this message translates to:
  /// **'Following system: {theme}'**
  String followingSystem(String theme);

  /// Theme label for dark appearance.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// Title for selecting the app color palette.
  ///
  /// In en, this message translates to:
  /// **'Accent palette'**
  String get themePalette;

  /// Palette name for the default Conduit theme.
  ///
  /// In en, this message translates to:
  /// **'Conduit'**
  String get themePaletteConduitLabel;

  /// Description of the Conduit palette.
  ///
  /// In en, this message translates to:
  /// **'Clean neutral theme designed for Conduit.'**
  String get themePaletteConduitDescription;

  /// Palette name inspired by the Claude web client.
  ///
  /// In en, this message translates to:
  /// **'Claude'**
  String get themePaletteClaudeLabel;

  /// Description of the Claude palette.
  ///
  /// In en, this message translates to:
  /// **'Warm, tactile palette lifted from the Claude web client.'**
  String get themePaletteClaudeDescription;

  /// Palette name inspired by the T3 Stack brand.
  ///
  /// In en, this message translates to:
  /// **'T3 Chat'**
  String get themePaletteT3ChatLabel;

  /// Description of the T3 Chat palette.
  ///
  /// In en, this message translates to:
  /// **'Playful gradients inspired by the T3 Stack brand.'**
  String get themePaletteT3ChatDescription;

  /// Palette name for Catppuccin colors.
  ///
  /// In en, this message translates to:
  /// **'Catppuccin'**
  String get themePaletteCatppuccinLabel;

  /// Description of the Catppuccin palette.
  ///
  /// In en, this message translates to:
  /// **'Soft pastel palette.'**
  String get themePaletteCatppuccinDescription;

  /// Palette name for Tangerine colors.
  ///
  /// In en, this message translates to:
  /// **'Tangerine'**
  String get themePaletteTangerineLabel;

  /// Description of the Tangerine palette.
  ///
  /// In en, this message translates to:
  /// **'Warm orange-and-slate palette.'**
  String get themePaletteTangerineDescription;

  /// Theme label for light appearance.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// Status text indicating dark theme is active.
  ///
  /// In en, this message translates to:
  /// **'Currently using Dark theme'**
  String get currentlyUsingDarkTheme;

  /// Status text indicating light theme is active.
  ///
  /// In en, this message translates to:
  /// **'Currently using Light theme'**
  String get currentlyUsingLightTheme;

  /// Dialog title for app information.
  ///
  /// In en, this message translates to:
  /// **'About Conduit'**
  String get aboutConduit;

  /// Displays version and build number in the About dialog.
  ///
  /// In en, this message translates to:
  /// **'Version: {version} ({build})'**
  String versionLabel(String version, String build);

  /// Link label pointing to the app repository.
  ///
  /// In en, this message translates to:
  /// **'GitHub Repository'**
  String get githubRepository;

  /// Error text when package info cannot be retrieved.
  ///
  /// In en, this message translates to:
  /// **'Unable to load app info'**
  String get unableToLoadAppInfo;

  /// Label shown while the assistant is reasoning.
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get thinking;

  /// Section title for showing reasoning content.
  ///
  /// In en, this message translates to:
  /// **'Thoughts'**
  String get thoughts;

  /// Shows how long the assistant thought before replying.
  ///
  /// In en, this message translates to:
  /// **'Thought for {duration}'**
  String thoughtForDuration(String duration);

  /// Title of the customization settings page.
  ///
  /// In en, this message translates to:
  /// **'Customization'**
  String get appCustomization;

  /// Subtitle shown under App Customization tile and page header.
  ///
  /// In en, this message translates to:
  /// **'Theme, language, voice, and quickpills'**
  String get appCustomizationSubtitle;

  /// Helper text explaining quick action pill selection in customization.
  ///
  /// In en, this message translates to:
  /// **'Quickpills in chat'**
  String get quickActionsDescription;

  /// Subtitle indicating how many quick actions are selected.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No actions selected} one{1 action selected} other{{count} actions selected}}'**
  String quickActionsSelectedCount(int count);

  /// Explains what the auto-select model setting does.
  ///
  /// In en, this message translates to:
  /// **'Let the app choose the best model'**
  String get autoSelectDescription;

  /// Section header for chat-related customization options.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get chatSettings;

  /// Toggle title for sending messages when pressing Enter.
  ///
  /// In en, this message translates to:
  /// **'Send on Enter'**
  String get sendOnEnter;

  /// Explanation of how the Send on Enter toggle behaves.
  ///
  /// In en, this message translates to:
  /// **'Enter sends (soft keyboard). Cmd/Ctrl+Enter also available'**
  String get sendOnEnterDescription;

  /// Section header for speech-to-text settings.
  ///
  /// In en, this message translates to:
  /// **'Speech to Text'**
  String get sttSettings;

  /// Label shown above the speech-to-text engine chips.
  ///
  /// In en, this message translates to:
  /// **'Recognition engine'**
  String get sttEngineLabel;

  /// Chip label for automatic speech-to-text selection.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get sttEngineAuto;

  /// Chip label for on-device speech recognition.
  ///
  /// In en, this message translates to:
  /// **'On device'**
  String get sttEngineDevice;

  /// Chip label for server speech recognition.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get sttEngineServer;

  /// Description shown when automatic speech-to-text preference is active.
  ///
  /// In en, this message translates to:
  /// **'Use on-device recognition when available and fall back to your server.'**
  String get sttEngineAutoDescription;

  /// Description shown when on-device speech-to-text preference is active.
  ///
  /// In en, this message translates to:
  /// **'Keep audio on this device. Voice input stops working if on-device speech recognition isn’t supported.'**
  String get sttEngineDeviceDescription;

  /// Description shown when server speech-to-text preference is active.
  ///
  /// In en, this message translates to:
  /// **'Always send recordings to your OpenWebUI server for transcription.'**
  String get sttEngineServerDescription;

  /// Warning shown when the user selects on-device speech recognition but it is unavailable.
  ///
  /// In en, this message translates to:
  /// **'On-device speech recognition isn’t available on this device.'**
  String get sttDeviceUnavailableWarning;

  /// Warning shown when the user selects server speech recognition but no server is available.
  ///
  /// In en, this message translates to:
  /// **'Connect to a server with transcription enabled to use this option.'**
  String get sttServerUnavailableWarning;

  /// Label for the silence duration setting in server speech-to-text.
  ///
  /// In en, this message translates to:
  /// **'Silence Duration'**
  String get sttSilenceDuration;

  /// Description for the silence duration slider in server speech-to-text settings.
  ///
  /// In en, this message translates to:
  /// **'Time to wait after silence before auto-stopping recording'**
  String get sttSilenceDurationDescription;

  /// Label for selecting the text-to-speech engine.
  ///
  /// In en, this message translates to:
  /// **'Engine'**
  String get ttsEngineLabel;

  /// Chip label for automatically selecting the text-to-speech engine.
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get ttsEngineAuto;

  /// Chip label for using on-device text-to-speech.
  ///
  /// In en, this message translates to:
  /// **'On device'**
  String get ttsEngineDevice;

  /// Chip label for using server-side text-to-speech.
  ///
  /// In en, this message translates to:
  /// **'Server'**
  String get ttsEngineServer;

  /// Description shown when automatic text-to-speech preference is active.
  ///
  /// In en, this message translates to:
  /// **'Use on-device speech when available and fall back to your server.'**
  String get ttsEngineAutoDescription;

  /// Description shown when on-device text-to-speech preference is active.
  ///
  /// In en, this message translates to:
  /// **'Keep synthesis on this device. Voice playback stops working if on-device TTS isn’t supported.'**
  String get ttsEngineDeviceDescription;

  /// Description shown when server text-to-speech preference is active.
  ///
  /// In en, this message translates to:
  /// **'Always request audio from your OpenWebUI server.'**
  String get ttsEngineServerDescription;

  /// Warning shown when on-device text-to-speech is unavailable.
  ///
  /// In en, this message translates to:
  /// **'On-device text-to-speech isn’t available on this device.'**
  String get ttsDeviceUnavailableWarning;

  /// Warning shown when server text-to-speech is unavailable.
  ///
  /// In en, this message translates to:
  /// **'Connect to a server with text-to-speech enabled to use this option.'**
  String get ttsServerUnavailableWarning;

  /// Section header for TTS-related customization options.
  ///
  /// In en, this message translates to:
  /// **'Text to Speech'**
  String get ttsSettings;

  /// Title for voice selection tile.
  ///
  /// In en, this message translates to:
  /// **'Voice'**
  String get ttsVoice;

  /// Title for speech rate slider.
  ///
  /// In en, this message translates to:
  /// **'Speech Rate'**
  String get ttsSpeechRate;

  /// Title for pitch slider.
  ///
  /// In en, this message translates to:
  /// **'Pitch'**
  String get ttsPitch;

  /// Title for volume slider.
  ///
  /// In en, this message translates to:
  /// **'Volume'**
  String get ttsVolume;

  /// Title for preview button.
  ///
  /// In en, this message translates to:
  /// **'Preview Voice'**
  String get ttsPreview;

  /// Label for system default voice option.
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get ttsSystemDefault;

  /// Title for voice picker bottom sheet.
  ///
  /// In en, this message translates to:
  /// **'Select Voice'**
  String get ttsSelectVoice;

  /// Sample text spoken during voice preview.
  ///
  /// In en, this message translates to:
  /// **'This is a preview of the selected voice.'**
  String get ttsPreviewText;

  /// Error message when no TTS voices can be found.
  ///
  /// In en, this message translates to:
  /// **'No voices available'**
  String get ttsNoVoicesAvailable;

  /// Section header for voices matching the app language
  ///
  /// In en, this message translates to:
  /// **'{language} Voices'**
  String ttsVoicesForLanguage(String language);

  /// Section header for voices in other languages.
  ///
  /// In en, this message translates to:
  /// **'Other Languages'**
  String get ttsOtherVoices;

  /// Generic error label.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// Error label with appended message text.
  ///
  /// In en, this message translates to:
  /// **'Error: {message}'**
  String errorWithMessage(String message);

  /// User-facing message when a network request times out.
  ///
  /// In en, this message translates to:
  /// **'Connection timed out. Please check your internet connection and try again.'**
  String get networkTimeoutError;

  /// User-facing message when the server cannot be reached.
  ///
  /// In en, this message translates to:
  /// **'Cannot reach the server. Please check your server URL and internet connection.'**
  String get networkUnreachableError;

  /// User-facing message when the server does not respond to a request.
  ///
  /// In en, this message translates to:
  /// **'Server is not responding. Please verify the server is running and accessible.'**
  String get networkServerNotResponding;

  /// Fallback message for generic network errors.
  ///
  /// In en, this message translates to:
  /// **'Network connection problem. Please check your internet connection.'**
  String get networkGenericError;

  /// Message when a 500 error is encountered.
  ///
  /// In en, this message translates to:
  /// **'Server is experiencing issues. This is usually temporary.'**
  String get serverError500;

  /// Message when a 502/503 error is encountered.
  ///
  /// In en, this message translates to:
  /// **'Server is temporarily unavailable. Please try again in a moment.'**
  String get serverErrorUnavailable;

  /// Message when the server times out.
  ///
  /// In en, this message translates to:
  /// **'Server took too long to respond. Please try again.'**
  String get serverErrorTimeout;

  /// Fallback server error message.
  ///
  /// In en, this message translates to:
  /// **'Server is having problems. Please try again later.'**
  String get serverErrorGeneric;

  /// Message when an authentication session expires.
  ///
  /// In en, this message translates to:
  /// **'Your session has expired. Please sign in again.'**
  String get authSessionExpired;

  /// Message when the user lacks required permissions.
  ///
  /// In en, this message translates to:
  /// **'You don\'t have permission to perform this action.'**
  String get authForbidden;

  /// Message when the authentication token is invalid.
  ///
  /// In en, this message translates to:
  /// **'Authentication token is invalid. Please sign in again.'**
  String get authInvalidToken;

  /// Fallback authentication error message.
  ///
  /// In en, this message translates to:
  /// **'Authentication problem. Please sign in again.'**
  String get authGenericError;

  /// Validation message for invalid email input.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid email address.'**
  String get validationInvalidEmail;

  /// Validation message for weak passwords.
  ///
  /// In en, this message translates to:
  /// **'Password doesn\'t meet requirements. Please check and try again.'**
  String get validationWeakPassword;

  /// Validation message when required fields are missing.
  ///
  /// In en, this message translates to:
  /// **'Please fill in all required fields.'**
  String get validationMissingRequired;

  /// Validation message for generic formatting issues.
  ///
  /// In en, this message translates to:
  /// **'Some information is in the wrong format. Please check and try again.'**
  String get validationFormatError;

  /// Fallback validation message.
  ///
  /// In en, this message translates to:
  /// **'Please check your input and try again.'**
  String get validationGenericError;

  /// Message when a file cannot be located.
  ///
  /// In en, this message translates to:
  /// **'File not found. It may have been moved or deleted.'**
  String get fileNotFound;

  /// Message when file access is denied.
  ///
  /// In en, this message translates to:
  /// **'Cannot access the file. Please check permissions.'**
  String get fileAccessDenied;

  /// Message when a file exceeds size limits.
  ///
  /// In en, this message translates to:
  /// **'File is too large. Please choose a smaller file.'**
  String get fileTooLarge;

  /// Fallback file error message.
  ///
  /// In en, this message translates to:
  /// **'Problem with the file. Please try a different file.'**
  String get fileGenericError;

  /// Message when camera permission is missing.
  ///
  /// In en, this message translates to:
  /// **'Camera permission is required. Please enable it in settings.'**
  String get permissionCameraRequired;

  /// Message when storage permission is missing.
  ///
  /// In en, this message translates to:
  /// **'Storage permission is required. Please enable it in settings.'**
  String get permissionStorageRequired;

  /// Message when microphone permission is missing.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission is required. Please enable it in settings.'**
  String get permissionMicrophoneRequired;

  /// Fallback permission error message.
  ///
  /// In en, this message translates to:
  /// **'Permission required. Please check app permissions in settings.'**
  String get permissionGenericError;

  /// Description for retrying a failed request.
  ///
  /// In en, this message translates to:
  /// **'Try the request again.'**
  String get actionRetryRequest;

  /// Description for checking internet connectivity.
  ///
  /// In en, this message translates to:
  /// **'Verify your internet connection.'**
  String get actionVerifyConnection;

  /// Description for retrying the same operation.
  ///
  /// In en, this message translates to:
  /// **'Retry the operation.'**
  String get actionRetryOperation;

  /// Description suggesting a short delay before retrying.
  ///
  /// In en, this message translates to:
  /// **'Wait a moment then try again.'**
  String get actionRetryAfterDelay;

  /// Description for signing back into the app.
  ///
  /// In en, this message translates to:
  /// **'Sign in to your account.'**
  String get actionSignInToAccount;

  /// Description for choosing a different file.
  ///
  /// In en, this message translates to:
  /// **'Select another file.'**
  String get actionSelectAnotherFile;

  /// Description for opening system or app settings.
  ///
  /// In en, this message translates to:
  /// **'Open app settings to grant permissions.'**
  String get actionOpenAppSettings;

  /// Description for retrying once permissions are granted.
  ///
  /// In en, this message translates to:
  /// **'Retry after granting permission.'**
  String get actionRetryAfterPermission;

  /// Description for navigating back to the prior screen.
  ///
  /// In en, this message translates to:
  /// **'Return to previous screen.'**
  String get actionReturnToPrevious;

  /// Section header for visual and layout related settings.
  ///
  /// In en, this message translates to:
  /// **'Display'**
  String get display;

  /// Section header for realtime/transport settings.
  ///
  /// In en, this message translates to:
  /// **'Realtime'**
  String get realtime;

  /// Title for selecting the networking transport used for realtime.
  ///
  /// In en, this message translates to:
  /// **'Transport mode'**
  String get transportMode;

  /// Form field label for transport mode dropdown.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get mode;

  /// Dropdown option label for HTTP polling fallback transport.
  ///
  /// In en, this message translates to:
  /// **'Polling fallback'**
  String get transportModePolling;

  /// Dropdown option label for WebSocket-only transport.
  ///
  /// In en, this message translates to:
  /// **'WebSocket only'**
  String get transportModeWs;

  /// Footnote text for the polling fallback transport mode.
  ///
  /// In en, this message translates to:
  /// **'Falls back to HTTP polling when WebSocket is blocked. Upgrades to WebSocket when possible.'**
  String get transportModePollingInfo;

  /// Footnote text for the WebSocket-only transport mode.
  ///
  /// In en, this message translates to:
  /// **'Lower overhead, but may fail behind strict proxies/firewalls.'**
  String get transportModeWsInfo;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>[
    'de',
    'en',
    'es',
    'fr',
    'it',
    'kr',
    'nl',
    'ru',
    'zh',
  ].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fr':
      return AppLocalizationsFr();
    case 'it':
      return AppLocalizationsIt();
    case 'kr':
      return AppLocalizationsKr();
    case 'nl':
      return AppLocalizationsNl();
    case 'ru':
      return AppLocalizationsRu();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
