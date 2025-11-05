// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Conduit';

  @override
  String get retry => 'Retry';

  @override
  String get back => 'Back';

  @override
  String get you => 'You';

  @override
  String get loadingProfile => 'Loading profile...';

  @override
  String get unableToLoadProfile => 'Unable to load profile';

  @override
  String get pleaseCheckConnection =>
      'Please check your connection and try again';

  @override
  String get connectionIssueTitle => 'Can\'t reach your server';

  @override
  String get connectionIssueSubtitle =>
      'Reconnect to continue or sign out to choose a different server.';

  @override
  String get connectionTimeout => 'Connection Timeout';

  @override
  String get connectionTimeoutMessage =>
      'The app is taking longer than expected to connect. This might be due to a slow connection or server timeout.';

  @override
  String get account => 'Account';

  @override
  String get supportConduit => 'Support Conduit';

  @override
  String get supportConduitSubtitle =>
      'Keep Conduit independent by funding ongoing development.';

  @override
  String get githubSponsorsTitle => 'GitHub Sponsors';

  @override
  String get githubSponsorsSubtitle =>
      'Become a recurring sponsor to fund roadmap items.';

  @override
  String get buyMeACoffeeTitle => 'Buy Me a Coffee';

  @override
  String get buyMeACoffeeSubtitle => 'Make a one-time donation to say thanks.';

  @override
  String get signOut => 'Sign Out';

  @override
  String get endYourSession => 'End your session';

  @override
  String get defaultModel => 'Default Model';

  @override
  String get autoSelect => 'Auto-select';

  @override
  String get loadingModels => 'Loading models...';

  @override
  String get failedToLoadModels => 'Failed to load models';

  @override
  String get availableModels => 'Available Models';

  @override
  String get modelCapabilityMultimodal => 'Multimodal';

  @override
  String get modelCapabilityReasoning => 'Reasoning';

  @override
  String get noResults => 'No results';

  @override
  String get searchModels => 'Search models...';

  @override
  String get errorMessage => 'Something went wrong. Please try again.';

  @override
  String get closeButtonSemantic => 'Close';

  @override
  String get loadingContent => 'Loading content';

  @override
  String get loadingShort => 'Loading';

  @override
  String loadingAnnouncement(String message) {
    return 'Loading: $message';
  }

  @override
  String errorAnnouncement(String error) {
    return 'Error: $error';
  }

  @override
  String errorAnnouncementWithSuggestion(String error, String suggestion) {
    return 'Error: $error. $suggestion';
  }

  @override
  String successAnnouncement(String message) {
    return 'Success: $message';
  }

  @override
  String get noItems => 'No items';

  @override
  String get noItemsToDisplay => 'No items to display';

  @override
  String get knowledgeBase => 'Knowledge Base';

  @override
  String get attachments => 'Attachments';

  @override
  String get takePhoto => 'Take a photo';

  @override
  String get document => 'Document';

  @override
  String get backToServerSetup => 'Back to server setup';

  @override
  String get connectedToServer => 'Connected to Server';

  @override
  String get signIn => 'Sign In';

  @override
  String get enterCredentials =>
      'Enter your credentials to access your AI conversations';

  @override
  String get credentials => 'Credentials';

  @override
  String get apiKey => 'API Key';

  @override
  String get usernameOrEmail => 'Username or Email';

  @override
  String get password => 'Password';

  @override
  String get signInWithApiKey => 'Sign in with API Key';

  @override
  String get connectToServer => 'Connect to Server';

  @override
  String get enterServerAddress =>
      'Enter your Open-WebUI server address to get started';

  @override
  String get serverUrl => 'Server URL';

  @override
  String get serverUrlHint => 'https://your-server.com';

  @override
  String get enterServerUrlSemantic => 'Enter your server URL or IP address';

  @override
  String get headerName => 'Header Name';

  @override
  String get headerValue => 'Header Value';

  @override
  String get headerValueHint => 'api-key-123 or Bearer token';

  @override
  String get addHeader => 'Add header';

  @override
  String get maximumHeadersReached => 'Maximum headers reached';

  @override
  String get removeHeader => 'Remove header';

  @override
  String get connecting => 'Connecting...';

  @override
  String get connectToServerButton => 'Connect to Server';

  @override
  String get demoModeActive => 'Demo Mode Active';

  @override
  String get skipServerSetupTryDemo => 'Skip server setup and try the demo';

  @override
  String get enterDemo => 'Enter Demo';

  @override
  String get demoBadge => 'Demo';

  @override
  String get serverNotOpenWebUI =>
      'This does not appear to be an Open-WebUI server.';

  @override
  String get serverUrlEmpty => 'Server URL cannot be empty';

  @override
  String get invalidUrlFormat => 'Invalid URL format. Please check your input.';

  @override
  String get onlyHttpHttps => 'Only HTTP and HTTPS protocols are supported.';

  @override
  String get serverAddressRequired =>
      'Server address is required (e.g., 192.168.1.10 or example.com).';

  @override
  String get portRange => 'Port must be between 1 and 65535.';

  @override
  String get invalidIpFormat =>
      'Invalid IP address format. Use format like 192.168.1.10.';

  @override
  String get couldNotConnectGeneric =>
      'Couldn\'t connect. Double-check the address and try again.';

  @override
  String get weCouldntReachServer =>
      'We couldn\'t reach the server. Check your connection and that the server is running.';

  @override
  String get connectionTimedOut =>
      'Connection timed out. The server might be busy or blocked by a firewall.';

  @override
  String get useHttpOrHttpsOnly => 'Use http:// or https:// only.';

  @override
  String get loginFailed => 'Login failed';

  @override
  String get invalidCredentials =>
      'Invalid username or password. Please try again.';

  @override
  String get serverRedirectingHttps =>
      'The server is redirecting requests. Check your server\'s HTTPS configuration.';

  @override
  String get unableToConnectServer =>
      'Unable to connect to server. Please check your connection.';

  @override
  String get requestTimedOut => 'The request timed out. Please try again.';

  @override
  String get genericSignInFailed =>
      'We couldn\'t sign you in. Check your credentials and server settings.';

  @override
  String get skip => 'Skip';

  @override
  String get next => 'Next';

  @override
  String get done => 'Done';

  @override
  String onboardStartTitle(String username) {
    return 'Hello, $username';
  }

  @override
  String get onboardStartSubtitle =>
      'Choose a model to get started. Tap New Chat anytime.';

  @override
  String get onboardStartBullet1 =>
      'Tap the model name in the top bar to switch models';

  @override
  String get onboardStartBullet2 => 'Use New Chat to reset context';

  @override
  String get onboardAttachTitle => 'Add context';

  @override
  String get onboardAttachSubtitle =>
      'Ground replies with content from Workspace or photos.';

  @override
  String get onboardAttachBullet1 => 'Workspace: PDFs, docs, datasets';

  @override
  String get onboardAttachBullet2 => 'Photos: camera or library';

  @override
  String get onboardSpeakTitle => 'Speak naturally';

  @override
  String get onboardSpeakSubtitle =>
      'Tap the mic to dictate with live waveform feedback.';

  @override
  String get onboardSpeakBullet1 => 'Stop anytime; partial text is preserved';

  @override
  String get onboardSpeakBullet2 => 'Great for quick notes or long prompts';

  @override
  String get onboardQuickTitle => 'Quick actions';

  @override
  String get onboardQuickSubtitle =>
      'Open the menu to switch between Chats, Workspace, and Profile.';

  @override
  String get onboardQuickBullet1 =>
      'Tap the menu to access Chats, Workspace, Profile';

  @override
  String get onboardQuickBullet2 =>
      'Start New Chat or manage models from the top bar';

  @override
  String get attachmentLabel => 'Attachment';

  @override
  String get tools => 'Tools';

  @override
  String get voiceInput => 'Voice input';

  @override
  String get voice => 'Voice';

  @override
  String get voiceStatusListening => 'Listening…';

  @override
  String get voiceStatusRecording => 'Recording…';

  @override
  String get voiceHoldToTalk => 'Hold to talk';

  @override
  String get voiceAutoSend => 'Auto-send';

  @override
  String get voiceTranscript => 'Transcript';

  @override
  String get voicePromptSpeakNow => 'Speak now…';

  @override
  String get voicePromptTapStart => 'Tap Start to begin';

  @override
  String get voiceActionStop => 'Stop';

  @override
  String get voiceActionStart => 'Start';

  @override
  String get voiceCallTitle => 'Voice Call';

  @override
  String get voiceCallPause => 'Pause';

  @override
  String get voiceCallResume => 'Resume';

  @override
  String get voiceCallStop => 'Stop';

  @override
  String get voiceCallEnd => 'End Call';

  @override
  String get voiceCallReady => 'Ready';

  @override
  String get voiceCallConnecting => 'Connecting...';

  @override
  String get voiceCallListening => 'Listening';

  @override
  String get voiceCallPaused => 'Paused';

  @override
  String get voiceCallProcessing => 'Thinking...';

  @override
  String get voiceCallSpeaking => 'Speaking';

  @override
  String get voiceCallDisconnected => 'Disconnected';

  @override
  String get voiceCallErrorHelp =>
      'Please check:\n• Microphone permissions are granted\n• Speech recognition is available on your device\n• You are connected to the server';

  @override
  String get messageInputLabel => 'Message input';

  @override
  String get messageInputHint => 'Type your message';

  @override
  String get messageHintText => 'Ask Conduit';

  @override
  String get stopGenerating => 'Stop generating';

  @override
  String get send => 'Send';

  @override
  String get codeCopiedToClipboard => 'Code copied to clipboard.';

  @override
  String get sendMessage => 'Send message';

  @override
  String get file => 'File';

  @override
  String get chooseDifferentFile => 'Choose Different File';

  @override
  String get photo => 'Photo';

  @override
  String get camera => 'Camera';

  @override
  String get apiUnavailable => 'API service not available';

  @override
  String get unableToLoadImage => 'Unable to load image';

  @override
  String notAnImageFile(String fileName) {
    return 'Not an image file: $fileName';
  }

  @override
  String failedToLoadImage(String error) {
    return 'Failed to load image: $error';
  }

  @override
  String get invalidDataUrl => 'Invalid data URL format';

  @override
  String get failedToDecodeImage => 'Failed to decode image';

  @override
  String get invalidImageFormat => 'Invalid image format';

  @override
  String get emptyImageData => 'Empty image data';

  @override
  String get confirm => 'Confirm';

  @override
  String get continueAction => 'Continue';

  @override
  String get cancel => 'Cancel';

  @override
  String get ok => 'OK';

  @override
  String get previousLabel => 'Prev';

  @override
  String get nextLabel => 'Next';

  @override
  String get inputField => 'Input field';

  @override
  String get checkConnection => 'Check Connection';

  @override
  String get openSettings => 'Open Settings';

  @override
  String get goBack => 'Go Back';

  @override
  String get technicalDetails => 'Technical Details';

  @override
  String requiredFieldLabel(String label) {
    return '$label *';
  }

  @override
  String get requiredFieldHelper => 'Required field';

  @override
  String get switchOnLabel => 'On';

  @override
  String get switchOffLabel => 'Off';

  @override
  String dialogSemanticLabel(String title) {
    return 'Dialog: $title';
  }

  @override
  String get save => 'Save';

  @override
  String get chooseModel => 'Choose Model';

  @override
  String get reviewerMode => 'REVIEWER MODE';

  @override
  String get selectLanguage => 'Select Language';

  @override
  String get newFolder => 'New Folder';

  @override
  String get folderName => 'Folder name';

  @override
  String get newChat => 'New Chat';

  @override
  String get more => 'More';

  @override
  String get clear => 'Clear';

  @override
  String get searchConversations => 'Search conversations...';

  @override
  String get create => 'Create';

  @override
  String get failedToCreateFolder => 'Failed to create folder';

  @override
  String get failedToMoveChat => 'Failed to move chat';

  @override
  String get failedToLoadChats => 'Failed to load chats';

  @override
  String get failedToUpdatePin => 'Failed to update pin';

  @override
  String get failedToDeleteChat => 'Failed to delete chat';

  @override
  String get manage => 'Manage';

  @override
  String get rename => 'Rename';

  @override
  String get delete => 'Delete';

  @override
  String get renameChat => 'Rename Chat';

  @override
  String get enterChatName => 'Enter chat name';

  @override
  String get failedToRenameChat => 'Failed to rename chat';

  @override
  String get failedToUpdateArchive => 'Failed to update archive';

  @override
  String get unarchive => 'Unarchive';

  @override
  String get archive => 'Archive';

  @override
  String get pin => 'Pin';

  @override
  String get unpin => 'Unpin';

  @override
  String get recent => 'Recent';

  @override
  String get system => 'System';

  @override
  String get english => 'English';

  @override
  String get deutsch => 'Deutsch';

  @override
  String get francais => 'Français';

  @override
  String get italiano => 'Italiano';

  @override
  String get espanol => 'Español';

  @override
  String get nederlands => 'Nederlands';

  @override
  String get russian => 'Русский';

  @override
  String get chinese => '中文';

  @override
  String get korean => '한국어';

  @override
  String get deleteMessagesTitle => 'Delete Messages';

  @override
  String deleteMessagesMessage(int count) {
    return 'Delete $count messages?';
  }

  @override
  String routeNotFound(String routeName) {
    return 'Route not found: $routeName';
  }

  @override
  String get deleteChatTitle => 'Delete Chat';

  @override
  String get deleteChatMessage => 'This chat will be permanently deleted.';

  @override
  String get deleteFolderTitle => 'Delete Folder';

  @override
  String get deleteFolderMessage =>
      'This folder and its assignment references will be removed.';

  @override
  String get failedToDeleteFolder => 'Failed to delete folder';

  @override
  String get aboutApp => 'About';

  @override
  String get aboutAppSubtitle => 'Conduit information and links';

  @override
  String get web => 'Web';

  @override
  String get imageGen => 'Image Gen';

  @override
  String get pinned => 'Pinned';

  @override
  String get folders => 'Folders';

  @override
  String get archived => 'Archived';

  @override
  String get appLanguage => 'App Language';

  @override
  String get darkMode => 'Dark Mode';

  @override
  String get webSearch => 'Web Search';

  @override
  String get webSearchDescription =>
      'Search the web and cite sources in replies.';

  @override
  String get imageGeneration => 'Image Generation';

  @override
  String get imageGenerationDescription => 'Create images from your prompts.';

  @override
  String get copy => 'Copy';

  @override
  String get ttsListen => 'Listen';

  @override
  String get ttsStop => 'Stop';

  @override
  String get edit => 'Edit';

  @override
  String get regenerate => 'Regenerate';

  @override
  String get noConversationsYet => 'No conversations yet';

  @override
  String get usernameOrEmailHint => 'Enter your username or email';

  @override
  String get passwordHint => 'Enter your password';

  @override
  String get enterApiKey => 'Enter your API key';

  @override
  String get signingIn => 'Signing in...';

  @override
  String get advancedSettings => 'Advanced Settings';

  @override
  String get customHeaders => 'Custom Headers';

  @override
  String get customHeadersDescription =>
      'Add custom HTTP headers for authentication, API keys, or special server requirements.';

  @override
  String get allowSelfSignedCertificates => 'Trust self-signed certificates';

  @override
  String get allowSelfSignedCertificatesDescription =>
      'Accept this server\'s TLS certificate even if it is self-signed. Enable only for servers you trust.';

  @override
  String get headerNameEmpty => 'Header name cannot be empty';

  @override
  String get headerNameTooLong => 'Header name too long (max 64 characters)';

  @override
  String get headerNameInvalidChars =>
      'Invalid header name. Use only letters, numbers, and these symbols: !#\$&-^_`|~';

  @override
  String headerNameReserved(String key) {
    return 'Cannot override reserved header \"$key\"';
  }

  @override
  String get headerValueEmpty => 'Header value cannot be empty';

  @override
  String get headerValueTooLong =>
      'Header value too long (max 1024 characters)';

  @override
  String get headerValueInvalidChars =>
      'Header value contains invalid characters. Use only printable ASCII.';

  @override
  String get headerValueUnsafe =>
      'Header value appears to contain potentially unsafe content';

  @override
  String headerAlreadyExists(String key) {
    return 'Header \"$key\" already exists. Remove it first to update.';
  }

  @override
  String get maxHeadersReachedDetail =>
      'Maximum of 10 custom headers allowed. Remove some to add more.';

  @override
  String get noModelsAvailable => 'No models available';

  @override
  String followingSystem(String theme) {
    return 'Following system: $theme';
  }

  @override
  String get themeDark => 'Dark';

  @override
  String get themePalette => 'Accent palette';

  @override
  String get themePaletteConduitLabel => 'Conduit';

  @override
  String get themePaletteConduitDescription =>
      'Clean neutral theme designed for Conduit.';

  @override
  String get themePaletteClaudeLabel => 'Claude';

  @override
  String get themePaletteClaudeDescription =>
      'Warm, tactile palette lifted from the Claude web client.';

  @override
  String get themePaletteT3ChatLabel => 'T3 Chat';

  @override
  String get themePaletteT3ChatDescription =>
      'Playful gradients inspired by the T3 Stack brand.';

  @override
  String get themePaletteCatppuccinLabel => 'Catppuccin';

  @override
  String get themePaletteCatppuccinDescription => 'Soft pastel palette.';

  @override
  String get themePaletteTangerineLabel => 'Tangerine';

  @override
  String get themePaletteTangerineDescription =>
      'Warm orange-and-slate palette.';

  @override
  String get themeLight => 'Light';

  @override
  String get currentlyUsingDarkTheme => 'Currently using Dark theme';

  @override
  String get currentlyUsingLightTheme => 'Currently using Light theme';

  @override
  String get aboutConduit => 'About Conduit';

  @override
  String versionLabel(String version, String build) {
    return 'Version: $version ($build)';
  }

  @override
  String get githubRepository => 'GitHub Repository';

  @override
  String get unableToLoadAppInfo => 'Unable to load app info';

  @override
  String get thinking => 'Thinking…';

  @override
  String get thoughts => 'Thoughts';

  @override
  String thoughtForDuration(String duration) {
    return 'Thought for $duration';
  }

  @override
  String get appCustomization => 'Customization';

  @override
  String get appCustomizationSubtitle =>
      'Theme, language, voice, and quickpills';

  @override
  String get quickActionsDescription => 'Quickpills in chat';

  @override
  String quickActionsSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count actions selected',
      one: '1 action selected',
      zero: 'No actions selected',
    );
    return '$_temp0';
  }

  @override
  String get autoSelectDescription => 'Let the app choose the best model';

  @override
  String get chatSettings => 'Chat';

  @override
  String get sendOnEnter => 'Send on Enter';

  @override
  String get sendOnEnterDescription =>
      'Enter sends (soft keyboard). Cmd/Ctrl+Enter also available';

  @override
  String get sttSettings => 'Speech to Text';

  @override
  String get sttEngineLabel => 'Recognition engine';

  @override
  String get sttEngineAuto => 'Auto';

  @override
  String get sttEngineDevice => 'On device';

  @override
  String get sttEngineServer => 'Server';

  @override
  String get sttEngineAutoDescription =>
      'Use on-device recognition when available and fall back to your server.';

  @override
  String get sttEngineDeviceDescription =>
      'Keep audio on this device. Voice input stops working if on-device speech recognition isn’t supported.';

  @override
  String get sttEngineServerDescription =>
      'Always send recordings to your OpenWebUI server for transcription.';

  @override
  String get sttDeviceUnavailableWarning =>
      'On-device speech recognition isn’t available on this device.';

  @override
  String get sttServerUnavailableWarning =>
      'Connect to a server with transcription enabled to use this option.';

  @override
  String get sttSilenceDuration => 'Silence Duration';

  @override
  String get sttSilenceDurationDescription =>
      'Time to wait after silence before auto-stopping recording';

  @override
  String get ttsEngineLabel => 'Engine';

  @override
  String get ttsEngineAuto => 'Auto';

  @override
  String get ttsEngineDevice => 'On device';

  @override
  String get ttsEngineServer => 'Server';

  @override
  String get ttsEngineAutoDescription =>
      'Use on-device speech when available and fall back to your server.';

  @override
  String get ttsEngineDeviceDescription =>
      'Keep synthesis on this device. Voice playback stops working if on-device TTS isn’t supported.';

  @override
  String get ttsEngineServerDescription =>
      'Always request audio from your OpenWebUI server.';

  @override
  String get ttsDeviceUnavailableWarning =>
      'On-device text-to-speech isn’t available on this device.';

  @override
  String get ttsServerUnavailableWarning =>
      'Connect to a server with text-to-speech enabled to use this option.';

  @override
  String get ttsSettings => 'Text to Speech';

  @override
  String get ttsVoice => 'Voice';

  @override
  String get ttsSpeechRate => 'Speech Rate';

  @override
  String get ttsPitch => 'Pitch';

  @override
  String get ttsVolume => 'Volume';

  @override
  String get ttsPreview => 'Preview Voice';

  @override
  String get ttsSystemDefault => 'System Default';

  @override
  String get ttsSelectVoice => 'Select Voice';

  @override
  String get ttsPreviewText => 'This is a preview of the selected voice.';

  @override
  String get ttsNoVoicesAvailable => 'No voices available';

  @override
  String ttsVoicesForLanguage(String language) {
    return '$language Voices';
  }

  @override
  String get ttsOtherVoices => 'Other Languages';

  @override
  String get error => 'Error';

  @override
  String errorWithMessage(String message) {
    return 'Error: $message';
  }

  @override
  String get networkTimeoutError =>
      'Connection timed out. Please check your internet connection and try again.';

  @override
  String get networkUnreachableError =>
      'Cannot reach the server. Please check your server URL and internet connection.';

  @override
  String get networkServerNotResponding =>
      'Server is not responding. Please verify the server is running and accessible.';

  @override
  String get networkGenericError =>
      'Network connection problem. Please check your internet connection.';

  @override
  String get serverError500 =>
      'Server is experiencing issues. This is usually temporary.';

  @override
  String get serverErrorUnavailable =>
      'Server is temporarily unavailable. Please try again in a moment.';

  @override
  String get serverErrorTimeout =>
      'Server took too long to respond. Please try again.';

  @override
  String get serverErrorGeneric =>
      'Server is having problems. Please try again later.';

  @override
  String get authSessionExpired =>
      'Your session has expired. Please sign in again.';

  @override
  String get authForbidden =>
      'You don\'t have permission to perform this action.';

  @override
  String get authInvalidToken =>
      'Authentication token is invalid. Please sign in again.';

  @override
  String get authGenericError =>
      'Authentication problem. Please sign in again.';

  @override
  String get validationInvalidEmail => 'Please enter a valid email address.';

  @override
  String get validationWeakPassword =>
      'Password doesn\'t meet requirements. Please check and try again.';

  @override
  String get validationMissingRequired => 'Please fill in all required fields.';

  @override
  String get validationFormatError =>
      'Some information is in the wrong format. Please check and try again.';

  @override
  String get validationGenericError => 'Please check your input and try again.';

  @override
  String get fileNotFound =>
      'File not found. It may have been moved or deleted.';

  @override
  String get fileAccessDenied =>
      'Cannot access the file. Please check permissions.';

  @override
  String get fileTooLarge => 'File is too large. Please choose a smaller file.';

  @override
  String get fileGenericError =>
      'Problem with the file. Please try a different file.';

  @override
  String get permissionCameraRequired =>
      'Camera permission is required. Please enable it in settings.';

  @override
  String get permissionStorageRequired =>
      'Storage permission is required. Please enable it in settings.';

  @override
  String get permissionMicrophoneRequired =>
      'Microphone permission is required. Please enable it in settings.';

  @override
  String get permissionGenericError =>
      'Permission required. Please check app permissions in settings.';

  @override
  String get actionRetryRequest => 'Try the request again.';

  @override
  String get actionVerifyConnection => 'Verify your internet connection.';

  @override
  String get actionRetryOperation => 'Retry the operation.';

  @override
  String get actionRetryAfterDelay => 'Wait a moment then try again.';

  @override
  String get actionSignInToAccount => 'Sign in to your account.';

  @override
  String get actionSelectAnotherFile => 'Select another file.';

  @override
  String get actionOpenAppSettings => 'Open app settings to grant permissions.';

  @override
  String get actionRetryAfterPermission => 'Retry after granting permission.';

  @override
  String get actionReturnToPrevious => 'Return to previous screen.';

  @override
  String get display => 'Display';

  @override
  String get realtime => 'Realtime';

  @override
  String get transportMode => 'Transport mode';

  @override
  String get mode => 'Mode';

  @override
  String get transportModePolling => 'Polling fallback';

  @override
  String get transportModeWs => 'WebSocket only';

  @override
  String get transportModePollingInfo =>
      'Falls back to HTTP polling when WebSocket is blocked. Upgrades to WebSocket when possible.';

  @override
  String get transportModeWsInfo =>
      'Lower overhead, but may fail behind strict proxies/firewalls.';
}
