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
  String get connectionIssueTitle => 'Impossibile raggiungere il server';

  @override
  String get connectionIssueSubtitle =>
      'Riconnettiti per continuare oppure esci per scegliere un server diverso.';

  @override
  String get connectionTimeout => 'Timeout di connessione';

  @override
  String get connectionTimeoutMessage =>
      'L\'app sta impiegando più tempo del previsto per connettersi. Potrebbe essere dovuto a una connessione lenta o a un timeout del server.';

  @override
  String get account => 'Account';

  @override
  String get supportConduit => 'Sostieni Conduit';

  @override
  String get supportConduitSubtitle =>
      'Mantieni Conduit indipendente finanziando lo sviluppo continuo.';

  @override
  String get githubSponsorsTitle => 'GitHub Sponsors';

  @override
  String get githubSponsorsSubtitle =>
      'Diventa sponsor ricorrente per supportare la roadmap.';

  @override
  String get buyMeACoffeeTitle => 'Buy Me a Coffee';

  @override
  String get buyMeACoffeeSubtitle =>
      'Fai una donazione una tantum per dire grazie.';

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
  String get modelCapabilityMultimodal => 'Multimodale';

  @override
  String get modelCapabilityReasoning => 'Ragionamento';

  @override
  String get noResults => 'Nessun risultato';

  @override
  String get searchModels => 'Cerca modelli...';

  @override
  String get errorMessage => 'Qualcosa è andato storto. Riprova.';

  @override
  String get closeButtonSemantic => 'Chiudi';

  @override
  String get loadingContent => 'Caricamento contenuto';

  @override
  String get loadingShort => 'Caricamento';

  @override
  String loadingAnnouncement(String message) {
    return 'Caricamento: $message';
  }

  @override
  String errorAnnouncement(String error) {
    return 'Errore: $error';
  }

  @override
  String errorAnnouncementWithSuggestion(String error, String suggestion) {
    return 'Errore: $error. $suggestion';
  }

  @override
  String successAnnouncement(String message) {
    return 'Operazione riuscita: $message';
  }

  @override
  String get noItems => 'Nessun elemento';

  @override
  String get noItemsToDisplay => 'Nessun elemento da visualizzare';

  @override
  String get knowledgeBase => 'Base di conoscenza';

  @override
  String get attachments => 'Allegati';

  @override
  String get takePhoto => 'Scatta una foto';

  @override
  String get document => 'Documento';

  @override
  String get backToServerSetup => 'Torna alla configurazione del server';

  @override
  String get connectedToServer => 'Connesso al server';

  @override
  String get signIn => 'Accedi';

  @override
  String get enterCredentials =>
      'Inserisci le credenziali per accedere alle conversazioni IA';

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
  String get enterServerAddress =>
      'Inserisci l\'indirizzo del server Open-WebUI per iniziare';

  @override
  String get serverUrl => 'URL del server';

  @override
  String get serverUrlHint => 'https://tuo-server.com';

  @override
  String get enterServerUrlSemantic =>
      'Inserisci l\'URL o l\'indirizzo IP del server';

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
  String get skipServerSetupTryDemo =>
      'Salta configurazione server e prova la demo';

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
  String get serverAddressRequired =>
      'Indirizzo server richiesto (es. 192.168.1.10 o example.com).';

  @override
  String get portRange => 'La porta deve essere tra 1 e 65535.';

  @override
  String get invalidIpFormat => 'Formato IP non valido. Esempio: 192.168.1.10.';

  @override
  String get couldNotConnectGeneric =>
      'Impossibile connettersi. Verifica l\'indirizzo e riprova.';

  @override
  String get weCouldntReachServer =>
      'Impossibile raggiungere il server. Verifica connessione e stato del server.';

  @override
  String get connectionTimedOut =>
      'Tempo scaduto. Il server potrebbe essere occupato o bloccato.';

  @override
  String get useHttpOrHttpsOnly => 'Usa solo http:// o https://.';

  @override
  String get loginFailed => 'Accesso non riuscito';

  @override
  String get invalidCredentials =>
      'Nome utente o password non validi. Riprova.';

  @override
  String get serverRedirectingHttps =>
      'Il server sta reindirizzando. Controlla la configurazione HTTPS.';

  @override
  String get unableToConnectServer =>
      'Impossibile connettersi al server. Controlla la connessione.';

  @override
  String get requestTimedOut => 'Richiesta scaduta. Riprova.';

  @override
  String get genericSignInFailed =>
      'Impossibile accedere. Controlla credenziali e server.';

  @override
  String get skip => 'Salta';

  @override
  String get next => 'Avanti';

  @override
  String get done => 'Fatto';

  @override
  String onboardStartTitle(String username) {
    return 'Ciao, $username';
  }

  @override
  String get onboardStartSubtitle =>
      'Scegli un modello per iniziare. Tocca Nuova chat in qualsiasi momento.';

  @override
  String get onboardStartBullet1 =>
      'Tocca il nome del modello in alto per cambiare';

  @override
  String get onboardStartBullet2 => 'Usa Nuova chat per azzerare il contesto';

  @override
  String get onboardAttachTitle => 'Aggiungi contesto';

  @override
  String get onboardAttachSubtitle =>
      'Collega le risposte a Workspace o alle foto.';

  @override
  String get onboardAttachBullet1 => 'Workspace: PDF, documenti, dataset';

  @override
  String get onboardAttachBullet2 => 'Foto: fotocamera o libreria';

  @override
  String get onboardSpeakTitle => 'Parla in modo naturale';

  @override
  String get onboardSpeakSubtitle =>
      'Tocca il microfono per dettare con feedback visivo.';

  @override
  String get onboardSpeakBullet1 =>
      'Interrompi in qualsiasi momento; il testo parziale viene mantenuto';

  @override
  String get onboardSpeakBullet2 => 'Ottimo per note rapide o prompt lunghi';

  @override
  String get onboardQuickTitle => 'Azioni rapide';

  @override
  String get onboardQuickSubtitle =>
      'Apri il menu per passare tra Chat, Workspace e Profilo.';

  @override
  String get onboardQuickBullet1 =>
      'Tocca il menu per accedere a Chat, Workspace, Profilo';

  @override
  String get onboardQuickBullet2 =>
      'Avvia Nuova chat o gestisci i modelli dalla barra';

  @override
  String get attachmentLabel => 'Allegato';

  @override
  String get tools => 'Strumenti';

  @override
  String get voiceInput => 'Input vocale';

  @override
  String get voice => 'Voce';

  @override
  String get voiceStatusListening => 'In ascolto…';

  @override
  String get voiceStatusRecording => 'Registrazione…';

  @override
  String get voiceHoldToTalk => 'Tieni premuto per parlare';

  @override
  String get voiceAutoSend => 'Invio automatico';

  @override
  String get voiceTranscript => 'Trascrizione';

  @override
  String get voicePromptSpeakNow => 'Parla ora…';

  @override
  String get voicePromptTapStart => 'Tocca \"Avvia\" per iniziare';

  @override
  String get voiceActionStop => 'Stop';

  @override
  String get voiceActionStart => 'Avvia';

  @override
  String get voiceCallTitle => 'Chiamata vocale';

  @override
  String get voiceCallPause => 'Pausa';

  @override
  String get voiceCallResume => 'Riprendi';

  @override
  String get voiceCallStop => 'Stop';

  @override
  String get voiceCallEnd => 'Termina chiamata';

  @override
  String get voiceCallReady => 'Pronto';

  @override
  String get voiceCallConnecting => 'Connessione...';

  @override
  String get voiceCallListening => 'In ascolto';

  @override
  String get voiceCallPaused => 'In pausa';

  @override
  String get voiceCallProcessing => 'Elaborazione...';

  @override
  String get voiceCallSpeaking => 'Sta parlando';

  @override
  String get voiceCallDisconnected => 'Disconnesso';

  @override
  String get voiceCallErrorHelp =>
      'Controlla:\n• Sono state concesse le autorizzazioni del microfono\n• Il riconoscimento vocale è disponibile sul dispositivo\n• Sei connesso al server';

  @override
  String get messageInputLabel => 'Input messaggio';

  @override
  String get messageInputHint => 'Scrivi il tuo messaggio';

  @override
  String get messageHintText => 'Chiedi a Conduit';

  @override
  String get stopGenerating => 'Interrompi generazione';

  @override
  String get send => 'Invia';

  @override
  String get codeCopiedToClipboard => 'Codice copiato negli appunti.';

  @override
  String get sendMessage => 'Invia messaggio';

  @override
  String get file => 'File';

  @override
  String get chooseDifferentFile => 'Scegli un altro file';

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
  String get confirm => 'Conferma';

  @override
  String get continueAction => 'Continua';

  @override
  String get cancel => 'Annulla';

  @override
  String get ok => 'OK';

  @override
  String get previousLabel => 'Precedente';

  @override
  String get nextLabel => 'Successivo';

  @override
  String get inputField => 'Campo di input';

  @override
  String get checkConnection => 'Controlla connessione';

  @override
  String get openSettings => 'Apri impostazioni';

  @override
  String get goBack => 'Indietro';

  @override
  String get technicalDetails => 'Dettagli tecnici';

  @override
  String requiredFieldLabel(String label) {
    return '$label *';
  }

  @override
  String get requiredFieldHelper => 'Campo obbligatorio';

  @override
  String get switchOnLabel => 'Attivo';

  @override
  String get switchOffLabel => 'Disattivo';

  @override
  String dialogSemanticLabel(String title) {
    return 'Dialogo: $title';
  }

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
  String get searchConversations => 'Cerca conversazioni...';

  @override
  String get create => 'Crea';

  @override
  String get failedToCreateFolder => 'Impossibile creare la cartella';

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
  String get nederlands => 'Olandese';

  @override
  String get russian => 'Russo';

  @override
  String get chinese => 'Cinese';

  @override
  String get korean => 'Coreano';

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
  String get deleteChatMessage =>
      'Questa chat verrà eliminata definitivamente.';

  @override
  String get deleteFolderTitle => 'Elimina cartella';

  @override
  String get deleteFolderMessage =>
      'Questa cartella e le sue associazioni verranno rimosse.';

  @override
  String get failedToDeleteFolder => 'Impossibile eliminare la cartella';

  @override
  String get aboutApp => 'Informazioni';

  @override
  String get aboutAppSubtitle => 'Informazioni e link di Conduit';

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
  String get ttsListen => 'Ascolta';

  @override
  String get ttsStop => 'Interrompi';

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
  String get customHeadersDescription =>
      'Aggiungi header HTTP personalizzati per autenticazione, chiavi API o requisiti speciali del server.';

  @override
  String get allowSelfSignedCertificates =>
      'Considera attendibili i certificati autofirmati';

  @override
  String get allowSelfSignedCertificatesDescription =>
      'Accetta il certificato TLS di questo server anche se è autofirmato. Attiva questa opzione solo per server di cui ti fidi.';

  @override
  String get headerNameEmpty => 'Il nome header non può essere vuoto';

  @override
  String get headerNameTooLong => 'Nome header troppo lungo (max 64 caratteri)';

  @override
  String get headerNameInvalidChars =>
      'Nome header non valido. Usa solo lettere, numeri e questi simboli: !#\$&-^_`|~';

  @override
  String headerNameReserved(String key) {
    return 'Impossibile sovrascrivere l\'header riservato \"$key\"';
  }

  @override
  String get headerValueEmpty => 'Il valore dell\'header non può essere vuoto';

  @override
  String get headerValueTooLong =>
      'Valore header troppo lungo (max 1024 caratteri)';

  @override
  String get headerValueInvalidChars =>
      'Il valore dell\'header contiene caratteri non validi. Usa solo ASCII stampabile.';

  @override
  String get headerValueUnsafe =>
      'Il valore dell\'header sembra contenere contenuti potenzialmente non sicuri';

  @override
  String headerAlreadyExists(String key) {
    return 'L\'header \"$key\" esiste già. Rimuovilo prima per aggiornarlo.';
  }

  @override
  String get maxHeadersReachedDetail =>
      'Massimo 10 header personalizzati consentiti. Rimuovine alcuni per aggiungerne altri.';

  @override
  String get noModelsAvailable => 'Nessun modello disponibile';

  @override
  String followingSystem(String theme) {
    return 'Segue il sistema: $theme';
  }

  @override
  String get themeDark => 'Scuro';

  @override
  String get themePalette => 'Palette di colori';

  @override
  String get themePaletteConduitLabel => 'Conduit';

  @override
  String get themePaletteConduitDescription =>
      'Tema neutro e pulito progettato per Conduit.';

  @override
  String get themePaletteClaudeLabel => 'Claude';

  @override
  String get themePaletteClaudeDescription =>
      'Palette calda e tattile ispirata al client web Claude.';

  @override
  String get themePaletteT3ChatLabel => 'T3 Chat';

  @override
  String get themePaletteT3ChatDescription =>
      'Sfumature vivaci ispirate al brand T3 Stack.';

  @override
  String get themePaletteCatppuccinLabel => 'Catppuccin';

  @override
  String get themePaletteCatppuccinDescription =>
      'Palette morbida di tonalità pastello.';

  @override
  String get themePaletteTangerineLabel => 'Tangerine';

  @override
  String get themePaletteTangerineDescription =>
      'Palette calda arancione e ardesia.';

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
  String get unableToLoadAppInfo =>
      'Impossibile caricare le informazioni dell\'app';

  @override
  String get thinking => 'Sta pensando…';

  @override
  String get thoughts => 'Pensieri';

  @override
  String thoughtForDuration(String duration) {
    return 'Ha pensato per $duration';
  }

  @override
  String get appCustomization => 'Personalizzazione';

  @override
  String get appCustomizationSubtitle => 'Tema, lingua, voce e quickpills';

  @override
  String get quickActionsDescription => 'Scorciatoie nella chat';

  @override
  String quickActionsSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count azioni selezionate',
      one: '$count azione selezionata',
      zero: 'Nessuna azione selezionata',
    );
    return '$_temp0';
  }

  @override
  String get autoSelectDescription =>
      'Lascia che l\'app scelga il modello migliore';

  @override
  String get chatSettings => 'Chat';

  @override
  String get sendOnEnter => 'Invia con Invio';

  @override
  String get sendOnEnterDescription =>
      'Invio invia (tastiera software). Cmd/Ctrl+Invio disponibile';

  @override
  String get sttSettings => 'Voce in testo';

  @override
  String get sttEngineLabel => 'Motore di riconoscimento';

  @override
  String get sttEngineAuto => 'Automatico';

  @override
  String get sttEngineDevice => 'Sul dispositivo';

  @override
  String get sttEngineServer => 'Server';

  @override
  String get sttEngineAutoDescription =>
      'Usa il riconoscimento sul dispositivo quando disponibile e altrimenti passa al tuo server.';

  @override
  String get sttEngineDeviceDescription =>
      'Mantiene l’audio su questo dispositivo. L’input vocale non funziona se il dispositivo non supporta il riconoscimento vocale.';

  @override
  String get sttEngineServerDescription =>
      'Invia sempre le registrazioni al tuo server OpenWebUI per la trascrizione.';

  @override
  String get sttDeviceUnavailableWarning =>
      'Il riconoscimento vocale sul dispositivo non è disponibile su questo dispositivo.';

  @override
  String get sttServerUnavailableWarning =>
      'Collegati a un server con la trascrizione abilitata per usare questa opzione.';

  @override
  String get sttSilenceDuration => 'Durata del silenzio';

  @override
  String get sttSilenceDurationDescription =>
      'Tempo di attesa dopo il silenzio prima di fermare automaticamente la registrazione';

  @override
  String get ttsEngineLabel => 'Motore';

  @override
  String get ttsEngineAuto => 'Automatico';

  @override
  String get ttsEngineDevice => 'Sul dispositivo';

  @override
  String get ttsEngineServer => 'Server';

  @override
  String get ttsEngineAutoDescription =>
      'Usa la sintesi sul dispositivo quando disponibile e altrimenti passa al tuo server.';

  @override
  String get ttsEngineDeviceDescription =>
      'Mantiene la sintesi su questo dispositivo. La riproduzione vocale non funziona se il dispositivo non supporta il TTS.';

  @override
  String get ttsEngineServerDescription =>
      'Richiede sempre l\'audio dal tuo server OpenWebUI.';

  @override
  String get ttsDeviceUnavailableWarning =>
      'La sintesi vocale sul dispositivo non è disponibile su questo dispositivo.';

  @override
  String get ttsServerUnavailableWarning =>
      'Collegati a un server con la sintesi vocale abilitata per usare questa opzione.';

  @override
  String get ttsSettings => 'Sintesi vocale';

  @override
  String get ttsVoice => 'Voce';

  @override
  String get ttsSpeechRate => 'Velocità di sintesi vocale';

  @override
  String get ttsPitch => 'Tonalità';

  @override
  String get ttsVolume => 'Volume';

  @override
  String get ttsPreview => 'Anteprima voce';

  @override
  String get ttsSystemDefault => 'Predefinito del sistema';

  @override
  String get ttsSelectVoice => 'Seleziona voce';

  @override
  String get ttsPreviewText => 'Questa è un\'anteprima della voce selezionata.';

  @override
  String get ttsNoVoicesAvailable => 'Nessuna voce disponibile';

  @override
  String ttsVoicesForLanguage(String language) {
    return 'Voci $language';
  }

  @override
  String get ttsOtherVoices => 'Altre lingue';

  @override
  String get error => 'Errore';

  @override
  String errorWithMessage(String message) {
    return 'Errore: $message';
  }

  @override
  String get networkTimeoutError =>
      'Connessione scaduta. Controlla la tua connessione Internet e riprova.';

  @override
  String get networkUnreachableError =>
      'Impossibile raggiungere il server. Controlla l\'URL del server e la connessione Internet.';

  @override
  String get networkServerNotResponding =>
      'Il server non risponde. Verifica che sia attivo e raggiungibile.';

  @override
  String get networkGenericError =>
      'Problema di connessione di rete. Controlla la connessione Internet.';

  @override
  String get serverError500 =>
      'Il server sta avendo problemi. Di solito è temporaneo.';

  @override
  String get serverErrorUnavailable =>
      'Il server è temporaneamente non disponibile. Riprova tra poco.';

  @override
  String get serverErrorTimeout =>
      'Il server ha impiegato troppo tempo a rispondere. Riprova.';

  @override
  String get serverErrorGeneric =>
      'Il server è in difficoltà. Riprova più tardi.';

  @override
  String get authSessionExpired => 'La sessione è scaduta. Accedi di nuovo.';

  @override
  String get authForbidden =>
      'Non hai l\'autorizzazione per eseguire questa azione.';

  @override
  String get authInvalidToken =>
      'Il token di autenticazione non è valido. Accedi di nuovo.';

  @override
  String get authGenericError => 'Problema di autenticazione. Accedi di nuovo.';

  @override
  String get validationInvalidEmail => 'Inserisci un indirizzo email valido.';

  @override
  String get validationWeakPassword =>
      'La password non soddisfa i requisiti. Controllala e riprova.';

  @override
  String get validationMissingRequired => 'Compila tutti i campi obbligatori.';

  @override
  String get validationFormatError =>
      'Alcune informazioni non sono nel formato corretto. Controllale e riprova.';

  @override
  String get validationGenericError => 'Controlla i dati inseriti e riprova.';

  @override
  String get fileNotFound =>
      'File non trovato. Potrebbe essere stato spostato o eliminato.';

  @override
  String get fileAccessDenied =>
      'Impossibile accedere al file. Controlla i permessi.';

  @override
  String get fileTooLarge =>
      'Il file è troppo grande. Scegline uno più piccolo.';

  @override
  String get fileGenericError =>
      'Problema con il file. Prova con un file diverso.';

  @override
  String get permissionCameraRequired =>
      'È necessario il permesso della fotocamera. Attivalo nelle impostazioni.';

  @override
  String get permissionStorageRequired =>
      'È necessario il permesso di archiviazione. Attivalo nelle impostazioni.';

  @override
  String get permissionMicrophoneRequired =>
      'È necessario il permesso del microfono. Attivalo nelle impostazioni.';

  @override
  String get permissionGenericError =>
      'È necessaria un\'autorizzazione. Controlla i permessi dell\'app nelle impostazioni.';

  @override
  String get actionRetryRequest => 'Riprova la richiesta.';

  @override
  String get actionVerifyConnection => 'Verifica la connessione a Internet.';

  @override
  String get actionRetryOperation => 'Riprova l\'operazione.';

  @override
  String get actionRetryAfterDelay => 'Attendi un momento e riprova.';

  @override
  String get actionSignInToAccount => 'Accedi al tuo account.';

  @override
  String get actionSelectAnotherFile => 'Seleziona un altro file.';

  @override
  String get actionOpenAppSettings =>
      'Apri le impostazioni dell\'app per concedere i permessi.';

  @override
  String get actionRetryAfterPermission =>
      'Riprova dopo aver concesso il permesso.';

  @override
  String get actionReturnToPrevious => 'Torna alla schermata precedente.';

  @override
  String get display => 'Schermo';

  @override
  String get realtime => 'Tempo reale';

  @override
  String get transportMode => 'Modalità di trasporto';

  @override
  String get mode => 'Modalità';

  @override
  String get transportModePolling => 'Polling di fallback';

  @override
  String get transportModeWs => 'Solo WebSocket';

  @override
  String get transportModePollingInfo =>
      'Quando WebSocket è bloccato passa a HTTP polling. Torna a WebSocket appena possibile.';

  @override
  String get transportModeWsInfo =>
      'Minore overhead, ma può fallire dietro proxy/firewall restrittivi.';
}
