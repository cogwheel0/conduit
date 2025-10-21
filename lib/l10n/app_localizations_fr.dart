// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'Conduit';

  @override
  String get initializationFailed => 'Échec de l\'initialisation';

  @override
  String get retry => 'Réessayer';

  @override
  String get back => 'Retour';

  @override
  String get you => 'Vous';

  @override
  String get loadingProfile => 'Chargement du profil...';

  @override
  String get unableToLoadProfile => 'Impossible de charger le profil';

  @override
  String get pleaseCheckConnection =>
      'Veuillez vérifier votre connexion et réessayer';

  @override
  String get connectionIssueTitle => 'Impossible d\'atteindre votre serveur';

  @override
  String get connectionIssueSubtitle =>
      'Reconnectez-vous pour continuer ou déconnectez-vous pour choisir un autre serveur.';

  @override
  String get stillOfflineMessage =>
      'Nous ne pouvons toujours pas joindre le serveur. Vérifiez votre connexion et réessayez.';

  @override
  String get account => 'Compte';

  @override
  String get supportConduit => 'Soutenir Conduit';

  @override
  String get supportConduitSubtitle =>
      'Financez le développement continu et les nouvelles fonctionnalités.';

  @override
  String get githubSponsorsTitle => 'GitHub Sponsors';

  @override
  String get githubSponsorsSubtitle =>
      'Devenez sponsor récurrent pour soutenir la feuille de route.';

  @override
  String get buyMeACoffeeTitle => 'Buy Me a Coffee';

  @override
  String get buyMeACoffeeSubtitle =>
      'Faites un don ponctuel pour nous encourager.';

  @override
  String get signOut => 'Se déconnecter';

  @override
  String get endYourSession => 'Terminer votre session';

  @override
  String get defaultModel => 'Modèle par défaut';

  @override
  String get autoSelect => 'Sélection automatique';

  @override
  String get loadingModels => 'Chargement des modèles...';

  @override
  String get failedToLoadModels => 'Échec du chargement des modèles';

  @override
  String get availableModels => 'Modèles disponibles';

  @override
  String get noResults => 'Aucun résultat';

  @override
  String get searchModels => 'Rechercher des modèles...';

  @override
  String get errorMessage => 'Une erreur s\'est produite. Veuillez réessayer.';

  @override
  String get loginButton => 'Connexion';

  @override
  String get menuItem => 'Paramètres';

  @override
  String dynamicContentWithPlaceholder(String name) {
    return 'Bienvenue, $name !';
  }

  @override
  String itemsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count éléments',
      one: '1 élément',
      zero: 'Aucun élément',
    );
    return '$_temp0';
  }

  @override
  String get closeButtonSemantic => 'Fermer';

  @override
  String get loadingContent => 'Chargement du contenu';

  @override
  String get noItems => 'Aucun élément';

  @override
  String get noItemsToDisplay => 'Aucun élément à afficher';

  @override
  String get loadMore => 'Charger plus';

  @override
  String get workspace => 'Espace de travail';

  @override
  String get recentFiles => 'Fichiers récents';

  @override
  String get knowledgeBase => 'Base de connaissances';

  @override
  String get noFilesYet => 'Pas encore de fichiers';

  @override
  String get uploadDocsPrompt =>
      'Importez des documents à utiliser dans vos conversations avec Conduit';

  @override
  String get uploadFirstFile => 'Importer votre premier fichier';

  @override
  String get attachments => 'Pièces jointes';

  @override
  String get knowledgeBaseEmpty => 'La base de connaissances est vide';

  @override
  String get createCollectionsPrompt =>
      'Créez des collections de documents liés pour une référence facile';

  @override
  String get chooseSourcePhoto => 'Choisir la source';

  @override
  String get takePhoto => 'Prendre une photo';

  @override
  String get chooseFromGallery => 'Choisir depuis vos photos';

  @override
  String get document => 'Document';

  @override
  String get documentHint => 'Fichier PDF, Word ou texte';

  @override
  String get uploadFileTitle => 'Importer un fichier';

  @override
  String fileUploadComingSoon(String type) {
    return 'Le téléversement de fichiers pour $type arrive bientôt !';
  }

  @override
  String get kbCreationComingSoon =>
      'La création de la base de connaissances arrive bientôt !';

  @override
  String get backToServerSetup => 'Retour à la configuration du serveur';

  @override
  String get connectedToServer => 'Connecté au serveur';

  @override
  String get signIn => 'Se connecter';

  @override
  String get enterCredentials =>
      'Entrez vos identifiants pour accéder à vos conversations IA';

  @override
  String get credentials => 'Identifiants';

  @override
  String get apiKey => 'Clé API';

  @override
  String get usernameOrEmail => 'Nom d\'utilisateur ou e‑mail';

  @override
  String get password => 'Mot de passe';

  @override
  String get signInWithApiKey => 'Se connecter avec une clé API';

  @override
  String get connectToServer => 'Se connecter au serveur';

  @override
  String get enterServerAddress =>
      'Saisissez l\'adresse de votre serveur Open-WebUI pour commencer';

  @override
  String get serverUrl => 'URL du serveur';

  @override
  String get serverUrlHint => 'https://votre-serveur.com';

  @override
  String get enterServerUrlSemantic =>
      'Saisissez l\'URL ou l\'adresse IP de votre serveur';

  @override
  String get headerName => 'Nom de l\'en-tête';

  @override
  String get headerValue => 'Valeur de l\'en-tête';

  @override
  String get headerValueHint => 'api-key-123 ou jeton Bearer';

  @override
  String get addHeader => 'Ajouter l\'en-tête';

  @override
  String get maximumHeadersReached => 'Nombre maximal atteint';

  @override
  String get removeHeader => 'Supprimer l\'en-tête';

  @override
  String get connecting => 'Connexion en cours...';

  @override
  String get connectToServerButton => 'Se connecter au serveur';

  @override
  String get demoModeActive => 'Mode démo activé';

  @override
  String get skipServerSetupTryDemo =>
      'Ignorer la configuration et essayer la démo';

  @override
  String get enterDemo => 'Entrer en démo';

  @override
  String get demoBadge => 'Démo';

  @override
  String get serverNotOpenWebUI =>
      'Ceci ne semble pas être un serveur Open-WebUI.';

  @override
  String get serverUrlEmpty => 'L\'URL du serveur ne peut pas être vide';

  @override
  String get invalidUrlFormat =>
      'Format d\'URL invalide. Veuillez vérifier votre saisie.';

  @override
  String get onlyHttpHttps =>
      'Seuls les protocoles HTTP et HTTPS sont pris en charge.';

  @override
  String get serverAddressRequired =>
      'Adresse du serveur requise (ex. 192.168.1.10 ou example.com).';

  @override
  String get portRange => 'Le port doit être compris entre 1 et 65535.';

  @override
  String get invalidIpFormat =>
      'Format d\'IP invalide. Exemple : 192.168.1.10.';

  @override
  String get couldNotConnectGeneric =>
      'Connexion impossible. Vérifiez l\'adresse et réessayez.';

  @override
  String get weCouldntReachServer =>
      'Impossible d\'atteindre le serveur. Vérifiez la connexion et l\'état du serveur.';

  @override
  String get connectionTimedOut =>
      'Délai d\'attente dépassé. Le serveur est peut-être occupé ou bloqué.';

  @override
  String get useHttpOrHttpsOnly => 'Utilisez uniquement http:// ou https://.';

  @override
  String get loginFailed => 'Échec de la connexion';

  @override
  String get invalidCredentials =>
      'Nom d\'utilisateur ou mot de passe invalide. Réessayez.';

  @override
  String get serverRedirectingHttps =>
      'Le serveur redirige les requêtes. Vérifiez la configuration HTTPS.';

  @override
  String get unableToConnectServer =>
      'Impossible de se connecter au serveur. Vérifiez votre connexion.';

  @override
  String get requestTimedOut => 'Délai d\'attente dépassé. Réessayez.';

  @override
  String get genericSignInFailed =>
      'Connexion impossible. Vérifiez vos identifiants et le serveur.';

  @override
  String get skip => 'Ignorer';

  @override
  String get next => 'Suivant';

  @override
  String get done => 'Terminé';

  @override
  String onboardStartTitle(String username) {
    return 'Bonjour, $username';
  }

  @override
  String get onboardStartSubtitle =>
      'Choisissez un modèle pour commencer. Touchez Nouveau chat à tout moment.';

  @override
  String get onboardStartBullet1 =>
      'Touchez le nom du modèle en haut pour changer';

  @override
  String get onboardStartBullet2 =>
      'Utilisez Nouveau chat pour réinitialiser le contexte';

  @override
  String get onboardAttachTitle => 'Ajouter du contexte';

  @override
  String get onboardAttachSubtitle =>
      'Ancrez les réponses avec l\'Espace de travail ou des photos.';

  @override
  String get onboardAttachBullet1 =>
      'Espace de travail : PDF, documents, jeux de données';

  @override
  String get onboardAttachBullet2 => 'Photos : appareil photo ou galerie';

  @override
  String get onboardSpeakTitle => 'Parlez naturellement';

  @override
  String get onboardSpeakSubtitle =>
      'Touchez le micro pour dicter avec retour visuel.';

  @override
  String get onboardSpeakBullet1 =>
      'Arrêtez à tout moment ; le texte partiel est conservé';

  @override
  String get onboardSpeakBullet2 =>
      'Idéal pour des notes rapides ou de longs prompts';

  @override
  String get onboardQuickTitle => 'Actions rapides';

  @override
  String get onboardQuickSubtitle =>
      'Ouvrez le menu pour passer entre Chats, Espace de travail et Profil.';

  @override
  String get onboardQuickBullet1 =>
      'Touchez le menu pour accéder à Chats, Espace, Profil';

  @override
  String get onboardQuickBullet2 =>
      'Lancez Nouveau chat ou gérez les modèles depuis la barre';

  @override
  String get addAttachment => 'Ajouter une pièce jointe';

  @override
  String get attachmentLabel => 'Pièce jointe';

  @override
  String get tools => 'Outils';

  @override
  String get voiceInput => 'Entrée vocale';

  @override
  String get voice => 'Voix';

  @override
  String get voiceStatusListening => 'Écoute…';

  @override
  String get voiceStatusRecording => 'Enregistrement…';

  @override
  String get voiceHoldToTalk => 'Maintenir pour parler';

  @override
  String get voiceAutoSend => 'Envoi automatique';

  @override
  String get voiceTranscript => 'Transcription';

  @override
  String get voicePromptSpeakNow => 'Parlez maintenant…';

  @override
  String get voicePromptTapStart => 'Appuyez sur \"Démarrer\" pour commencer';

  @override
  String get voiceActionStop => 'Arrêter';

  @override
  String get voiceActionStart => 'Démarrer';

  @override
  String get messageInputLabel => 'Saisie du message';

  @override
  String get messageInputHint => 'Saisissez votre message';

  @override
  String get messageHintText => 'Demander à Conduit';

  @override
  String get stopGenerating => 'Arrêter la génération';

  @override
  String get send => 'Envoyer';

  @override
  String get codeCopiedToClipboard => 'Code copié dans le presse-papiers.';

  @override
  String get sendMessage => 'Envoyer le message';

  @override
  String get file => 'Fichier';

  @override
  String get photo => 'Photo';

  @override
  String get camera => 'Appareil photo';

  @override
  String get apiUnavailable => 'Service API indisponible';

  @override
  String get unableToLoadImage => 'Impossible de charger l\'image';

  @override
  String notAnImageFile(String fileName) {
    return 'Ce n\'est pas un fichier image : $fileName';
  }

  @override
  String failedToLoadImage(String error) {
    return 'Échec du chargement de l\'image : $error';
  }

  @override
  String get invalidDataUrl => 'Format d\'URL de données invalide';

  @override
  String get failedToDecodeImage => 'Échec du décodage de l\'image';

  @override
  String get invalidImageFormat => 'Format d\'image invalide';

  @override
  String get emptyImageData => 'Données d\'image vides';

  @override
  String get featureRequiresInternet =>
      'Cette fonctionnalité nécessite une connexion Internet';

  @override
  String get messagesWillSendWhenOnline =>
      'Les messages seront envoyés lorsque vous serez de nouveau en ligne';

  @override
  String get confirm => 'Confirmer';

  @override
  String get cancel => 'Annuler';

  @override
  String get ok => 'OK';

  @override
  String get inputField => 'Champ de saisie';

  @override
  String get captureDocumentOrImage => 'Capturer un document ou une image';

  @override
  String get checkConnection => 'Vérifier la connexion';

  @override
  String get openSettings => 'Ouvrir les réglages';

  @override
  String get chooseDifferentFile => 'Choisir un autre fichier';

  @override
  String get goBack => 'Retour';

  @override
  String get technicalDetails => 'Détails techniques';

  @override
  String get save => 'Enregistrer';

  @override
  String get chooseModel => 'Choisir le modèle';

  @override
  String get reviewerMode => 'REVIEWER MODE';

  @override
  String get selectLanguage => 'Sélectionner la langue';

  @override
  String get newFolder => 'Nouveau dossier';

  @override
  String get folderName => 'Nom du dossier';

  @override
  String get newChat => 'Nouveau chat';

  @override
  String get more => 'Plus';

  @override
  String get clear => 'Effacer';

  @override
  String get searchHint => 'Rechercher...';

  @override
  String get searchConversations => 'Rechercher des conversations...';

  @override
  String get create => 'Créer';

  @override
  String get folderCreated => 'Dossier créé';

  @override
  String get failedToCreateFolder => 'Échec de la création du dossier';

  @override
  String movedChatToFolder(String title, String folder) {
    return '\"$title\" déplacé vers \"$folder\"';
  }

  @override
  String get failedToMoveChat => 'Échec du déplacement du chat';

  @override
  String get failedToLoadChats => 'Échec du chargement des chats';

  @override
  String get failedToUpdatePin => 'Échec de la mise à jour de l\'épingle';

  @override
  String get failedToDeleteChat => 'Échec de la suppression du chat';

  @override
  String get manage => 'Gérer';

  @override
  String get rename => 'Renommer';

  @override
  String get delete => 'Supprimer';

  @override
  String get renameChat => 'Renommer le chat';

  @override
  String get enterChatName => 'Saisir le nom du chat';

  @override
  String get failedToRenameChat => 'Échec du renommage du chat';

  @override
  String get failedToUpdateArchive => 'Échec de la mise à jour de l\'archive';

  @override
  String get unarchive => 'Désarchiver';

  @override
  String get archive => 'Archiver';

  @override
  String get pin => 'Épingler';

  @override
  String get unpin => 'Détacher';

  @override
  String get recent => 'Récent';

  @override
  String get system => 'Système';

  @override
  String get english => 'Anglais';

  @override
  String get deutsch => 'Allemand';

  @override
  String get francais => 'Français';

  @override
  String get italiano => 'Italien';

  @override
  String get espanol => 'Espagnol';

  @override
  String get nederlands => 'Néerlandais';

  @override
  String get russian => 'Russe';

  @override
  String get chinese => 'Chinois';

  @override
  String get korean => 'Coréen';

  @override
  String get deleteMessagesTitle => 'Supprimer les messages';

  @override
  String deleteMessagesMessage(int count) {
    return 'Supprimer $count messages ?';
  }

  @override
  String routeNotFound(String routeName) {
    return 'Route introuvable : $routeName';
  }

  @override
  String get deleteChatTitle => 'Supprimer le chat';

  @override
  String get deleteChatMessage => 'Ce chat sera supprimé définitivement.';

  @override
  String get deleteFolderTitle => 'Supprimer le dossier';

  @override
  String get deleteFolderMessage =>
      'Ce dossier et ses associations seront supprimés.';

  @override
  String get failedToDeleteFolder => 'Échec de la suppression du dossier';

  @override
  String get aboutApp => 'À propos';

  @override
  String get aboutAppSubtitle => 'Informations et liens Conduit';

  @override
  String get web => 'Web';

  @override
  String get imageGen => 'Gén. image';

  @override
  String get pinned => 'Épinglé';

  @override
  String get folders => 'Dossiers';

  @override
  String get archived => 'Archivé';

  @override
  String get appLanguage => 'Langue de l\'app';

  @override
  String get darkMode => 'Mode sombre';

  @override
  String get webSearch => 'Recherche Web';

  @override
  String get webSearchDescription =>
      'Recherchez sur le web et citez les sources.';

  @override
  String get imageGeneration => 'Génération d\'images';

  @override
  String get imageGenerationDescription =>
      'Créez des images à partir de vos prompts.';

  @override
  String get copy => 'Copier';

  @override
  String get ttsListen => 'Écouter';

  @override
  String get ttsStop => 'Arrêter';

  @override
  String get edit => 'Modifier';

  @override
  String get regenerate => 'Régénérer';

  @override
  String get noConversationsYet => 'Aucune conversation pour l\'instant';

  @override
  String get usernameOrEmailHint => 'Entrez votre nom d\'utilisateur ou e‑mail';

  @override
  String get passwordHint => 'Entrez votre mot de passe';

  @override
  String get enterApiKey => 'Entrez votre clé API';

  @override
  String get signingIn => 'Connexion en cours...';

  @override
  String get advancedSettings => 'Paramètres avancés';

  @override
  String get customHeaders => 'En-têtes personnalisés';

  @override
  String get customHeadersDescription =>
      'Ajoutez des en-têtes HTTP personnalisés pour l\'authentification, les clés API ou des exigences spécifiques du serveur.';

  @override
  String get allowSelfSignedCertificates =>
      'Faire confiance aux certificats auto-signés';

  @override
  String get allowSelfSignedCertificatesDescription =>
      'Acceptez le certificat TLS de ce serveur même s\'il est auto-signé. Activez cette option uniquement pour les serveurs auxquels vous faites confiance.';

  @override
  String get headerNameEmpty => 'Le nom de l\'en-tête ne peut pas être vide';

  @override
  String get headerNameTooLong =>
      'Nom d\'en-tête trop long (max 64 caractères)';

  @override
  String get headerNameInvalidChars =>
      'Nom d\'en-tête invalide. Utilisez uniquement des lettres, des chiffres et ces symboles : !#\$&-^_`|~';

  @override
  String headerNameReserved(String key) {
    return 'Impossible d\'écraser l\'en-tête réservé « $key »';
  }

  @override
  String get headerValueEmpty =>
      'La valeur de l\'en-tête ne peut pas être vide';

  @override
  String get headerValueTooLong =>
      'Valeur d\'en-tête trop longue (max 1024 caractères)';

  @override
  String get headerValueInvalidChars =>
      'La valeur de l\'en-tête contient des caractères invalides. Utilisez uniquement des caractères ASCII imprimables.';

  @override
  String get headerValueUnsafe =>
      'La valeur de l\'en-tête semble contenir du contenu potentiellement dangereux';

  @override
  String headerAlreadyExists(String key) {
    return 'L\'en-tête « $key » existe déjà. Supprimez-le d\'abord pour le modifier.';
  }

  @override
  String get maxHeadersReachedDetail =>
      'Maximum 10 en-têtes personnalisés. Supprimez-en pour en ajouter.';

  @override
  String get editMessage => 'Modifier le message';

  @override
  String get noModelsAvailable => 'Aucun modèle disponible';

  @override
  String followingSystem(String theme) {
    return 'Selon le système : $theme';
  }

  @override
  String get themeDark => 'Sombre';

  @override
  String get themePalette => 'Palette de couleurs';

  @override
  String get themePaletteDescription =>
      'Choisissez les couleurs d\'accent utilisées pour les boutons, les cartes et les bulles de discussion.';

  @override
  String get themeLight => 'Clair';

  @override
  String get currentlyUsingDarkTheme => 'Thème sombre actuellement utilisé';

  @override
  String get currentlyUsingLightTheme => 'Thème clair actuellement utilisé';

  @override
  String get aboutConduit => 'À propos de Conduit';

  @override
  String versionLabel(String version, String build) {
    return 'Version : $version ($build)';
  }

  @override
  String get githubRepository => 'Dépôt GitHub';

  @override
  String get unableToLoadAppInfo =>
      'Impossible de charger les informations de l\'application';

  @override
  String get thinking => 'Réflexion…';

  @override
  String get thoughts => 'Réflexions';

  @override
  String thoughtForDuration(String duration) {
    return 'A réfléchi pendant $duration';
  }

  @override
  String get appCustomization => 'Personnalisation';

  @override
  String get appCustomizationSubtitle => 'Thème, langue, voix et quickpills';

  @override
  String get quickActionsDescription => 'Raccourcis dans le chat';

  @override
  String get chatSettings => 'Discussion';

  @override
  String get sendOnEnter => 'Envoyer avec Entrée';

  @override
  String get sendOnEnterDescription =>
      'Entrée envoie (clavier logiciel). Cmd/Ctrl+Entrée aussi disponible';

  @override
  String get ttsSettings => 'Synthèse vocale';

  @override
  String get ttsVoice => 'Voix';

  @override
  String get ttsSpeechRate => 'Vitesse de parole';

  @override
  String get ttsPitch => 'Hauteur';

  @override
  String get ttsVolume => 'Volume';

  @override
  String get ttsPreview => 'Aperçu de la voix';

  @override
  String get ttsSystemDefault => 'Système par défaut';

  @override
  String get ttsSelectVoice => 'Sélectionner la voix';

  @override
  String get ttsPreviewText => 'Ceci est un aperçu de la voix sélectionnée.';

  @override
  String get ttsNoVoicesAvailable => 'Aucune voix disponible';

  @override
  String ttsVoicesForLanguage(String language) {
    return 'Voix $language';
  }

  @override
  String get ttsOtherVoices => 'Autres langues';

  @override
  String get error => 'Erreur';

  @override
  String get display => 'Affichage';

  @override
  String get realtime => 'Temps réel';

  @override
  String get transportMode => 'Mode de transport';

  @override
  String get transportModeDescription =>
      'Choisissez comment l\'app se connecte pour les mises à jour en temps réel.';

  @override
  String get mode => 'Mode';

  @override
  String get transportModeAuto => 'Auto (Polling + WebSocket)';

  @override
  String get transportModeWs => 'WebSocket uniquement';

  @override
  String get transportModeAutoInfo =>
      'Plus robuste sur les réseaux restrictifs. Passe à WebSocket lorsque possible.';

  @override
  String get transportModeWsInfo =>
      'Moins de surcharge, mais peut échouer derrière des proxys/firewalls stricts.';
}
