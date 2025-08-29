import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_it.dart';

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
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Conduit'**
  String get appTitle;

  /// No description provided for @initializationFailed.
  ///
  /// In en, this message translates to:
  /// **'Initialization Failed'**
  String get initializationFailed;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @you.
  ///
  /// In en, this message translates to:
  /// **'You'**
  String get you;

  /// No description provided for @loadingProfile.
  ///
  /// In en, this message translates to:
  /// **'Loading profile...'**
  String get loadingProfile;

  /// No description provided for @unableToLoadProfile.
  ///
  /// In en, this message translates to:
  /// **'Unable to load profile'**
  String get unableToLoadProfile;

  /// No description provided for @pleaseCheckConnection.
  ///
  /// In en, this message translates to:
  /// **'Please check your connection and try again'**
  String get pleaseCheckConnection;

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get signOut;

  /// No description provided for @endYourSession.
  ///
  /// In en, this message translates to:
  /// **'End your session'**
  String get endYourSession;

  /// No description provided for @defaultModel.
  ///
  /// In en, this message translates to:
  /// **'Default Model'**
  String get defaultModel;

  /// No description provided for @autoSelect.
  ///
  /// In en, this message translates to:
  /// **'Auto-select'**
  String get autoSelect;

  /// No description provided for @loadingModels.
  ///
  /// In en, this message translates to:
  /// **'Loading models...'**
  String get loadingModels;

  /// No description provided for @failedToLoadModels.
  ///
  /// In en, this message translates to:
  /// **'Failed to load models'**
  String get failedToLoadModels;

  /// No description provided for @availableModels.
  ///
  /// In en, this message translates to:
  /// **'Available Models'**
  String get availableModels;

  /// No description provided for @noResults.
  ///
  /// In en, this message translates to:
  /// **'No results'**
  String get noResults;

  /// No description provided for @searchModels.
  ///
  /// In en, this message translates to:
  /// **'Search models...'**
  String get searchModels;

  /// No description provided for @errorMessage.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get errorMessage;

  /// No description provided for @loginButton.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get loginButton;

  /// No description provided for @menuItem.
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

  /// No description provided for @closeButtonSemantic.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get closeButtonSemantic;

  /// No description provided for @loadingContent.
  ///
  /// In en, this message translates to:
  /// **'Loading content'**
  String get loadingContent;

  /// No description provided for @noItems.
  ///
  /// In en, this message translates to:
  /// **'No items'**
  String get noItems;

  /// No description provided for @noItemsToDisplay.
  ///
  /// In en, this message translates to:
  /// **'No items to display'**
  String get noItemsToDisplay;

  /// No description provided for @loadMore.
  ///
  /// In en, this message translates to:
  /// **'Load More'**
  String get loadMore;

  /// No description provided for @workspace.
  ///
  /// In en, this message translates to:
  /// **'Workspace'**
  String get workspace;

  /// No description provided for @recentFiles.
  ///
  /// In en, this message translates to:
  /// **'Recent Files'**
  String get recentFiles;

  /// No description provided for @knowledgeBase.
  ///
  /// In en, this message translates to:
  /// **'Knowledge Base'**
  String get knowledgeBase;

  /// No description provided for @noFilesYet.
  ///
  /// In en, this message translates to:
  /// **'No files yet'**
  String get noFilesYet;

  /// No description provided for @uploadDocsPrompt.
  ///
  /// In en, this message translates to:
  /// **'Upload documents to reference in your conversations with Conduit'**
  String get uploadDocsPrompt;

  /// No description provided for @uploadFirstFile.
  ///
  /// In en, this message translates to:
  /// **'Upload your first file'**
  String get uploadFirstFile;

  /// No description provided for @knowledgeBaseEmpty.
  ///
  /// In en, this message translates to:
  /// **'Knowledge base is empty'**
  String get knowledgeBaseEmpty;

  /// No description provided for @createCollectionsPrompt.
  ///
  /// In en, this message translates to:
  /// **'Create collections of related documents for easy reference'**
  String get createCollectionsPrompt;

  /// No description provided for @chooseSourcePhoto.
  ///
  /// In en, this message translates to:
  /// **'Choose your source'**
  String get chooseSourcePhoto;

  /// No description provided for @takePhoto.
  ///
  /// In en, this message translates to:
  /// **'Take a photo'**
  String get takePhoto;

  /// No description provided for @chooseFromGallery.
  ///
  /// In en, this message translates to:
  /// **'Choose from your photos'**
  String get chooseFromGallery;

  /// No description provided for @document.
  ///
  /// In en, this message translates to:
  /// **'Document'**
  String get document;

  /// No description provided for @documentHint.
  ///
  /// In en, this message translates to:
  /// **'PDF, Word, or text file'**
  String get documentHint;

  /// No description provided for @uploadFileTitle.
  ///
  /// In en, this message translates to:
  /// **'Upload File'**
  String get uploadFileTitle;

  /// Temporary message for upcoming upload feature by type
  ///
  /// In en, this message translates to:
  /// **'File upload for {type} is coming soon!'**
  String fileUploadComingSoon(String type);

  /// No description provided for @kbCreationComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Knowledge base creation is coming soon!'**
  String get kbCreationComingSoon;

  /// No description provided for @backToServerSetup.
  ///
  /// In en, this message translates to:
  /// **'Back to server setup'**
  String get backToServerSetup;

  /// No description provided for @connectedToServer.
  ///
  /// In en, this message translates to:
  /// **'Connected to Server'**
  String get connectedToServer;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get signIn;

  /// No description provided for @enterCredentials.
  ///
  /// In en, this message translates to:
  /// **'Enter your credentials to access your AI conversations'**
  String get enterCredentials;

  /// No description provided for @credentials.
  ///
  /// In en, this message translates to:
  /// **'Credentials'**
  String get credentials;

  /// No description provided for @apiKey.
  ///
  /// In en, this message translates to:
  /// **'API Key'**
  String get apiKey;

  /// No description provided for @usernameOrEmail.
  ///
  /// In en, this message translates to:
  /// **'Username or Email'**
  String get usernameOrEmail;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @signInWithApiKey.
  ///
  /// In en, this message translates to:
  /// **'Sign in with API Key'**
  String get signInWithApiKey;

  /// No description provided for @connectToServer.
  ///
  /// In en, this message translates to:
  /// **'Connect to Server'**
  String get connectToServer;

  /// No description provided for @enterServerAddress.
  ///
  /// In en, this message translates to:
  /// **'Enter your Open-WebUI server address to get started'**
  String get enterServerAddress;

  /// No description provided for @serverUrl.
  ///
  /// In en, this message translates to:
  /// **'Server URL'**
  String get serverUrl;

  /// No description provided for @serverUrlHint.
  ///
  /// In en, this message translates to:
  /// **'https://your-server.com'**
  String get serverUrlHint;

  /// No description provided for @enterServerUrlSemantic.
  ///
  /// In en, this message translates to:
  /// **'Enter your server URL or IP address'**
  String get enterServerUrlSemantic;

  /// No description provided for @headerName.
  ///
  /// In en, this message translates to:
  /// **'Header Name'**
  String get headerName;

  /// No description provided for @headerValue.
  ///
  /// In en, this message translates to:
  /// **'Header Value'**
  String get headerValue;

  /// No description provided for @headerValueHint.
  ///
  /// In en, this message translates to:
  /// **'api-key-123 or Bearer token'**
  String get headerValueHint;

  /// No description provided for @addHeader.
  ///
  /// In en, this message translates to:
  /// **'Add header'**
  String get addHeader;

  /// No description provided for @maximumHeadersReached.
  ///
  /// In en, this message translates to:
  /// **'Maximum headers reached'**
  String get maximumHeadersReached;

  /// No description provided for @removeHeader.
  ///
  /// In en, this message translates to:
  /// **'Remove header'**
  String get removeHeader;

  /// No description provided for @connecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get connecting;

  /// No description provided for @connectToServerButton.
  ///
  /// In en, this message translates to:
  /// **'Connect to Server'**
  String get connectToServerButton;

  /// No description provided for @demoModeActive.
  ///
  /// In en, this message translates to:
  /// **'Demo Mode Active'**
  String get demoModeActive;

  /// No description provided for @skipServerSetupTryDemo.
  ///
  /// In en, this message translates to:
  /// **'Skip server setup and try the demo'**
  String get skipServerSetupTryDemo;

  /// No description provided for @enterDemo.
  ///
  /// In en, this message translates to:
  /// **'Enter Demo'**
  String get enterDemo;

  /// No description provided for @demoBadge.
  ///
  /// In en, this message translates to:
  /// **'Demo'**
  String get demoBadge;

  /// No description provided for @serverNotOpenWebUI.
  ///
  /// In en, this message translates to:
  /// **'This does not appear to be an Open-WebUI server.'**
  String get serverNotOpenWebUI;

  /// No description provided for @serverUrlEmpty.
  ///
  /// In en, this message translates to:
  /// **'Server URL cannot be empty'**
  String get serverUrlEmpty;

  /// No description provided for @invalidUrlFormat.
  ///
  /// In en, this message translates to:
  /// **'Invalid URL format. Please check your input.'**
  String get invalidUrlFormat;

  /// No description provided for @onlyHttpHttps.
  ///
  /// In en, this message translates to:
  /// **'Only HTTP and HTTPS protocols are supported.'**
  String get onlyHttpHttps;

  /// No description provided for @serverAddressRequired.
  ///
  /// In en, this message translates to:
  /// **'Server address is required (e.g., 192.168.1.10 or example.com).'**
  String get serverAddressRequired;

  /// No description provided for @portRange.
  ///
  /// In en, this message translates to:
  /// **'Port must be between 1 and 65535.'**
  String get portRange;

  /// No description provided for @invalidIpFormat.
  ///
  /// In en, this message translates to:
  /// **'Invalid IP address format. Use format like 192.168.1.10.'**
  String get invalidIpFormat;

  /// No description provided for @couldNotConnectGeneric.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t connect. Double-check the address and try again.'**
  String get couldNotConnectGeneric;

  /// No description provided for @weCouldntReachServer.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t reach the server. Check your connection and that the server is running.'**
  String get weCouldntReachServer;

  /// No description provided for @connectionTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Connection timed out. The server might be busy or blocked by a firewall.'**
  String get connectionTimedOut;

  /// No description provided for @useHttpOrHttpsOnly.
  ///
  /// In en, this message translates to:
  /// **'Use http:// or https:// only.'**
  String get useHttpOrHttpsOnly;

  /// No description provided for @loginFailed.
  ///
  /// In en, this message translates to:
  /// **'Login failed'**
  String get loginFailed;

  /// No description provided for @invalidCredentials.
  ///
  /// In en, this message translates to:
  /// **'Invalid username or password. Please try again.'**
  String get invalidCredentials;

  /// No description provided for @serverRedirectingHttps.
  ///
  /// In en, this message translates to:
  /// **'The server is redirecting requests. Check your server\'s HTTPS configuration.'**
  String get serverRedirectingHttps;

  /// No description provided for @unableToConnectServer.
  ///
  /// In en, this message translates to:
  /// **'Unable to connect to server. Please check your connection.'**
  String get unableToConnectServer;

  /// No description provided for @requestTimedOut.
  ///
  /// In en, this message translates to:
  /// **'The request timed out. Please try again.'**
  String get requestTimedOut;

  /// No description provided for @genericSignInFailed.
  ///
  /// In en, this message translates to:
  /// **'We couldn\'t sign you in. Check your credentials and server settings.'**
  String get genericSignInFailed;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @onboardStartTitle.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation'**
  String get onboardStartTitle;

  /// No description provided for @onboardStartSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a model, then type below to begin. Tap New Chat anytime.'**
  String get onboardStartSubtitle;

  /// No description provided for @onboardStartBullet1.
  ///
  /// In en, this message translates to:
  /// **'Tap the model name in the top bar to switch models'**
  String get onboardStartBullet1;

  /// No description provided for @onboardStartBullet2.
  ///
  /// In en, this message translates to:
  /// **'Use New Chat to reset context'**
  String get onboardStartBullet2;

  /// No description provided for @onboardAttachTitle.
  ///
  /// In en, this message translates to:
  /// **'Add context'**
  String get onboardAttachTitle;

  /// No description provided for @onboardAttachSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Ground replies with content from Workspace or photos.'**
  String get onboardAttachSubtitle;

  /// No description provided for @onboardAttachBullet1.
  ///
  /// In en, this message translates to:
  /// **'Workspace: PDFs, docs, datasets'**
  String get onboardAttachBullet1;

  /// No description provided for @onboardAttachBullet2.
  ///
  /// In en, this message translates to:
  /// **'Photos: camera or library'**
  String get onboardAttachBullet2;

  /// No description provided for @onboardSpeakTitle.
  ///
  /// In en, this message translates to:
  /// **'Speak naturally'**
  String get onboardSpeakTitle;

  /// No description provided for @onboardSpeakSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tap the mic to dictate with live waveform feedback.'**
  String get onboardSpeakSubtitle;

  /// No description provided for @onboardSpeakBullet1.
  ///
  /// In en, this message translates to:
  /// **'Stop anytime; partial text is preserved'**
  String get onboardSpeakBullet1;

  /// No description provided for @onboardSpeakBullet2.
  ///
  /// In en, this message translates to:
  /// **'Great for quick notes or long prompts'**
  String get onboardSpeakBullet2;

  /// No description provided for @onboardQuickTitle.
  ///
  /// In en, this message translates to:
  /// **'Quick actions'**
  String get onboardQuickTitle;

  /// No description provided for @onboardQuickSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Open the menu to switch between Chats, Workspace, and Profile.'**
  String get onboardQuickSubtitle;

  /// No description provided for @onboardQuickBullet1.
  ///
  /// In en, this message translates to:
  /// **'Tap the menu to access Chats, Workspace, Profile'**
  String get onboardQuickBullet1;

  /// No description provided for @onboardQuickBullet2.
  ///
  /// In en, this message translates to:
  /// **'Start New Chat or manage models from the top bar'**
  String get onboardQuickBullet2;

  /// No description provided for @addAttachment.
  ///
  /// In en, this message translates to:
  /// **'Add attachment'**
  String get addAttachment;

  /// No description provided for @tools.
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get tools;

  /// No description provided for @voiceInput.
  ///
  /// In en, this message translates to:
  /// **'Voice input'**
  String get voiceInput;

  /// No description provided for @messageInputLabel.
  ///
  /// In en, this message translates to:
  /// **'Message input'**
  String get messageInputLabel;

  /// No description provided for @messageInputHint.
  ///
  /// In en, this message translates to:
  /// **'Type your message'**
  String get messageInputHint;

  /// No description provided for @messageHintText.
  ///
  /// In en, this message translates to:
  /// **'Message...'**
  String get messageHintText;

  /// No description provided for @stopGenerating.
  ///
  /// In en, this message translates to:
  /// **'Stop generating'**
  String get stopGenerating;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @sendMessage.
  ///
  /// In en, this message translates to:
  /// **'Send message'**
  String get sendMessage;

  /// No description provided for @file.
  ///
  /// In en, this message translates to:
  /// **'File'**
  String get file;

  /// No description provided for @photo.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get photo;

  /// No description provided for @camera.
  ///
  /// In en, this message translates to:
  /// **'Camera'**
  String get camera;

  /// No description provided for @apiUnavailable.
  ///
  /// In en, this message translates to:
  /// **'API service not available'**
  String get apiUnavailable;

  /// No description provided for @unableToLoadImage.
  ///
  /// In en, this message translates to:
  /// **'Unable to load image'**
  String get unableToLoadImage;

  /// No description provided for @notAnImageFile.
  ///
  /// In en, this message translates to:
  /// **'Not an image file: {fileName}'**
  String notAnImageFile(String fileName);

  /// No description provided for @failedToLoadImage.
  ///
  /// In en, this message translates to:
  /// **'Failed to load image: {error}'**
  String failedToLoadImage(String error);

  /// No description provided for @invalidDataUrl.
  ///
  /// In en, this message translates to:
  /// **'Invalid data URL format'**
  String get invalidDataUrl;

  /// No description provided for @failedToDecodeImage.
  ///
  /// In en, this message translates to:
  /// **'Failed to decode image'**
  String get failedToDecodeImage;

  /// No description provided for @invalidImageFormat.
  ///
  /// In en, this message translates to:
  /// **'Invalid image format'**
  String get invalidImageFormat;

  /// No description provided for @emptyImageData.
  ///
  /// In en, this message translates to:
  /// **'Empty image data'**
  String get emptyImageData;

  /// No description provided for @offlineBanner.
  ///
  /// In en, this message translates to:
  /// **'You\'re offline. Some features may be limited.'**
  String get offlineBanner;

  /// No description provided for @featureRequiresInternet.
  ///
  /// In en, this message translates to:
  /// **'This feature requires an internet connection'**
  String get featureRequiresInternet;

  /// No description provided for @messagesWillSendWhenOnline.
  ///
  /// In en, this message translates to:
  /// **'Messages will be sent when you\'re back online'**
  String get messagesWillSendWhenOnline;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @inputField.
  ///
  /// In en, this message translates to:
  /// **'Input field'**
  String get inputField;

  /// No description provided for @captureDocumentOrImage.
  ///
  /// In en, this message translates to:
  /// **'Capture a document or image'**
  String get captureDocumentOrImage;

  /// No description provided for @checkConnection.
  ///
  /// In en, this message translates to:
  /// **'Check Connection'**
  String get checkConnection;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get openSettings;

  /// No description provided for @chooseDifferentFile.
  ///
  /// In en, this message translates to:
  /// **'Choose Different File'**
  String get chooseDifferentFile;

  /// No description provided for @goBack.
  ///
  /// In en, this message translates to:
  /// **'Go Back'**
  String get goBack;

  /// No description provided for @technicalDetails.
  ///
  /// In en, this message translates to:
  /// **'Technical Details'**
  String get technicalDetails;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @chooseModel.
  ///
  /// In en, this message translates to:
  /// **'Choose Model'**
  String get chooseModel;

  /// No description provided for @reviewerMode.
  ///
  /// In en, this message translates to:
  /// **'REVIEWER MODE'**
  String get reviewerMode;

  /// No description provided for @selectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select Language'**
  String get selectLanguage;

  /// No description provided for @newFolder.
  ///
  /// In en, this message translates to:
  /// **'New Folder'**
  String get newFolder;

  /// No description provided for @folderName.
  ///
  /// In en, this message translates to:
  /// **'Folder name'**
  String get folderName;

  /// No description provided for @newChat.
  ///
  /// In en, this message translates to:
  /// **'New Chat'**
  String get newChat;

  /// No description provided for @more.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get more;

  /// No description provided for @clear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get clear;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search...'**
  String get searchHint;

  /// No description provided for @searchConversations.
  ///
  /// In en, this message translates to:
  /// **'Search conversations...'**
  String get searchConversations;

  /// No description provided for @create.
  ///
  /// In en, this message translates to:
  /// **'Create'**
  String get create;

  /// No description provided for @folderCreated.
  ///
  /// In en, this message translates to:
  /// **'Folder created'**
  String get folderCreated;

  /// No description provided for @failedToCreateFolder.
  ///
  /// In en, this message translates to:
  /// **'Failed to create folder'**
  String get failedToCreateFolder;

  /// No description provided for @movedChatToFolder.
  ///
  /// In en, this message translates to:
  /// **'Moved \"{title}\" to \"{folder}\"'**
  String movedChatToFolder(String title, String folder);

  /// No description provided for @failedToMoveChat.
  ///
  /// In en, this message translates to:
  /// **'Failed to move chat'**
  String get failedToMoveChat;

  /// No description provided for @failedToLoadChats.
  ///
  /// In en, this message translates to:
  /// **'Failed to load chats'**
  String get failedToLoadChats;

  /// No description provided for @failedToUpdatePin.
  ///
  /// In en, this message translates to:
  /// **'Failed to update pin'**
  String get failedToUpdatePin;

  /// No description provided for @failedToDeleteChat.
  ///
  /// In en, this message translates to:
  /// **'Failed to delete chat'**
  String get failedToDeleteChat;

  /// No description provided for @manage.
  ///
  /// In en, this message translates to:
  /// **'Manage'**
  String get manage;

  /// No description provided for @rename.
  ///
  /// In en, this message translates to:
  /// **'Rename'**
  String get rename;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @renameChat.
  ///
  /// In en, this message translates to:
  /// **'Rename Chat'**
  String get renameChat;

  /// No description provided for @enterChatName.
  ///
  /// In en, this message translates to:
  /// **'Enter chat name'**
  String get enterChatName;

  /// No description provided for @failedToRenameChat.
  ///
  /// In en, this message translates to:
  /// **'Failed to rename chat'**
  String get failedToRenameChat;

  /// No description provided for @failedToUpdateArchive.
  ///
  /// In en, this message translates to:
  /// **'Failed to update archive'**
  String get failedToUpdateArchive;

  /// No description provided for @unarchive.
  ///
  /// In en, this message translates to:
  /// **'Unarchive'**
  String get unarchive;

  /// No description provided for @archive.
  ///
  /// In en, this message translates to:
  /// **'Archive'**
  String get archive;

  /// No description provided for @pin.
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get pin;

  /// No description provided for @unpin.
  ///
  /// In en, this message translates to:
  /// **'Unpin'**
  String get unpin;

  /// No description provided for @recent.
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get recent;

  /// No description provided for @system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @deutsch.
  ///
  /// In en, this message translates to:
  /// **'Deutsch'**
  String get deutsch;

  /// No description provided for @francais.
  ///
  /// In en, this message translates to:
  /// **'Français'**
  String get francais;

  /// No description provided for @italiano.
  ///
  /// In en, this message translates to:
  /// **'Italiano'**
  String get italiano;

  /// No description provided for @espanol.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get espanol;

  /// No description provided for @deleteMessagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Messages'**
  String get deleteMessagesTitle;

  /// No description provided for @deleteMessagesMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete {count} messages?'**
  String deleteMessagesMessage(int count);

  /// No description provided for @routeNotFound.
  ///
  /// In en, this message translates to:
  /// **'Route not found: {routeName}'**
  String routeNotFound(String routeName);

  /// No description provided for @deleteChatTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Chat'**
  String get deleteChatTitle;

  /// No description provided for @deleteChatMessage.
  ///
  /// In en, this message translates to:
  /// **'This chat will be permanently deleted.'**
  String get deleteChatMessage;

  /// No description provided for @aboutApp.
  ///
  /// In en, this message translates to:
  /// **'About App'**
  String get aboutApp;

  /// No description provided for @aboutAppSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Conduit information and links'**
  String get aboutAppSubtitle;

  /// No description provided for @typeBelowToBegin.
  ///
  /// In en, this message translates to:
  /// **'Type below to begin'**
  String get typeBelowToBegin;

  /// No description provided for @web.
  ///
  /// In en, this message translates to:
  /// **'Web'**
  String get web;

  /// No description provided for @imageGen.
  ///
  /// In en, this message translates to:
  /// **'Image Gen'**
  String get imageGen;

  /// No description provided for @pinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinned;

  /// No description provided for @folders.
  ///
  /// In en, this message translates to:
  /// **'Folders'**
  String get folders;

  /// No description provided for @archived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get archived;

  /// No description provided for @appLanguage.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get appLanguage;

  /// No description provided for @darkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark mode'**
  String get darkMode;

  /// No description provided for @webSearch.
  ///
  /// In en, this message translates to:
  /// **'Web Search'**
  String get webSearch;

  /// No description provided for @webSearchDescription.
  ///
  /// In en, this message translates to:
  /// **'Search the web and cite sources in replies.'**
  String get webSearchDescription;

  /// No description provided for @imageGeneration.
  ///
  /// In en, this message translates to:
  /// **'Image Generation'**
  String get imageGeneration;

  /// No description provided for @imageGenerationDescription.
  ///
  /// In en, this message translates to:
  /// **'Create images from your prompts.'**
  String get imageGenerationDescription;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @regenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get regenerate;

  /// No description provided for @noConversationsYet.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get noConversationsYet;

  /// No description provided for @usernameOrEmailHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your username or email'**
  String get usernameOrEmailHint;

  /// No description provided for @passwordHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your password'**
  String get passwordHint;

  /// No description provided for @enterApiKey.
  ///
  /// In en, this message translates to:
  /// **'Enter your API key'**
  String get enterApiKey;

  /// No description provided for @signingIn.
  ///
  /// In en, this message translates to:
  /// **'Signing in...'**
  String get signingIn;

  /// No description provided for @advancedSettings.
  ///
  /// In en, this message translates to:
  /// **'Advanced Settings'**
  String get advancedSettings;

  /// No description provided for @customHeaders.
  ///
  /// In en, this message translates to:
  /// **'Custom Headers'**
  String get customHeaders;

  /// No description provided for @customHeadersDescription.
  ///
  /// In en, this message translates to:
  /// **'Add custom HTTP headers for authentication, API keys, or special server requirements.'**
  String get customHeadersDescription;

  /// No description provided for @headerNameEmpty.
  ///
  /// In en, this message translates to:
  /// **'Header name cannot be empty'**
  String get headerNameEmpty;

  /// No description provided for @headerNameTooLong.
  ///
  /// In en, this message translates to:
  /// **'Header name too long (max 64 characters)'**
  String get headerNameTooLong;

  /// No description provided for @headerNameInvalidChars.
  ///
  /// In en, this message translates to:
  /// **'Invalid header name. Use only letters, numbers, and these symbols: !#\$&-^_`|~'**
  String get headerNameInvalidChars;

  /// No description provided for @headerNameReserved.
  ///
  /// In en, this message translates to:
  /// **'Cannot override reserved header \"{key}\"'**
  String headerNameReserved(String key);

  /// No description provided for @headerValueEmpty.
  ///
  /// In en, this message translates to:
  /// **'Header value cannot be empty'**
  String get headerValueEmpty;

  /// No description provided for @headerValueTooLong.
  ///
  /// In en, this message translates to:
  /// **'Header value too long (max 1024 characters)'**
  String get headerValueTooLong;

  /// No description provided for @headerValueInvalidChars.
  ///
  /// In en, this message translates to:
  /// **'Header value contains invalid characters. Use only printable ASCII.'**
  String get headerValueInvalidChars;

  /// No description provided for @headerValueUnsafe.
  ///
  /// In en, this message translates to:
  /// **'Header value appears to contain potentially unsafe content'**
  String get headerValueUnsafe;

  /// No description provided for @headerAlreadyExists.
  ///
  /// In en, this message translates to:
  /// **'Header \"{key}\" already exists. Remove it first to update.'**
  String headerAlreadyExists(String key);

  /// No description provided for @maxHeadersReachedDetail.
  ///
  /// In en, this message translates to:
  /// **'Maximum of 10 custom headers allowed. Remove some to add more.'**
  String get maxHeadersReachedDetail;

  /// No description provided for @editMessage.
  ///
  /// In en, this message translates to:
  /// **'Edit Message'**
  String get editMessage;

  /// No description provided for @noModelsAvailable.
  ///
  /// In en, this message translates to:
  /// **'No models available'**
  String get noModelsAvailable;

  /// No description provided for @followingSystem.
  ///
  /// In en, this message translates to:
  /// **'Following system: {theme}'**
  String followingSystem(String theme);

  /// No description provided for @themeDark.
  ///
  /// In en, this message translates to:
  /// **'Dark'**
  String get themeDark;

  /// No description provided for @themeLight.
  ///
  /// In en, this message translates to:
  /// **'Light'**
  String get themeLight;

  /// No description provided for @currentlyUsingDarkTheme.
  ///
  /// In en, this message translates to:
  /// **'Currently using Dark theme'**
  String get currentlyUsingDarkTheme;

  /// No description provided for @currentlyUsingLightTheme.
  ///
  /// In en, this message translates to:
  /// **'Currently using Light theme'**
  String get currentlyUsingLightTheme;

  /// No description provided for @aboutConduit.
  ///
  /// In en, this message translates to:
  /// **'About Conduit'**
  String get aboutConduit;

  /// No description provided for @versionLabel.
  ///
  /// In en, this message translates to:
  /// **'Version: {version} ({build})'**
  String versionLabel(String version, String build);

  /// No description provided for @githubRepository.
  ///
  /// In en, this message translates to:
  /// **'GitHub Repository'**
  String get githubRepository;

  /// No description provided for @unableToLoadAppInfo.
  ///
  /// In en, this message translates to:
  /// **'Unable to load app info'**
  String get unableToLoadAppInfo;

  /// No description provided for @thinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking…'**
  String get thinking;

  /// No description provided for @thoughts.
  ///
  /// In en, this message translates to:
  /// **'Thoughts'**
  String get thoughts;

  /// Shows how long the assistant thought before replying.
  ///
  /// In en, this message translates to:
  /// **'Thought for {duration}'**
  String thoughtForDuration(String duration);

  /// No description provided for @ttsLanguage.
  ///
  /// In en, this message translates to:
  /// **'TTS Language'**
  String get ttsLanguage;

  /// No description provided for @ttsLanguageDescription.
  ///
  /// In en, this message translates to:
  /// **'Choose language for text-to-speech'**
  String get ttsLanguageDescription;

  /// No description provided for @listen.
  ///
  /// In en, this message translates to:
  /// **'Listen'**
  String get listen;

  /// No description provided for @stop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get stop;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en', 'fr', 'it'].contains(locale.languageCode);

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
    case 'fr':
      return AppLocalizationsFr();
    case 'it':
      return AppLocalizationsIt();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
