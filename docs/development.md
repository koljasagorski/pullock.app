# Native Entwicklung

Entwicklungsfassung 0.4.1: USB-Auswahl, Simulationen, Dienstdiagnose, manueller Sperrtest und integrierter automatischer Sperrtest nach ausdrücklichem ARM. Die Kette ist noch nicht auf installierten Diensten und echter Hardware qualifiziert. Es wurde kein Dienst durch den Build installiert.

## Voraussetzungen und Gesamtprüfung

Apple Silicon, macOS 27.x, Xcode 27 / Swift 6.4. Projektgenerierung: XcodeGen 2.45.4. Das generierte Projekt und Shared Scheme sind versioniert.

```sh
bash tools/validation/check.sh
```

179 Tests über Core, USB, IPC, Services einschließlich DaemonRuntime, Actions und Probe, anschließend Debug-/Release-Builds der drei Targets. Selbstdiagnose, Signaturen, eingebettete Helper/Launch-Pfade und direkte Imports werden geprüft. Der öffentliche Eingabeadapter ist in App und SessionAgent erlaubt, niemals im Root-Daemon; private Sperr- und Shutdown-Funktionen bleiben ausgeschlossen. Eine Importprüfung ist kein vollständiger Sicherheitsbeweis.

Keine echten Eingaben, Berechtigungsdialoge, Dienste, Gerätebefehle oder Shutdowns im Testablauf. Anonyme lokale XPC-Verbindungen und temporäre Konfigurationsdateien sind Bestandteil der Tests. Das temporäre Buildverzeichnis vermeidet Finder-/File-Provider-Metadaten aus dem Projektpfad. Mit `PULLOCK_VALIDATION_ROOT` lässt es sich wiederverwenden.

## App starten

```sh
export PULLOCK_BUILD=$(mktemp -d "${TMPDIR%/}/pullock-development.XXXXXX")
xcodebuild -project apps/macos/Pullock.xcodeproj -scheme PullockDevelopment \
  -configuration Debug -derivedDataPath "$PULLOCK_BUILD/xcode" build
open "$PULLOCK_BUILD/xcode/Build/Products/Debug/PullockDevelopment.app"
```

Die Standardansicht zeigt nach authentifizierter Verbindung die USB-Liste des Hintergrunddiensts. „Choose“ lässt diesen die aktuelle Verbindung bestätigen; Schließen des Fensters beendet weder den App-Client noch die Daemon-Beobachtung. Sleep, Sitzungswechsel, Entfernen und Dienstneustart verwerfen die Auswahl. Ohne installierte Dienste öffnet „Local USB inspection…“ die fenstergebundene, passive Diagnose.

Die Dienstansicht bietet jetzt „Arm Pullock…“ mit anschließender Bestätigung echter Sperranforderungen. Voraussetzung sind gesunde Dienste, eindeutiger Agent-Rückkanal, aktive Sitzung sowie Eingabeberechtigung und passendes Layout im Agenten. App und Agent benötigen ihre jeweils passende macOS-Berechtigung. Entfernung und bestimmte Health-Ausfälle können danach reale Eingaben auslösen. Wiedereinstecken hebt einen Trigger nicht auf; ausdrücklich zurücksetzen und neu auswählen. Vor Quit, Disconnect und Unregister verlangt die UI bestätigtes Disarm. Stale oder unbekannter Zustand wird nicht als ARMED angezeigt.

Im Menü stehen sechs bezeichnete Simulationen, Dienstdiagnose und „Test screen lock…“. Letzteres öffnet zuerst die Erklärung und Berechtigungseinrichtung. **Erst** „Lock this Mac now…“ mit anschließender Bestätigung postet eine echte Systemtastenkombination. Ein Lock-Test unterbricht die Sitzung. Das Ergebnis heißt ausschließlich „Lock requested“; entsperre normal und prüfe selbst, ob macOS tatsächlich gesperrt hat.

`--self-check` ist bei allen Binaries weiterhin harmlos. Der optionale App-Aufruf `--usb-inspect` ist die bisherige passive, auf Yubico gefilterte Diagnose; die normale Geräteauswahl verwendet dagegen alle USB-Hersteller. Rohseriennummern und Produktnamen werden nicht in diese Diagnoseausgabe aufgenommen.

## Dienste

Die App enthält zwei Helfer und Launch-Definitionen. Die UI registriert sie nur auf ausdrücklichen Wunsch über `SMAppService`; sie zeigt Freigabestatus getrennt vom Health-Status. Apple-Zertifikat und Installation in `/Applications` sind UI-Voraussetzungen; macOS verlangt für Apps mit LaunchDaemon zusätzlich Notarisierung und Administratorfreigabe. Nicht registrierte oder ad-hoc-signierte Entwicklungsbuilds stellen deshalb keinen Systemdienst bereit.

`PullockDaemon --serve-health` ist ein expliziter root-Dienststart mit festen Rollenendpunkten, autoritativer Auswahl sowie USB-/Power-/Konsolenbeobachtung. Der Kommandozeilenname bleibt bestehen; dieser Modus aktiviert nun auch den eng begrenzten Aktionsversand zum Agenten. `PullockSessionAgent --monitor-health` ist ein Benutzerprozess mit Readiness-Abfrage, authentifiziertem Rückkanal und unabhängigem Lease-Watchdog. Er fordert beim Login keine Berechtigung an. Unter „Background services“ lässt sich nach Verbindung und im entschärften Zustand „Request session agent permission“ auslösen. Der einmalige, befristete Auftrag läuft über das authentifizierte XPC; der Agent ruft die Berechtigungsanfrage selbst auf. Dieser Schritt sendet keine Tasteneingabe und bestätigt keine erteilte Berechtigung. Die nächste Readiness-Meldung enthält das eigene Preflight-Ergebnis. Default/`--self-check` starten keine Listener und keinen Aktionspfad. Clients können keine USB-Ereignisse injizieren. Protokoll v3 verlangt ein gemeinsames Update aller drei Komponenten. [Dienstimplementierung](../packages/PullockServices/README.md).

`PullockDaemon --inspect-runtime` prüft separat für eine Sekunde native USB-/Power-/Konsolenregistrierung und Eventloop-Fortschritt. Er startet keinen XPC-Listener, registriert keinen launchd-Dienst und führt keine Aktionen aus. Die Ausgabe enthält nur eine Geräteanzahl. Dieser optionale lokale OS-Test ist nicht Teil der gewöhnlichen CI.

## Signiertes lokales Archiv

Nach einer erfolgreichen Gesamtprüfung, mit genau einem verwendbaren Apple-Signierzertifikat:

```sh
export PULLOCK_SIGNED_ROOT=$(mktemp -d "${TMPDIR%/}/pullock-signed.XXXXXX")
python3 tools/release/archive-development.py \
  --output "$PULLOCK_SIGNED_ROOT/review" \
  --probe-binary "$PULLOCK_VALIDATION_ROOT/xcode/Build/Products/Release/PullockDaemon"
```

`PULLOCK_VALIDATION_ROOT` muss auf das tatsächlich geprüfte Verzeichnis zeigen. Der Helfer wählt ein vorhandenes Developer-ID-Application-Zertifikat, andernfalls Apple Development; bei mehrdeutigen Identitäten bricht er ab. Er signiert einen kopierten Probe-Binary zur Ermittlung der Team-ID, **führt ihn aber nicht aus**. Logs und Exportoptionen bleiben privat im Ausgabeverzeichnis; keine Passwörter, privaten Schlüssel oder Zertifikatsexporte werden benötigt.

Optional `--export-developer-id` erlaubt Xcode, den Developer-ID-Export über den in Xcode eingerichteten Account vorzubereiten. Ein CLI-Fehler `No Accounts` beweist nicht, dass die Xcode-Oberfläche abgemeldet ist. Bei bestätigtem Team dieselbe Xcode-Installation und denselben macOS-Benutzer prüfen und das vorhandene Archiv direkt im Organizer verteilen. Keine Notarisierung, Installation, Service-Registrierung oder GitHub-Veröffentlichung durch diesen Befehl.

## Projekt und CI

Nach Strukturänderungen `xcodegen generate --spec apps/macos/project.yml` ausführen und Projektdatei sowie YAML gemeinsam versionieren. Die CI verwendet denselben Prüfablauf auf `xcode-27`, Read-only-Rechte und gepinnte Checkout-Action. Sie hat keine Signing-/Notarisierungscredentials.

[Aktueller Testbericht](test-reports/M4-M5.md), [Release-Voraussetzungen](release/README.md), [XcodeGen-Spezifikation](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
