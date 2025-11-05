// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for German (`de`).
class AppLocalizationsDe extends AppLocalizations {
  AppLocalizationsDe([String locale = 'de']) : super(locale);

  @override
  String get appTitle => 'Conduit';

  @override
  String get retry => 'Erneut versuchen';

  @override
  String get back => 'Zurück';

  @override
  String get you => 'Du';

  @override
  String get loadingProfile => 'Profil wird geladen...';

  @override
  String get unableToLoadProfile => 'Profil konnte nicht geladen werden';

  @override
  String get pleaseCheckConnection =>
      'Bitte überprüfe deine Verbindung und versuche es erneut';

  @override
  String get connectionIssueTitle => 'Server nicht erreichbar';

  @override
  String get connectionIssueSubtitle =>
      'Verbindung wiederherstellen oder abmelden, um einen anderen Server zu wählen.';

  @override
  String get connectionTimeout => 'Verbindungszeitüberschreitung';

  @override
  String get connectionTimeoutMessage =>
      'Die App benötigt länger als erwartet zum Verbinden. Dies könnte an einer langsamen Verbindung oder einem Server-Timeout liegen.';

  @override
  String get account => 'Konto';

  @override
  String get supportConduit => 'Conduit unterstützen';

  @override
  String get supportConduitSubtitle =>
      'Hilf, die Weiterentwicklung und neue Funktionen zu finanzieren.';

  @override
  String get githubSponsorsTitle => 'GitHub Sponsors';

  @override
  String get githubSponsorsSubtitle =>
      'Werde monatliche*r Sponsor*in und unterstütze die Roadmap.';

  @override
  String get buyMeACoffeeTitle => 'Buy Me a Coffee';

  @override
  String get buyMeACoffeeSubtitle =>
      'Bedanke dich mit einer einmaligen Spende.';

  @override
  String get signOut => 'Abmelden';

  @override
  String get endYourSession => 'Sitzung beenden';

  @override
  String get defaultModel => 'Standardmodell';

  @override
  String get autoSelect => 'Automatische Auswahl';

  @override
  String get loadingModels => 'Modelle werden geladen...';

  @override
  String get failedToLoadModels => 'Modelle konnten nicht geladen werden';

  @override
  String get availableModels => 'Verfügbare Modelle';

  @override
  String get modelCapabilityMultimodal => 'Multimodal';

  @override
  String get modelCapabilityReasoning => 'Reasoning';

  @override
  String get noResults => 'Keine Ergebnisse';

  @override
  String get searchModels => 'Modelle suchen...';

  @override
  String get errorMessage =>
      'Etwas ist schief gelaufen. Bitte versuche es erneut.';

  @override
  String get closeButtonSemantic => 'Schließen';

  @override
  String get loadingContent => 'Inhalt wird geladen';

  @override
  String get loadingShort => 'Laden';

  @override
  String loadingAnnouncement(String message) {
    return 'Laden: $message';
  }

  @override
  String errorAnnouncement(String error) {
    return 'Fehler: $error';
  }

  @override
  String errorAnnouncementWithSuggestion(String error, String suggestion) {
    return 'Fehler: $error. $suggestion';
  }

  @override
  String successAnnouncement(String message) {
    return 'Erfolg: $message';
  }

  @override
  String get noItems => 'Keine Elemente';

  @override
  String get noItemsToDisplay => 'Keine Elemente zum Anzeigen';

  @override
  String get knowledgeBase => 'Wissensdatenbank';

  @override
  String get attachments => 'Anhänge';

  @override
  String get takePhoto => 'Foto aufnehmen';

  @override
  String get document => 'Dokument';

  @override
  String get backToServerSetup => 'Zur Servereinrichtung zurück';

  @override
  String get connectedToServer => 'Mit Server verbunden';

  @override
  String get signIn => 'Anmelden';

  @override
  String get enterCredentials =>
      'Gib deine Anmeldedaten ein, um auf deine KI-Unterhaltungen zuzugreifen';

  @override
  String get credentials => 'Zugangsdaten';

  @override
  String get apiKey => 'API-Schlüssel';

  @override
  String get usernameOrEmail => 'Benutzername oder E‑Mail';

  @override
  String get password => 'Passwort';

  @override
  String get signInWithApiKey => 'Mit API-Schlüssel anmelden';

  @override
  String get connectToServer => 'Mit Server verbinden';

  @override
  String get enterServerAddress =>
      'Gib die Adresse deines Open-WebUI-Servers ein, um zu beginnen';

  @override
  String get serverUrl => 'Server-URL';

  @override
  String get serverUrlHint => 'https://dein-server.com';

  @override
  String get enterServerUrlSemantic =>
      'Gib deine Server-URL oder IP-Adresse ein';

  @override
  String get headerName => 'Header-Name';

  @override
  String get headerValue => 'Header-Wert';

  @override
  String get headerValueHint => 'api-key-123 oder Bearer-Token';

  @override
  String get addHeader => 'Header hinzufügen';

  @override
  String get maximumHeadersReached => 'Maximale Anzahl erreicht';

  @override
  String get removeHeader => 'Header entfernen';

  @override
  String get connecting => 'Verbindung wird hergestellt...';

  @override
  String get connectToServerButton => 'Mit Server verbinden';

  @override
  String get demoModeActive => 'Demo-Modus aktiv';

  @override
  String get skipServerSetupTryDemo =>
      'Servereinrichtung überspringen und Demo testen';

  @override
  String get enterDemo => 'Demo starten';

  @override
  String get demoBadge => 'Demo';

  @override
  String get serverNotOpenWebUI =>
      'Dies scheint kein Open-WebUI-Server zu sein.';

  @override
  String get serverUrlEmpty => 'Server-URL darf nicht leer sein';

  @override
  String get invalidUrlFormat => 'Ungültiges URL-Format. Bitte Eingabe prüfen.';

  @override
  String get onlyHttpHttps =>
      'Nur HTTP- und HTTPS-Protokolle werden unterstützt.';

  @override
  String get serverAddressRequired =>
      'Serveradresse erforderlich (z. B. 192.168.1.10 oder example.com).';

  @override
  String get portRange => 'Port muss zwischen 1 und 65535 liegen.';

  @override
  String get invalidIpFormat => 'Ungültiges IP-Format. Beispiel: 192.168.1.10.';

  @override
  String get couldNotConnectGeneric =>
      'Verbindung fehlgeschlagen. Adresse prüfen und erneut versuchen.';

  @override
  String get weCouldntReachServer =>
      'Server nicht erreichbar. Verbindung und Serverstatus prüfen.';

  @override
  String get connectionTimedOut =>
      'Zeitüberschreitung. Server eventuell ausgelastet oder blockiert.';

  @override
  String get useHttpOrHttpsOnly => 'Nur http:// oder https:// verwenden.';

  @override
  String get loginFailed => 'Anmeldung fehlgeschlagen';

  @override
  String get invalidCredentials =>
      'Ungültiger Benutzername oder Passwort. Bitte erneut versuchen.';

  @override
  String get serverRedirectingHttps =>
      'Server leitet um. HTTPS-Konfiguration prüfen.';

  @override
  String get unableToConnectServer =>
      'Verbindung zum Server nicht möglich. Bitte Verbindung prüfen.';

  @override
  String get requestTimedOut => 'Zeitüberschreitung. Bitte erneut versuchen.';

  @override
  String get genericSignInFailed =>
      'Anmeldung nicht möglich. Zugangsdaten und Server prüfen.';

  @override
  String get skip => 'Überspringen';

  @override
  String get next => 'Weiter';

  @override
  String get done => 'Fertig';

  @override
  String onboardStartTitle(String username) {
    return 'Hallo, $username';
  }

  @override
  String get onboardStartSubtitle =>
      'Wähle ein Modell, um loszulegen. Tippe jederzeit auf Neuer Chat.';

  @override
  String get onboardStartBullet1 => 'Modellname oben antippen, um zu wechseln';

  @override
  String get onboardStartBullet2 => 'Mit Neuer Chat den Kontext zurücksetzen';

  @override
  String get onboardAttachTitle => 'Kontext hinzufügen';

  @override
  String get onboardAttachSubtitle =>
      'Antworten mit Inhalten aus Arbeitsbereich oder Fotos untermauern.';

  @override
  String get onboardAttachBullet1 =>
      'Arbeitsbereich: PDFs, Dokumente, Datensätze';

  @override
  String get onboardAttachBullet2 => 'Fotos: Kamera oder Bibliothek';

  @override
  String get onboardSpeakTitle => 'Natürlich sprechen';

  @override
  String get onboardSpeakSubtitle => 'Auf das Mikro tippen, um zu diktieren.';

  @override
  String get onboardSpeakBullet1 => 'Jederzeit stoppen; Text bleibt erhalten';

  @override
  String get onboardSpeakBullet2 =>
      'Ideal für kurze Notizen oder lange Prompts';

  @override
  String get onboardQuickTitle => 'Schnellaktionen';

  @override
  String get onboardQuickSubtitle =>
      'Menü öffnen, um zwischen Chats, Arbeitsbereich und Profil zu wechseln.';

  @override
  String get onboardQuickBullet1 =>
      'Menü tippen für Chats, Arbeitsbereich, Profil';

  @override
  String get onboardQuickBullet2 =>
      'Neuer Chat starten oder Modelle oben verwalten';

  @override
  String get attachmentLabel => 'Anhang';

  @override
  String get tools => 'Werkzeuge';

  @override
  String get voiceInput => 'Spracheingabe';

  @override
  String get voice => 'Sprache';

  @override
  String get voiceStatusListening => 'Hört zu…';

  @override
  String get voiceStatusRecording => 'Nimmt auf…';

  @override
  String get voiceHoldToTalk => 'Zum Sprechen halten';

  @override
  String get voiceAutoSend => 'Automatisch senden';

  @override
  String get voiceTranscript => 'Transkript';

  @override
  String get voicePromptSpeakNow => 'Jetzt sprechen…';

  @override
  String get voicePromptTapStart => 'Tippe auf \"Starten\", um zu beginnen';

  @override
  String get voiceActionStop => 'Stopp';

  @override
  String get voiceActionStart => 'Starten';

  @override
  String get voiceCallTitle => 'Sprachanruf';

  @override
  String get voiceCallPause => 'Pause';

  @override
  String get voiceCallResume => 'Fortsetzen';

  @override
  String get voiceCallStop => 'Stopp';

  @override
  String get voiceCallEnd => 'Anruf beenden';

  @override
  String get voiceCallReady => 'Bereit';

  @override
  String get voiceCallConnecting => 'Verbinden...';

  @override
  String get voiceCallListening => 'Zuhören';

  @override
  String get voiceCallPaused => 'Pausiert';

  @override
  String get voiceCallProcessing => 'Denkt...';

  @override
  String get voiceCallSpeaking => 'Spricht';

  @override
  String get voiceCallDisconnected => 'Getrennt';

  @override
  String get voiceCallErrorHelp =>
      'Bitte prüfe:\n• Mikrofonberechtigungen sind erteilt\n• Spracherkennung ist auf deinem Gerät verfügbar\n• Du bist mit dem Server verbunden';

  @override
  String get messageInputLabel => 'Nachrichteneingabe';

  @override
  String get messageInputHint => 'Nachricht eingeben';

  @override
  String get messageHintText => 'Frag Conduit';

  @override
  String get stopGenerating => 'Generierung stoppen';

  @override
  String get send => 'Senden';

  @override
  String get codeCopiedToClipboard => 'Code in die Zwischenablage kopiert.';

  @override
  String get sendMessage => 'Nachricht senden';

  @override
  String get file => 'Datei';

  @override
  String get chooseDifferentFile => 'Andere Datei auswählen';

  @override
  String get photo => 'Foto';

  @override
  String get camera => 'Kamera';

  @override
  String get apiUnavailable => 'API-Dienst nicht verfügbar';

  @override
  String get unableToLoadImage => 'Bild kann nicht geladen werden';

  @override
  String notAnImageFile(String fileName) {
    return 'Keine Bilddatei: $fileName';
  }

  @override
  String failedToLoadImage(String error) {
    return 'Bild konnte nicht geladen werden: $error';
  }

  @override
  String get invalidDataUrl => 'Ungültiges Data-URL-Format';

  @override
  String get failedToDecodeImage => 'Bild konnte nicht decodiert werden';

  @override
  String get invalidImageFormat => 'Ungültiges Bildformat';

  @override
  String get emptyImageData => 'Leere Bilddaten';

  @override
  String get confirm => 'Bestätigen';

  @override
  String get continueAction => 'Weiter';

  @override
  String get cancel => 'Abbrechen';

  @override
  String get ok => 'OK';

  @override
  String get previousLabel => 'Zurück';

  @override
  String get nextLabel => 'Weiter';

  @override
  String get inputField => 'Eingabefeld';

  @override
  String get checkConnection => 'Verbindung prüfen';

  @override
  String get openSettings => 'Einstellungen öffnen';

  @override
  String get goBack => 'Zurück';

  @override
  String get technicalDetails => 'Technische Details';

  @override
  String requiredFieldLabel(String label) {
    return '$label *';
  }

  @override
  String get requiredFieldHelper => 'Pflichtfeld';

  @override
  String get switchOnLabel => 'Ein';

  @override
  String get switchOffLabel => 'Aus';

  @override
  String dialogSemanticLabel(String title) {
    return 'Dialog: $title';
  }

  @override
  String get save => 'Speichern';

  @override
  String get chooseModel => 'Modell wählen';

  @override
  String get reviewerMode => 'REVIEWER MODE';

  @override
  String get selectLanguage => 'Sprache auswählen';

  @override
  String get newFolder => 'Neuer Ordner';

  @override
  String get folderName => 'Ordnername';

  @override
  String get newChat => 'Neuer Chat';

  @override
  String get more => 'Mehr';

  @override
  String get clear => 'Leeren';

  @override
  String get searchConversations => 'Konversationen durchsuchen...';

  @override
  String get create => 'Erstellen';

  @override
  String get failedToCreateFolder => 'Ordner konnte nicht erstellt werden';

  @override
  String get failedToMoveChat => 'Chat konnte nicht verschoben werden';

  @override
  String get failedToLoadChats => 'Chats konnten nicht geladen werden';

  @override
  String get failedToUpdatePin => 'Pin konnte nicht aktualisiert werden';

  @override
  String get failedToDeleteChat => 'Chat konnte nicht gelöscht werden';

  @override
  String get manage => 'Verwalten';

  @override
  String get rename => 'Umbenennen';

  @override
  String get delete => 'Löschen';

  @override
  String get renameChat => 'Chat umbenennen';

  @override
  String get enterChatName => 'Chat-Namen eingeben';

  @override
  String get failedToRenameChat => 'Chat konnte nicht umbenannt werden';

  @override
  String get failedToUpdateArchive => 'Archiv konnte nicht aktualisiert werden';

  @override
  String get unarchive => 'Archivierung aufheben';

  @override
  String get archive => 'Archivieren';

  @override
  String get pin => 'Anheften';

  @override
  String get unpin => 'Lösen';

  @override
  String get recent => 'Zuletzt';

  @override
  String get system => 'System';

  @override
  String get english => 'Englisch';

  @override
  String get deutsch => 'Deutsch';

  @override
  String get francais => 'Französisch';

  @override
  String get italiano => 'Italienisch';

  @override
  String get espanol => 'Spanisch';

  @override
  String get nederlands => 'Niederländisch';

  @override
  String get russian => 'Russisch';

  @override
  String get chinese => 'Chinesisch';

  @override
  String get korean => 'Koreanisch';

  @override
  String get deleteMessagesTitle => 'Nachrichten löschen';

  @override
  String deleteMessagesMessage(int count) {
    return '$count Nachrichten löschen?';
  }

  @override
  String routeNotFound(String routeName) {
    return 'Route nicht gefunden: $routeName';
  }

  @override
  String get deleteChatTitle => 'Chat löschen';

  @override
  String get deleteChatMessage => 'Dieser Chat wird dauerhaft gelöscht.';

  @override
  String get deleteFolderTitle => 'Ordner löschen';

  @override
  String get deleteFolderMessage =>
      'Dieser Ordner und seine Zuordnungen werden entfernt.';

  @override
  String get failedToDeleteFolder => 'Ordner konnte nicht gelöscht werden';

  @override
  String get aboutApp => 'Über';

  @override
  String get aboutAppSubtitle => 'Conduit Informationen und Links';

  @override
  String get web => 'Web';

  @override
  String get imageGen => 'Bild-Gen';

  @override
  String get pinned => 'Angeheftet';

  @override
  String get folders => 'Ordner';

  @override
  String get archived => 'Archiviert';

  @override
  String get appLanguage => 'App-Sprache';

  @override
  String get darkMode => 'Dunkelmodus';

  @override
  String get webSearch => 'Websuche';

  @override
  String get webSearchDescription => 'Im Web suchen und Quellen zitieren.';

  @override
  String get imageGeneration => 'Bildgenerierung';

  @override
  String get imageGenerationDescription =>
      'Bilder aus deinen Prompts erstellen.';

  @override
  String get copy => 'Kopieren';

  @override
  String get ttsListen => 'Anhören';

  @override
  String get ttsStop => 'Stoppen';

  @override
  String get edit => 'Bearbeiten';

  @override
  String get regenerate => 'Neu generieren';

  @override
  String get noConversationsYet => 'Noch keine Unterhaltungen';

  @override
  String get usernameOrEmailHint =>
      'Gib deinen Benutzernamen oder deine E‑Mail ein';

  @override
  String get passwordHint => 'Gib dein Passwort ein';

  @override
  String get enterApiKey => 'Gib deinen API-Schlüssel ein';

  @override
  String get signingIn => 'Anmeldung läuft...';

  @override
  String get advancedSettings => 'Erweiterte Einstellungen';

  @override
  String get customHeaders => 'Benutzerdefinierte Header';

  @override
  String get customHeadersDescription =>
      'Füge benutzerdefinierte HTTP-Header für Authentifizierung, API-Schlüssel oder spezielle Serveranforderungen hinzu.';

  @override
  String get allowSelfSignedCertificates =>
      'Selbstsignierten Zertifikaten vertrauen';

  @override
  String get allowSelfSignedCertificatesDescription =>
      'Akzeptiere das TLS-Zertifikat dieses Servers auch dann, wenn es selbstsigniert ist. Aktiviere diese Option nur für Server, denen du vertraust.';

  @override
  String get headerNameEmpty => 'Header-Name darf nicht leer sein';

  @override
  String get headerNameTooLong => 'Header-Name zu lang (max. 64 Zeichen)';

  @override
  String get headerNameInvalidChars =>
      'Ungültiger Header-Name. Verwende nur Buchstaben, Zahlen und diese Zeichen: !#\$&-^_`|~';

  @override
  String headerNameReserved(String key) {
    return 'Reservierten Header \"$key\" kann nicht überschrieben werden';
  }

  @override
  String get headerValueEmpty => 'Header-Wert darf nicht leer sein';

  @override
  String get headerValueTooLong => 'Header-Wert zu lang (max. 1024 Zeichen)';

  @override
  String get headerValueInvalidChars =>
      'Header-Wert enthält ungültige Zeichen. Nur druckbare ASCII-Zeichen verwenden.';

  @override
  String get headerValueUnsafe =>
      'Header-Wert scheint potenziell unsicheren Inhalt zu enthalten';

  @override
  String headerAlreadyExists(String key) {
    return 'Header \"$key\" existiert bereits. Zum Aktualisieren zuerst entfernen.';
  }

  @override
  String get maxHeadersReachedDetail =>
      'Maximal 10 benutzerdefinierte Header zulässig. Einige entfernen, um mehr hinzuzufügen.';

  @override
  String get noModelsAvailable => 'Keine Modelle verfügbar';

  @override
  String followingSystem(String theme) {
    return 'Dem System folgen: $theme';
  }

  @override
  String get themeDark => 'Dunkel';

  @override
  String get themePalette => 'Farbpalette';

  @override
  String get themePaletteConduitLabel => 'Conduit';

  @override
  String get themePaletteConduitDescription =>
      'Schlichtes neutrales Design für Conduit.';

  @override
  String get themePaletteClaudeLabel => 'Claude';

  @override
  String get themePaletteClaudeDescription =>
      'Warmes, haptisches Farbschema aus dem Claude-Webclient.';

  @override
  String get themePaletteT3ChatLabel => 'T3 Chat';

  @override
  String get themePaletteT3ChatDescription =>
      'Verspielte Verläufe inspiriert vom T3-Stack.';

  @override
  String get themePaletteCatppuccinLabel => 'Catppuccin';

  @override
  String get themePaletteCatppuccinDescription => 'Sanfte Pastellpalette.';

  @override
  String get themePaletteTangerineLabel => 'Tangerine';

  @override
  String get themePaletteTangerineDescription =>
      'Warmes Orange-Schiefer-Farbschema.';

  @override
  String get themeLight => 'Hell';

  @override
  String get currentlyUsingDarkTheme => 'Aktuell dunkles Thema';

  @override
  String get currentlyUsingLightTheme => 'Aktuell helles Thema';

  @override
  String get aboutConduit => 'Über Conduit';

  @override
  String versionLabel(String version, String build) {
    return 'Version: $version ($build)';
  }

  @override
  String get githubRepository => 'GitHub-Repository';

  @override
  String get unableToLoadAppInfo =>
      'App-Informationen konnten nicht geladen werden';

  @override
  String get thinking => 'Denkt…';

  @override
  String get thoughts => 'Gedanken';

  @override
  String thoughtForDuration(String duration) {
    return 'Gedacht für $duration';
  }

  @override
  String get appCustomization => 'Anpassung';

  @override
  String get appCustomizationSubtitle =>
      'Design, Sprache, Stimme und Quick Pills';

  @override
  String get quickActionsDescription => 'Schnellzugriffe im Chat';

  @override
  String quickActionsSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Aktionen ausgewählt',
      one: '$count Aktion ausgewählt',
      zero: 'Keine Aktionen ausgewählt',
    );
    return '$_temp0';
  }

  @override
  String get autoSelectDescription => 'Lass die App das beste Modell auswählen';

  @override
  String get chatSettings => 'Chat';

  @override
  String get sendOnEnter => 'Mit Enter senden';

  @override
  String get sendOnEnterDescription =>
      'Enter sendet (Soft-Tastatur). Cmd/Ctrl+Enter ebenfalls verfügbar';

  @override
  String get sttSettings => 'Sprache zu Text';

  @override
  String get sttEngineLabel => 'Erkennungs-Engine';

  @override
  String get sttEngineAuto => 'Automatisch';

  @override
  String get sttEngineDevice => 'Auf dem Gerät';

  @override
  String get sttEngineServer => 'Server';

  @override
  String get sttEngineAutoDescription =>
      'Verwendet die Erkennung auf dem Gerät, wenn verfügbar, und greift sonst auf deinen Server zurück.';

  @override
  String get sttEngineDeviceDescription =>
      'Behält Audio auf diesem Gerät. Spracheingabe funktioniert nicht, wenn das Gerät keine Spracherkennung unterstützt.';

  @override
  String get sttEngineServerDescription =>
      'Sendet Aufnahmen immer an deinen OpenWebUI-Server zur Transkription.';

  @override
  String get sttDeviceUnavailableWarning =>
      'Auf diesem Gerät steht keine Spracherkennung zur Verfügung.';

  @override
  String get sttServerUnavailableWarning =>
      'Verbinde dich mit einem Server mit aktivierter Transkription, um diese Option zu nutzen.';

  @override
  String get sttSilenceDuration => 'Stille-Dauer';

  @override
  String get sttSilenceDurationDescription =>
      'Zeit nach Stille warten, bevor die Aufnahme automatisch gestoppt wird';

  @override
  String get ttsEngineLabel => 'Engine';

  @override
  String get ttsEngineAuto => 'Automatisch';

  @override
  String get ttsEngineDevice => 'Auf dem Gerät';

  @override
  String get ttsEngineServer => 'Server';

  @override
  String get ttsEngineAutoDescription =>
      'Verwendet die Sprachausgabe auf dem Gerät, wenn verfügbar, und greift sonst auf deinen Server zurück.';

  @override
  String get ttsEngineDeviceDescription =>
      'Behält die Ausgabe auf diesem Gerät. Sprachausgabe funktioniert nicht, wenn das Gerät keine TTS-Unterstützung bietet.';

  @override
  String get ttsEngineServerDescription =>
      'Sendet die Ausgabe immer an deinen OpenWebUI-Server.';

  @override
  String get ttsDeviceUnavailableWarning =>
      'Sprachausgabe auf dem Gerät steht auf diesem Gerät nicht zur Verfügung.';

  @override
  String get ttsServerUnavailableWarning =>
      'Verbinde dich mit einem Server mit aktivierter Sprachausgabe, um diese Option zu nutzen.';

  @override
  String get ttsSettings => 'Text zu Sprache';

  @override
  String get ttsVoice => 'Stimme';

  @override
  String get ttsSpeechRate => 'Sprechgeschwindigkeit';

  @override
  String get ttsPitch => 'Tonhöhe';

  @override
  String get ttsVolume => 'Lautstärke';

  @override
  String get ttsPreview => 'Stimme vorschau';

  @override
  String get ttsSystemDefault => 'Systemstandard';

  @override
  String get ttsSelectVoice => 'Stimme auswählen';

  @override
  String get ttsPreviewText =>
      'Dies ist eine Vorschau der ausgewählten Stimme.';

  @override
  String get ttsNoVoicesAvailable => 'Keine Stimmen verfügbar';

  @override
  String ttsVoicesForLanguage(String language) {
    return '$language-Stimmen';
  }

  @override
  String get ttsOtherVoices => 'Andere Sprachen';

  @override
  String get error => 'Fehler';

  @override
  String errorWithMessage(String message) {
    return 'Fehler: $message';
  }

  @override
  String get networkTimeoutError =>
      'Verbindung abgelaufen. Bitte überprüfe deine Internetverbindung und versuche es erneut.';

  @override
  String get networkUnreachableError =>
      'Server nicht erreichbar. Bitte überprüfe die Server-URL und deine Internetverbindung.';

  @override
  String get networkServerNotResponding =>
      'Server reagiert nicht. Bitte stelle sicher, dass der Server läuft und erreichbar ist.';

  @override
  String get networkGenericError =>
      'Netzwerkproblem. Bitte überprüfe deine Internetverbindung.';

  @override
  String get serverError500 =>
      'Der Server hat Probleme. Das ist meist nur vorübergehend.';

  @override
  String get serverErrorUnavailable =>
      'Server vorübergehend nicht verfügbar. Bitte versuche es gleich noch einmal.';

  @override
  String get serverErrorTimeout =>
      'Der Server hat zu lange für eine Antwort gebraucht. Bitte versuche es erneut.';

  @override
  String get serverErrorGeneric =>
      'Der Server hat Schwierigkeiten. Bitte versuche es später erneut.';

  @override
  String get authSessionExpired =>
      'Deine Sitzung ist abgelaufen. Bitte melde dich erneut an.';

  @override
  String get authForbidden => 'Du hast keine Berechtigung für diese Aktion.';

  @override
  String get authInvalidToken =>
      'Der Authentifizierungstoken ist ungültig. Bitte melde dich erneut an.';

  @override
  String get authGenericError =>
      'Authentifizierungsproblem. Bitte melde dich erneut an.';

  @override
  String get validationInvalidEmail =>
      'Bitte gib eine gültige E-Mail-Adresse ein.';

  @override
  String get validationWeakPassword =>
      'Das Passwort erfüllt die Anforderungen nicht. Bitte überprüfe es und versuche es erneut.';

  @override
  String get validationMissingRequired => 'Bitte fülle alle Pflichtfelder aus.';

  @override
  String get validationFormatError =>
      'Einige Angaben haben ein falsches Format. Bitte überprüfe sie und versuche es erneut.';

  @override
  String get validationGenericError =>
      'Bitte überprüfe deine Eingaben und versuche es erneut.';

  @override
  String get fileNotFound =>
      'Datei nicht gefunden. Vielleicht wurde sie verschoben oder gelöscht.';

  @override
  String get fileAccessDenied =>
      'Datei kann nicht geöffnet werden. Bitte prüfe die Berechtigungen.';

  @override
  String get fileTooLarge =>
      'Datei ist zu groß. Bitte wähle eine kleinere Datei.';

  @override
  String get fileGenericError =>
      'Problem mit der Datei. Bitte versuche eine andere Datei.';

  @override
  String get permissionCameraRequired =>
      'Kamerazugriff erforderlich. Bitte aktiviere ihn in den Einstellungen.';

  @override
  String get permissionStorageRequired =>
      'Speicherzugriff erforderlich. Bitte aktiviere ihn in den Einstellungen.';

  @override
  String get permissionMicrophoneRequired =>
      'Mikrofonzugriff erforderlich. Bitte aktiviere ihn in den Einstellungen.';

  @override
  String get permissionGenericError =>
      'Berechtigung erforderlich. Bitte prüfe die App-Berechtigungen in den Einstellungen.';

  @override
  String get actionRetryRequest => 'Versuche die Anfrage erneut.';

  @override
  String get actionVerifyConnection => 'Überprüfe deine Internetverbindung.';

  @override
  String get actionRetryOperation => 'Wiederhole den Vorgang.';

  @override
  String get actionRetryAfterDelay =>
      'Warte einen Moment und versuche es dann erneut.';

  @override
  String get actionSignInToAccount => 'Melde dich bei deinem Konto an.';

  @override
  String get actionSelectAnotherFile => 'Wähle eine andere Datei.';

  @override
  String get actionOpenAppSettings =>
      'Öffne die App-Einstellungen, um Berechtigungen zu erteilen.';

  @override
  String get actionRetryAfterPermission =>
      'Versuche es erneut, nachdem du die Berechtigung erteilt hast.';

  @override
  String get actionReturnToPrevious => 'Zur vorherigen Ansicht zurückkehren.';

  @override
  String get display => 'Anzeige';

  @override
  String get realtime => 'Echtzeit';

  @override
  String get transportMode => 'Transportmodus';

  @override
  String get mode => 'Modus';

  @override
  String get transportModePolling => 'Polling-Fallback';

  @override
  String get transportModeWs => 'Nur WebSocket';

  @override
  String get transportModePollingInfo =>
      'Fällt auf HTTP-Polling zurück, wenn WebSockets blockiert sind. Wechselt nach Möglichkeit zu WebSocket.';

  @override
  String get transportModeWsInfo =>
      'Geringerer Overhead, kann jedoch hinter strikten Proxys/Firewalls fehlschlagen.';
}
