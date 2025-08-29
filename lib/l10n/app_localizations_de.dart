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
  String get initializationFailed => 'Initialisierung fehlgeschlagen';

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
  String get pleaseCheckConnection => 'Bitte überprüfe deine Verbindung und versuche es erneut';

  @override
  String get account => 'Konto';

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
  String get noResults => 'Keine Ergebnisse';

  @override
  String get searchModels => 'Modelle suchen...';

  @override
  String get errorMessage => 'Etwas ist schief gelaufen. Bitte versuche es erneut.';

  @override
  String get loginButton => 'Anmelden';

  @override
  String get menuItem => 'Einstellungen';

  @override
  String dynamicContentWithPlaceholder(String name) {
    return 'Willkommen, $name!';
  }

  @override
  String itemsCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count Elemente',
      one: '1 Element',
      zero: 'Keine Elemente',
    );
    return '$_temp0';
  }

  @override
  String get closeButtonSemantic => 'Schließen';

  @override
  String get loadingContent => 'Inhalt wird geladen';

  @override
  String get noItems => 'Keine Elemente';

  @override
  String get noItemsToDisplay => 'Keine Elemente zum Anzeigen';

  @override
  String get loadMore => 'Mehr laden';

  @override
  String get workspace => 'Arbeitsbereich';

  @override
  String get recentFiles => 'Zuletzt verwendete Dateien';

  @override
  String get knowledgeBase => 'Wissensdatenbank';

  @override
  String get noFilesYet => 'Noch keine Dateien';

  @override
  String get uploadDocsPrompt => 'Lade Dokumente hoch, um sie in deinen Unterhaltungen mit Conduit zu verwenden';

  @override
  String get uploadFirstFile => 'Erste Datei hochladen';

  @override
  String get knowledgeBaseEmpty => 'Wissensdatenbank ist leer';

  @override
  String get createCollectionsPrompt => 'Erstelle Sammlungen verwandter Dokumente zur einfachen Referenz';

  @override
  String get chooseSourcePhoto => 'Quelle auswählen';

  @override
  String get takePhoto => 'Foto aufnehmen';

  @override
  String get chooseFromGallery => 'Aus Fotos auswählen';

  @override
  String get document => 'Dokument';

  @override
  String get documentHint => 'PDF-, Word- oder Textdatei';

  @override
  String get uploadFileTitle => 'Datei hochladen';

  @override
  String fileUploadComingSoon(String type) {
    return 'Dateiupload für $type kommt bald!';
  }

  @override
  String get kbCreationComingSoon => 'Erstellung der Wissensdatenbank kommt bald!';

  @override
  String get backToServerSetup => 'Zur Servereinrichtung zurück';

  @override
  String get connectedToServer => 'Mit Server verbunden';

  @override
  String get signIn => 'Anmelden';

  @override
  String get enterCredentials => 'Gib deine Anmeldedaten ein, um auf deine KI-Unterhaltungen zuzugreifen';

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
  String get enterServerAddress => 'Gib die Adresse deines Open-WebUI-Servers ein, um zu beginnen';

  @override
  String get serverUrl => 'Server-URL';

  @override
  String get serverUrlHint => 'https://dein-server.com';

  @override
  String get enterServerUrlSemantic => 'Gib deine Server-URL oder IP-Adresse ein';

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
  String get skipServerSetupTryDemo => 'Servereinrichtung überspringen und Demo testen';

  @override
  String get enterDemo => 'Demo starten';

  @override
  String get demoBadge => 'Demo';

  @override
  String get serverNotOpenWebUI => 'Dies scheint kein Open-WebUI-Server zu sein.';

  @override
  String get serverUrlEmpty => 'Server-URL darf nicht leer sein';

  @override
  String get invalidUrlFormat => 'Ungültiges URL-Format. Bitte Eingabe prüfen.';

  @override
  String get onlyHttpHttps => 'Nur HTTP- und HTTPS-Protokolle werden unterstützt.';

  @override
  String get serverAddressRequired => 'Serveradresse erforderlich (z. B. 192.168.1.10 oder example.com).';

  @override
  String get portRange => 'Port muss zwischen 1 und 65535 liegen.';

  @override
  String get invalidIpFormat => 'Ungültiges IP-Format. Beispiel: 192.168.1.10.';

  @override
  String get couldNotConnectGeneric => 'Verbindung fehlgeschlagen. Adresse prüfen und erneut versuchen.';

  @override
  String get weCouldntReachServer => 'Server nicht erreichbar. Verbindung und Serverstatus prüfen.';

  @override
  String get connectionTimedOut => 'Zeitüberschreitung. Server eventuell ausgelastet oder blockiert.';

  @override
  String get useHttpOrHttpsOnly => 'Nur http:// oder https:// verwenden.';

  @override
  String get loginFailed => 'Anmeldung fehlgeschlagen';

  @override
  String get invalidCredentials => 'Ungültiger Benutzername oder Passwort. Bitte erneut versuchen.';

  @override
  String get serverRedirectingHttps => 'Server leitet um. HTTPS-Konfiguration prüfen.';

  @override
  String get unableToConnectServer => 'Verbindung zum Server nicht möglich. Bitte Verbindung prüfen.';

  @override
  String get requestTimedOut => 'Zeitüberschreitung. Bitte erneut versuchen.';

  @override
  String get genericSignInFailed => 'Anmeldung nicht möglich. Zugangsdaten und Server prüfen.';

  @override
  String get skip => 'Überspringen';

  @override
  String get next => 'Weiter';

  @override
  String get done => 'Fertig';

  @override
  String get onboardStartTitle => 'Unterhaltung starten';

  @override
  String get onboardStartSubtitle => 'Wähle ein Modell und tippe los. Tippe jederzeit auf Neuer Chat.';

  @override
  String get onboardStartBullet1 => 'Modellname oben antippen, um zu wechseln';

  @override
  String get onboardStartBullet2 => 'Mit Neuer Chat den Kontext zurücksetzen';

  @override
  String get onboardAttachTitle => 'Kontext hinzufügen';

  @override
  String get onboardAttachSubtitle => 'Antworten mit Inhalten aus Arbeitsbereich oder Fotos untermauern.';

  @override
  String get onboardAttachBullet1 => 'Arbeitsbereich: PDFs, Dokumente, Datensätze';

  @override
  String get onboardAttachBullet2 => 'Fotos: Kamera oder Bibliothek';

  @override
  String get onboardSpeakTitle => 'Natürlich sprechen';

  @override
  String get onboardSpeakSubtitle => 'Auf das Mikro tippen, um zu diktieren.';

  @override
  String get onboardSpeakBullet1 => 'Jederzeit stoppen; Text bleibt erhalten';

  @override
  String get onboardSpeakBullet2 => 'Ideal für kurze Notizen oder lange Prompts';

  @override
  String get onboardQuickTitle => 'Schnellaktionen';

  @override
  String get onboardQuickSubtitle => 'Menü öffnen, um zwischen Chats, Arbeitsbereich und Profil zu wechseln.';

  @override
  String get onboardQuickBullet1 => 'Menü tippen für Chats, Arbeitsbereich, Profil';

  @override
  String get onboardQuickBullet2 => 'Neuer Chat starten oder Modelle oben verwalten';

  @override
  String get addAttachment => 'Anhang hinzufügen';

  @override
  String get tools => 'Werkzeuge';

  @override
  String get voiceInput => 'Spracheingabe';

  @override
  String get messageInputLabel => 'Nachrichteneingabe';

  @override
  String get messageInputHint => 'Nachricht eingeben';

  @override
  String get messageHintText => 'Nachricht...';

  @override
  String get stopGenerating => 'Generierung stoppen';

  @override
  String get send => 'Senden';

  @override
  String get sendMessage => 'Nachricht senden';

  @override
  String get file => 'Datei';

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
  String get offlineBanner => 'Du bist offline. Einige Funktionen sind eingeschränkt.';

  @override
  String get featureRequiresInternet => 'Diese Funktion erfordert eine Internetverbindung';

  @override
  String get messagesWillSendWhenOnline => 'Nachrichten werden gesendet, sobald du wieder online bist';

  @override
  String get confirm => 'Bestätigen';

  @override
  String get cancel => 'Abbrechen';

  @override
  String get ok => 'OK';

  @override
  String get inputField => 'Eingabefeld';

  @override
  String get captureDocumentOrImage => 'Dokument oder Bild aufnehmen';

  @override
  String get checkConnection => 'Verbindung prüfen';

  @override
  String get openSettings => 'Einstellungen öffnen';

  @override
  String get chooseDifferentFile => 'Andere Datei wählen';

  @override
  String get goBack => 'Zurück';

  @override
  String get technicalDetails => 'Technische Details';

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
  String get searchHint => 'Suchen...';

  @override
  String get searchConversations => 'Konversationen durchsuchen...';

  @override
  String get create => 'Erstellen';

  @override
  String get folderCreated => 'Ordner erstellt';

  @override
  String get failedToCreateFolder => 'Ordner konnte nicht erstellt werden';

  @override
  String movedChatToFolder(String title, String folder) {
    return '\"$title\" nach \"$folder\" verschoben';
  }

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
  String get aboutApp => 'Über die App';

  @override
  String get aboutAppSubtitle => 'Conduit Informationen und Links';

  @override
  String get typeBelowToBegin => 'Unten tippen, um zu beginnen';

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
  String get imageGenerationDescription => 'Bilder aus deinen Prompts erstellen.';

  @override
  String get copy => 'Kopieren';

  @override
  String get edit => 'Bearbeiten';

  @override
  String get regenerate => 'Neu generieren';

  @override
  String get noConversationsYet => 'Noch keine Unterhaltungen';

  @override
  String get usernameOrEmailHint => 'Gib deinen Benutzernamen oder deine E‑Mail ein';

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
  String get customHeadersDescription => 'Füge benutzerdefinierte HTTP-Header für Authentifizierung, API-Schlüssel oder spezielle Serveranforderungen hinzu.';

  @override
  String get headerNameEmpty => 'Header-Name darf nicht leer sein';

  @override
  String get headerNameTooLong => 'Header-Name zu lang (max. 64 Zeichen)';

  @override
  String get headerNameInvalidChars => 'Ungültiger Header-Name. Verwende nur Buchstaben, Zahlen und diese Zeichen: !#\$&-^_`|~';

  @override
  String headerNameReserved(String key) {
    return 'Reservierten Header \"$key\" kann nicht überschrieben werden';
  }

  @override
  String get headerValueEmpty => 'Header-Wert darf nicht leer sein';

  @override
  String get headerValueTooLong => 'Header-Wert zu lang (max. 1024 Zeichen)';

  @override
  String get headerValueInvalidChars => 'Header-Wert enthält ungültige Zeichen. Nur druckbare ASCII-Zeichen verwenden.';

  @override
  String get headerValueUnsafe => 'Header-Wert scheint potenziell unsicheren Inhalt zu enthalten';

  @override
  String headerAlreadyExists(String key) {
    return 'Header \"$key\" existiert bereits. Zum Aktualisieren zuerst entfernen.';
  }

  @override
  String get maxHeadersReachedDetail => 'Maximal 10 benutzerdefinierte Header zulässig. Einige entfernen, um mehr hinzuzufügen.';

  @override
  String get editMessage => 'Nachricht bearbeiten';

  @override
  String get noModelsAvailable => 'Keine Modelle verfügbar';

  @override
  String followingSystem(String theme) {
    return 'Dem System folgen: $theme';
  }

  @override
  String get themeDark => 'Dunkel';

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
  String get unableToLoadAppInfo => 'App-Informationen konnten nicht geladen werden';

  @override
  String get thinking => 'Denkt…';

  @override
  String get thoughts => 'Gedanken';

  @override
  String thoughtForDuration(String duration) {
    return 'Gedacht für $duration';
  }

  @override
  String get ttsLanguage => 'TTS-Sprache';

  @override
  String get ttsLanguageDescription => 'Sprache für Text-zu-Sprache wählen';

  @override
  String get listen => 'Anhören';

  @override
  String get stop => 'Stoppen';
}
