// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Italian (`it`).
class AppLocalizationsIt extends AppLocalizations {
  AppLocalizationsIt([String locale = 'it']) : super(locale);

  @override
  String get appTitle => 'Conduit';

  @override
  String get initializationFailed => 'Inizializzazione non riuscita';

  @override
  String get retry => 'Riprova';

  @override
  String get back => 'Indietro';

  @override
  String get you => 'Tu';

  @override
  String get loadingProfile => 'Caricamento profilo...';

  @override
  String get unableToLoadProfile => 'Impossibile caricare il profilo';

  @override
  String get pleaseCheckConnection => 'Controlla la connessione e riprova';

  @override
  String get account => 'Account';

  @override
  String get signOut => 'Esci';

  @override
  String get endYourSession => 'Termina la sessione';

  @override
  String get defaultModel => 'Modello predefinito';

  @override
  String get autoSelect => 'Selezione automatica';

  @override
  String get loadingModels => 'Caricamento modelli...';

  @override
  String get failedToLoadModels => 'Impossibile caricare i modelli';

  @override
  String get availableModels => 'Modelli disponibili';

  @override
  String get noResults => 'Nessun risultato';

  @override
  String get searchModels => 'Cerca modelli...';

  @override
  String get errorMessage => 'Qualcosa è andato storto. Riprova.';

  @override
  String get loginButton => 'Accedi';

  @override
  String get menuItem => 'Impostazioni';

  @override
  String dynamicContentWithPlaceholder(String name) {
    return 'Benvenuto, $name!';
  }

  @override
  String itemsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count elementi',
      one: '1 elemento',
      zero: 'Nessun elemento',
    );
    return '$_temp0';
  }

  @override
  String get closeButtonSemantic => 'Chiudi';

  @override
  String get loadingContent => 'Caricamento contenuto';

  @override
  String get noItems => 'Nessun elemento';

  @override
  String get noItemsToDisplay => 'Nessun elemento da visualizzare';

  @override
  String get loadMore => 'Carica altro';

  @override
  String get workspace => 'Spazio di lavoro';

  @override
  String get recentFiles => 'File recenti';

  @override
  String get knowledgeBase => 'Base di conoscenza';

  @override
  String get noFilesYet => 'Ancora nessun file';

  @override
  String get uploadDocsPrompt => 'Carica documenti da usare nelle conversazioni con Conduit';

  @override
  String get uploadFirstFile => 'Carica il tuo primo file';

  @override
  String get knowledgeBaseEmpty => 'La base di conoscenza è vuota';

  @override
  String get createCollectionsPrompt => 'Crea raccolte di documenti correlati per un rapido riferimento';

  @override
  String get chooseSourcePhoto => 'Scegli origine';

  @override
  String get takePhoto => 'Scatta una foto';

  @override
  String get chooseFromGallery => 'Scegli dalle foto';

  @override
  String get document => 'Documento';

  @override
  String get documentHint => 'File PDF, Word o di testo';

  @override
  String get uploadFileTitle => 'Carica file';

  @override
  String fileUploadComingSoon(String type) {
    return 'Il caricamento file per $type arriverà presto!';
  }

  @override
  String get kbCreationComingSoon => 'La creazione della base di conoscenza arriverà presto!';

  @override
  String get backToServerSetup => 'Torna alla configurazione del server';

  @override
  String get connectedToServer => 'Connesso al server';

  @override
  String get signIn => 'Accedi';

  @override
  String get enterCredentials => 'Inserisci le credenziali per accedere alle conversazioni IA';

  @override
  String get credentials => 'Credenziali';

  @override
  String get apiKey => 'Chiave API';

  @override
  String get usernameOrEmail => 'Username o e‑mail';

  @override
  String get password => 'Password';

  @override
  String get signInWithApiKey => 'Accedi con chiave API';

  @override
  String get connectToServer => 'Connetti al server';

  @override
  String get enterServerAddress => 'Inserisci l\'indirizzo del server Open-WebUI per iniziare';

  @override
  String get serverUrl => 'URL del server';

  @override
  String get serverUrlHint => 'https://tuo-server.com';

  @override
  String get enterServerUrlSemantic => 'Inserisci l\'URL o l\'indirizzo IP del server';

  @override
  String get headerName => 'Nome header';

  @override
  String get headerValue => 'Valore header';

  @override
  String get headerValueHint => 'api-key-123 o token Bearer';

  @override
  String get addHeader => 'Aggiungi header';

  @override
  String get maximumHeadersReached => 'Numero massimo raggiunto';

  @override
  String get removeHeader => 'Rimuovi header';

  @override
  String get connecting => 'Connessione in corso...';

  @override
  String get connectToServerButton => 'Connetti al server';

  @override
  String get demoModeActive => 'Modalità demo attiva';

  @override
  String get skipServerSetupTryDemo => 'Salta configurazione server e prova la demo';

  @override
  String get enterDemo => 'Entra in demo';

  @override
  String get demoBadge => 'Demo';

  @override
  String get serverNotOpenWebUI => 'Questo non sembra un server Open-WebUI.';

  @override
  String get serverUrlEmpty => 'L\'URL del server non può essere vuoto';

  @override
  String get invalidUrlFormat => 'Formato URL non valido. Controlla l\'input.';

  @override
  String get onlyHttpHttps => 'Sono supportati solo i protocolli HTTP e HTTPS.';

  @override
  String get serverAddressRequired => 'Indirizzo server richiesto (es. 192.168.1.10 o example.com).';

  @override
  String get portRange => 'La porta deve essere tra 1 e 65535.';

  @override
  String get invalidIpFormat => 'Formato IP non valido. Esempio: 192.168.1.10.';

  @override
  String get couldNotConnectGeneric => 'Impossibile connettersi. Verifica l\'indirizzo e riprova.';

  @override
  String get weCouldntReachServer => 'Impossibile raggiungere il server. Verifica connessione e stato del server.';

  @override
  String get connectionTimedOut => 'Tempo scaduto. Il server potrebbe essere occupato o bloccato.';

  @override
  String get useHttpOrHttpsOnly => 'Usa solo http:// o https://.';

  @override
  String get loginFailed => 'Accesso non riuscito';

  @override
  String get invalidCredentials => 'Nome utente o password non validi. Riprova.';

  @override
  String get serverRedirectingHttps => 'Il server sta reindirizzando. Controlla la configurazione HTTPS.';

  @override
  String get unableToConnectServer => 'Impossibile connettersi al server. Controlla la connessione.';

  @override
  String get requestTimedOut => 'Richiesta scaduta. Riprova.';

  @override
  String get genericSignInFailed => 'Impossibile accedere. Controlla credenziali e server.';

  @override
  String get skip => 'Salta';

  @override
  String get next => 'Avanti';

  @override
  String get done => 'Fatto';

  @override
  String get onboardStartTitle => 'Inizia una conversazione';

  @override
  String get onboardStartSubtitle => 'Scegli un modello e inizia a scrivere. Tocca Nuova chat in qualsiasi momento.';

  @override
  String get onboardStartBullet1 => 'Tocca il nome del modello in alto per cambiare';

  @override
  String get onboardStartBullet2 => 'Usa Nuova chat per azzerare il contesto';

  @override
  String get onboardAttachTitle => 'Aggiungi contesto';

  @override
  String get onboardAttachSubtitle => 'Collega le risposte a Workspace o alle foto.';

  @override
  String get onboardAttachBullet1 => 'Workspace: PDF, documenti, dataset';

  @override
  String get onboardAttachBullet2 => 'Foto: fotocamera o libreria';

  @override
  String get onboardSpeakTitle => 'Parla in modo naturale';

  @override
  String get onboardSpeakSubtitle => 'Tocca il microfono per dettare con feedback visivo.';

  @override
  String get onboardSpeakBullet1 => 'Interrompi in qualsiasi momento; il testo parziale viene mantenuto';

  @override
  String get onboardSpeakBullet2 => 'Ottimo per note rapide o prompt lunghi';

  @override
  String get onboardQuickTitle => 'Azioni rapide';

  @override
  String get onboardQuickSubtitle => 'Apri il menu per passare tra Chat, Workspace e Profilo.';

  @override
  String get onboardQuickBullet1 => 'Tocca il menu per accedere a Chat, Workspace, Profilo';

  @override
  String get onboardQuickBullet2 => 'Avvia Nuova chat o gestisci i modelli dalla barra';

  @override
  String get addAttachment => 'Aggiungi allegato';

  @override
  String get tools => 'Strumenti';

  @override
  String get voiceInput => 'Input vocale';

  @override
  String get messageInputLabel => 'Input messaggio';

  @override
  String get messageInputHint => 'Scrivi il tuo messaggio';

  @override
  String get messageHintText => 'Messaggio...';

  @override
  String get stopGenerating => 'Interrompi generazione';

  @override
  String get send => 'Invia';

  @override
  String get sendMessage => 'Invia messaggio';

  @override
  String get file => 'File';

  @override
  String get photo => 'Foto';

  @override
  String get camera => 'Fotocamera';

  @override
  String get apiUnavailable => 'Servizio API non disponibile';

  @override
  String get unableToLoadImage => 'Impossibile caricare l\'immagine';

  @override
  String notAnImageFile(String fileName) {
    return 'Non è un file immagine: $fileName';
  }

  @override
  String failedToLoadImage(String error) {
    return 'Impossibile caricare l\'immagine: $error';
  }

  @override
  String get invalidDataUrl => 'Formato data URL non valido';

  @override
  String get failedToDecodeImage => 'Impossibile decodificare l\'immagine';

  @override
  String get invalidImageFormat => 'Formato immagine non valido';

  @override
  String get emptyImageData => 'Dati immagine vuoti';

  @override
  String get offlineBanner => 'Sei offline. Alcune funzioni potrebbero essere limitate.';

  @override
  String get featureRequiresInternet => 'Questa funzione richiede una connessione Internet';

  @override
  String get messagesWillSendWhenOnline => 'I messaggi verranno inviati quando tornerai online';

  @override
  String get confirm => 'Conferma';

  @override
  String get cancel => 'Annulla';

  @override
  String get ok => 'OK';

  @override
  String get inputField => 'Campo di input';

  @override
  String get captureDocumentOrImage => 'Acquisisci un documento o un\'immagine';

  @override
  String get checkConnection => 'Controlla connessione';

  @override
  String get openSettings => 'Apri impostazioni';

  @override
  String get chooseDifferentFile => 'Scegli un altro file';

  @override
  String get goBack => 'Indietro';

  @override
  String get technicalDetails => 'Dettagli tecnici';

  @override
  String get save => 'Salva';

  @override
  String get chooseModel => 'Scegli modello';

  @override
  String get reviewerMode => 'REVIEWER MODE';

  @override
  String get selectLanguage => 'Seleziona lingua';

  @override
  String get newFolder => 'Nuova cartella';

  @override
  String get folderName => 'Nome cartella';

  @override
  String get newChat => 'Nuova chat';

  @override
  String get more => 'Altro';

  @override
  String get clear => 'Pulisci';

  @override
  String get searchHint => 'Cerca...';

  @override
  String get searchConversations => 'Cerca conversazioni...';

  @override
  String get create => 'Crea';

  @override
  String get folderCreated => 'Cartella creata';

  @override
  String get failedToCreateFolder => 'Impossibile creare la cartella';

  @override
  String movedChatToFolder(String title, String folder) {
    return '\"$title\" spostata in \"$folder\"';
  }

  @override
  String get failedToMoveChat => 'Impossibile spostare la chat';

  @override
  String get failedToLoadChats => 'Impossibile caricare le chat';

  @override
  String get failedToUpdatePin => 'Impossibile aggiornare il pin';

  @override
  String get failedToDeleteChat => 'Impossibile eliminare la chat';

  @override
  String get manage => 'Gestisci';

  @override
  String get rename => 'Rinomina';

  @override
  String get delete => 'Elimina';

  @override
  String get renameChat => 'Rinomina chat';

  @override
  String get enterChatName => 'Inserisci nome chat';

  @override
  String get failedToRenameChat => 'Impossibile rinominare la chat';

  @override
  String get failedToUpdateArchive => 'Impossibile aggiornare l\'archivio';

  @override
  String get unarchive => 'Ripristina';

  @override
  String get archive => 'Archivia';

  @override
  String get pin => 'Fissa';

  @override
  String get unpin => 'Sblocca';

  @override
  String get recent => 'Recenti';

  @override
  String get system => 'Sistema';

  @override
  String get english => 'Inglese';

  @override
  String get deutsch => 'Tedesco';

  @override
  String get francais => 'Francese';

  @override
  String get italiano => 'Italiano';

  @override
  String get espanol => 'Spagnolo';

  @override
  String get deleteMessagesTitle => 'Elimina messaggi';

  @override
  String deleteMessagesMessage(int count) {
    return 'Eliminare $count messaggi?';
  }

  @override
  String routeNotFound(String routeName) {
    return 'Percorso non trovato: $routeName';
  }

  @override
  String get deleteChatTitle => 'Elimina chat';

  @override
  String get deleteChatMessage => 'Questa chat verrà eliminata definitivamente.';

  @override
  String get aboutApp => 'Informazioni sull\'app';

  @override
  String get aboutAppSubtitle => 'Informazioni e link di Conduit';

  @override
  String get typeBelowToBegin => 'Scrivi qui sotto per iniziare';

  @override
  String get web => 'Web';

  @override
  String get imageGen => 'Gen. immagini';

  @override
  String get pinned => 'Fissati';

  @override
  String get folders => 'Cartelle';

  @override
  String get archived => 'Archiviati';

  @override
  String get appLanguage => 'Lingua app';

  @override
  String get darkMode => 'Modalità scura';

  @override
  String get webSearch => 'Ricerca Web';

  @override
  String get webSearchDescription => 'Cerca sul web e cita le fonti.';

  @override
  String get imageGeneration => 'Generazione immagini';

  @override
  String get imageGenerationDescription => 'Crea immagini dai tuoi prompt.';

  @override
  String get copy => 'Copia';

  @override
  String get edit => 'Modifica';

  @override
  String get regenerate => 'Rigenera';

  @override
  String get noConversationsYet => 'Ancora nessuna conversazione';

  @override
  String get usernameOrEmailHint => 'Inserisci il tuo username o e‑mail';

  @override
  String get passwordHint => 'Inserisci la password';

  @override
  String get enterApiKey => 'Inserisci la tua chiave API';

  @override
  String get signingIn => 'Accesso in corso...';

  @override
  String get advancedSettings => 'Impostazioni avanzate';

  @override
  String get customHeaders => 'Header personalizzati';

  @override
  String get customHeadersDescription => 'Aggiungi header HTTP personalizzati per autenticazione, chiavi API o requisiti speciali del server.';

  @override
  String get headerNameEmpty => 'Il nome header non può essere vuoto';

  @override
  String get headerNameTooLong => 'Nome header troppo lungo (max 64 caratteri)';

  @override
  String get headerNameInvalidChars => 'Nome header non valido. Usa solo lettere, numeri e questi simboli: !#\$&-^_`|~';

  @override
  String headerNameReserved(String key) {
    return 'Impossibile sovrascrivere l\'header riservato \"$key\"';
  }

  @override
  String get headerValueEmpty => 'Il valore dell\'header non può essere vuoto';

  @override
  String get headerValueTooLong => 'Valore header troppo lungo (max 1024 caratteri)';

  @override
  String get headerValueInvalidChars => 'Il valore dell\'header contiene caratteri non validi. Usa solo ASCII stampabile.';

  @override
  String get headerValueUnsafe => 'Il valore dell\'header sembra contenere contenuti potenzialmente non sicuri';

  @override
  String headerAlreadyExists(String key) {
    return 'L\'header \"$key\" esiste già. Rimuovilo prima per aggiornarlo.';
  }

  @override
  String get maxHeadersReachedDetail => 'Massimo 10 header personalizzati consentiti. Rimuovine alcuni per aggiungerne altri.';

  @override
  String get editMessage => 'Modifica messaggio';

  @override
  String get noModelsAvailable => 'Nessun modello disponibile';

  @override
  String followingSystem(String theme) {
    return 'Segue il sistema: $theme';
  }

  @override
  String get themeDark => 'Scuro';

  @override
  String get themeLight => 'Chiaro';

  @override
  String get currentlyUsingDarkTheme => 'Attualmente tema scuro';

  @override
  String get currentlyUsingLightTheme => 'Attualmente tema chiaro';

  @override
  String get aboutConduit => 'Informazioni su Conduit';

  @override
  String versionLabel(String version, String build) {
    return 'Versione: $version ($build)';
  }

  @override
  String get githubRepository => 'Repository GitHub';

  @override
  String get unableToLoadAppInfo => 'Impossibile caricare le informazioni dell\'app';

  @override
  String get thinking => 'Sta pensando…';

  @override
  String get thoughts => 'Pensieri';

  @override
  String thoughtForDuration(String duration) {
    return 'Ha pensato per $duration';
  }

  @override
  String get ttsLanguage => 'Lingua TTS';

  @override
  String get ttsLanguageDescription => 'Scegli la lingua per la sintesi vocale';

  @override
  String get listen => 'Ascolta';

  @override
  String get stop => 'Ferma';
}
