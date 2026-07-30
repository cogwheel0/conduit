import '../../core/models/model.dart';
import '../direct_connections/models/direct_connection_profile.dart';
import '../direct_connections/services/direct_model_registry.dart';

const bool kChatGptAccountEnabled = bool.fromEnvironment(
  'CHATGPT_ACCOUNT_DIRECT',
  defaultValue: true,
);

const String kChatGptAccountAdapterKey = 'chatgpt-account';
const String kChatGptAccountProfileId = 'chatgpt-account';
const String kChatGptAccountBaseUrl = 'https://chatgpt.com';

bool isCanonicalChatGptAccountProfile(DirectConnectionProfile profile) =>
    profile.id == kChatGptAccountProfileId &&
    profile.adapterKey == kChatGptAccountAdapterKey &&
    profile.baseUrl == kChatGptAccountBaseUrl &&
    profile.apiKey == null &&
    profile.customHeaders.isEmpty &&
    !profile.allowSelfSignedCertificates &&
    profile.manualModelIds.isEmpty;

bool isChatGptAccountProfile(DirectConnectionProfile profile) =>
    profile.adapterKey == kChatGptAccountAdapterKey;

bool isChatGptAccountModel(Model model) =>
    isLocallyMintedDirectModelForAdapter(model, kChatGptAccountAdapterKey);

bool isUserConfiguredDirectModel(Model model) =>
    isLocallyMintedDirectModel(model) && !isChatGptAccountModel(model);
