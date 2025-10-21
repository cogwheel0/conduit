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
import 'app_localizations_ko.dart';
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
    Locale('ko'),
  ];

  /// Application name displayed in the app and OS UI.
  ///
  /// In en, this message translates to:
  /// **'Conduit'**
  String get appTitle;

  /// Shown if the app fails to initialize critical services.
  ///
  /// In en, this message translates to:
  /// **'Initialization Failed'**
  String get initializationFailed;

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

  /// Status message after a retry when connectivity has not been restored
  ///
  /// In en, this message translates to:
  /// **'We still can\'t reach the server. Double-check your connection and try again.'**
  String get stillOfflineMessage;

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

  /// Button text for the login action.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get loginButton;

  /// Generic settings menu item label.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get menuItem;

  /// Greeting message with a dynamic user name.
  ///
  /// In en, this message translates to:
  /// **'Welcome, {name}!'**
  String dynamicContentWithPlaceholder(String name);

  /// Pluralized count of items.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No items} one{1 item} other{{count} items}}'**
  String itemsCount(int count);

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

  /// Button label to load additional items in a paged list.
  ///
  /// In en, this message translates to:
  /// **'Load More'**
  String get loadMore;

  /// Section/tab label for documents and files.
  ///
  /// In en, this message translates to:
  /// **'Workspace'**
  String get workspace;

  /// Header for recently accessed files.
  ///
  /// In en, this message translates to:
  /// **'Recent Files'**
  String get recentFiles;

  /// Section for knowledge base content.
  ///
  /// In en, this message translates to:
  /// **'Knowledge Base'**
  String get knowledgeBase;

  /// Empty state when no files are present.
  ///
  /// In en, this message translates to:
  /// **'No files yet'**
  String get noFilesYet;

  /// Prompt encouraging users to upload documents.
  ///
  /// In en, this message translates to:
  /// **'Upload documents to reference in your conversations with Conduit'**
  String get uploadDocsPrompt;

  /// CTA to add the first file.
  ///
  /// In en, this message translates to:
  /// **'Upload your first file'**
  String get uploadFirstFile;

  /// Header above list of attached files in compose area.
  ///
  /// In en, this message translates to:
  /// **'Attachments'**
  String get attachments;

  /// Empty state title for the knowledge base section.
  ///
  /// In en, this message translates to:
  /// **'Knowledge base is empty'**
  String get knowledgeBaseEmpty;

  /// Prompt describing the benefit of creating collections.
  ///
  /// In en, this message translates to:
  /// **'Create collections of related documents for easy reference'**
  String get createCollectionsPrompt;

  /// Sheet title to pick camera or photo library.
  ///
  /// In en, this message translates to:
  /// **'Choose your source'**
  String get chooseSourcePhoto;

  /// Action to open camera and capture a new photo.
  ///
  /// In en, this message translates to:
  /// **'Take a photo'**
  String get takePhoto;

  /// Action to pick an existing photo from library.
  ///
  /// In en, this message translates to:
  /// **'Choose from your photos'**
  String get chooseFromGallery;

  /// Generic document label used in UI.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get document;

  /// Helper hint listing supported document types.
  ///
  /// In en, this message translates to:
  /// **'PDF, Word, or text file'**
  String get documentHint;

  /// Dialog/sheet title for file upload.
  ///
  /// In en, this message translates to:
  /// **'Upload File'**
  String get uploadFileTitle;

  /// Temporary message for upcoming upload feature by type
  ///
  /// In en, this message translates to:
  /// **'File upload for {type} is coming soon!'**
  String fileUploadComingSoon(String type);

  /// Temporary message indicating KB creation feature is not yet available.
  ///
  /// In en, this message translates to:
  /// **'Knowledge base creation is coming soon!'**
  String get kbCreationComingSoon;

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

  /// Button to add an attachment (file/photo).
  ///
  /// In en, this message translates to:
  /// **'Add attachment'**
  String get addAttachment;

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

  /// Informational text explaining internet requirement.
  ///
  /// In en, this message translates to:
  /// **'This feature requires an internet connection'**
  String get featureRequiresInternet;

  /// Queue behavior notice while offline.
  ///
  /// In en, this message translates to:
  /// **'Messages will be sent when you\'re back online'**
  String get messagesWillSendWhenOnline;

  /// Confirmation button label.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

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

  /// Accessibility label describing an input field.
  ///
  /// In en, this message translates to:
  /// **'Input field'**
  String get inputField;

  /// Action to capture a document or image using camera.
  ///
  /// In en, this message translates to:
  /// **'Capture a document or image'**
  String get captureDocumentOrImage;

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

  /// CTA to pick an alternative file.
  ///
  /// In en, this message translates to:
  /// **'Choose Different File'**
  String get chooseDifferentFile;

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

  /// Generic search input hint.
  ///
  /// In en, this message translates to:
  /// **'Search...'**
  String get searchHint;

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

  /// Toast/notice after successfully creating a folder.
  ///
  /// In en, this message translates to:
  /// **'Folder created'**
  String get folderCreated;

  /// Error notice when folder creation fails.
  ///
  /// In en, this message translates to:
  /// **'Failed to create folder'**
  String get failedToCreateFolder;

  /// Toast indicating a chat titled {title} was moved to folder {folder}.
  ///
  /// In en, this message translates to:
  /// **'Moved \"{title}\" to \"{folder}\"'**
  String movedChatToFolder(String title, String folder);

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

  /// Action to edit a previously sent message.
  ///
  /// In en, this message translates to:
  /// **'Edit Message'**
  String get editMessage;

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

  /// Helper text explaining palette selection.
  ///
  /// In en, this message translates to:
  /// **'Choose the accent colors used for buttons, cards, and chat bubbles.'**
  String get themePaletteDescription;

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

  /// Helper text explaining the transport setting.
  ///
  /// In en, this message translates to:
  /// **'Choose how the app connects for realtime updates.'**
  String get transportModeDescription;

  /// Form field label for transport mode dropdown.
  ///
  /// In en, this message translates to:
  /// **'Mode'**
  String get mode;

  /// Dropdown option label for automatic transport selection.
  ///
  /// In en, this message translates to:
  /// **'Auto (Polling + WebSocket)'**
  String get transportModeAuto;

  /// Dropdown option label for WebSocket-only transport.
  ///
  /// In en, this message translates to:
  /// **'WebSocket only'**
  String get transportModeWs;

  /// Footnote text for the Auto transport mode.
  ///
  /// In en, this message translates to:
  /// **'More robust on restrictive networks. Upgrades to WebSocket when possible.'**
  String get transportModeAutoInfo;

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
    'ko',
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
    case 'ko':
      return AppLocalizationsKo();
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
