# Native Entwicklung

Entwicklungsfassung 0.4.0: USB-Auswahl, Simulationen, Dienstdiagnose und ein ausdrücklich gestarteter manueller Sperrtest. Automatischer Schutz ist noch nicht verfügbar. Es wurde kein Dienst durch den Build installiert.

## Voraussetzungen und Gesamtprüfung

Apple Silicon, macOS 27.x, Xcode 27 / Swift 6.4. Projektgenerierung: XcodeGen 2.45.4. Das generierte Projekt und Shared Scheme sind versioniert.

```sh
bash tools/validation/check.sh
```

118 Tests über Core, USB, IPC, Services, Actions und Probe, anschließend Debug-/Release-Builds der drei Targets. Selbstdiagnose, Signaturen, eingebettete Helper/Launch-Pfade und direkte Imports werden geprüft. Der echte öffentliche Eingabeadapter ist nur im App-Target für den manuellen UI-Test erlaubt; private Sperr- und Shutdown-Funktionen bleiben ausgeschlossen. Eine Importprüfung ist kein vollständiger Sicherheitsbeweis.

Keine echten Eingaben, Berechtigungsdialoge, Dienste, Gerätebefehle oder Shutdowns im Testablauf. Anonyme lokale XPC-Verbindungen und temporäre Konfigurationsdateien sind Bestandteil der Tests. Das temporäre Buildverzeichnis vermeidet Finder-/File-Provider-Metadaten aus dem Projektpfad. Mit `PULLOCK_VALIDATION_ROOT` lässt es sich wiederverwenden.

## App starten

```sh
export PULLOCK_BUILD=$(mktemp -d "${TMPDIR%/}/pullock-development.XXXXXX")
xcodebuild -project apps/macos/Pullock.xcodeproj -scheme PullockDevelopment \
  -configuration Debug -derivedDataPath "$PULLOCK_BUILD/xcode" build
open "$PULLOCK_BUILD/xcode/Build/Products/Debug/PullockDevelopment.app"
```

Die Standardansicht zeigt USB-Geräte verschiedener Hersteller. „Select this connection“ wählt nur die aktuelle Verbindung; Schließen/Neustart der Diagnosebeobachtung, Sleep, Sitzungswechsel und Entfernen verwerfen sie. Das ist derzeit ein Erkennungstest, kein automatisches Arming.

Im Menü stehen sechs bezeichnete Simulationen, Dienstdiagnose und „Test screen lock…“. Letzteres öffnet zuerst die Erklärung und Berechtigungseinrichtung. **Erst** „Lock this Mac now…“ mit anschließender Bestätigung postet eine echte Systemtastenkombination. Ein Lock-Test unterbricht die Sitzung. Das Ergebnis heißt ausschließlich „Lock requested“; entsperre normal und prüfe selbst, ob macOS tatsächlich gesperrt hat.

`--self-check` ist bei allen Binaries weiterhin harmlos. Der optionale App-Aufruf `--usb-inspect` ist die bisherige passive, auf Yubico gefilterte Diagnose; die normale Geräteauswahl verwendet dagegen alle USB-Hersteller. Rohseriennummern und Produktnamen werden nicht in diese Diagnoseausgabe aufgenommen.

## Dienste

Die App enthält zwei Helfer und Launch-Definitionen. Die UI registriert sie nur auf ausdrücklichen Wunsch über `SMAppService`; sie zeigt Freigabestatus getrennt vom Health-Status. Apple-Zertifikat und Installation in `/Applications` sind UI-Voraussetzungen; macOS verlangt für Apps mit LaunchDaemon zusätzlich Notarisierung und Administratorfreigabe. Nicht registrierte oder ad-hoc-signierte Entwicklungsbuilds stellen deshalb keinen Systemdienst bereit.

`PullockDaemon --serve-health` ist ein expliziter root-Dienststart mit festen Rollenendpunkten. `PullockSessionAgent --monitor-health` ist ein Benutzerprozess mit begrenzter Health-Abfrage. Default/`--self-check` starten keine Listener. Kein Diagnose-Endpunkt akzeptiert Arming, Konfiguration, USB-Injektion oder Aktionen. [Dienstimplementierung](../packages/PullockServices/README.md).

## Signiertes lokales Archiv

Nach einer erfolgreichen Gesamtprüfung, mit genau einem verwendbaren Apple-Signierzertifikat:

```sh
export PULLOCK_SIGNED_ROOT=$(mktemp -d "${TMPDIR%/}/pullock-signed.XXXXXX")
python3 tools/release/archive-development.py \
  --output "$PULLOCK_SIGNED_ROOT/review" \
  --probe-binary "$PULLOCK_VALIDATION_ROOT/xcode/Build/Products/Release/PullockDaemon"
```

`PULLOCK_VALIDATION_ROOT` muss auf das tatsächlich geprüfte Verzeichnis zeigen. Der Helfer wählt ein vorhandenes Developer-ID-Application-Zertifikat, andernfalls Apple Development; bei mehrdeutigen Identitäten bricht er ab. Er signiert einen kopierten Probe-Binary zur Ermittlung der Team-ID, **führt ihn aber nicht aus**. Logs und Exportoptionen bleiben privat im Ausgabeverzeichnis; keine Passwörter, privaten Schlüssel oder Zertifikatsexporte werden benötigt.

Optional `--export-developer-id` erlaubt Xcode, den Developer-ID-Export über den in Xcode eingerichteten Account vorzubereiten. Fehlt der Account, meldet der Helfer diesen konkreten Grund. Keine Notarisierung, Installation, Service-Registrierung oder GitHub-Veröffentlichung durch diesen Befehl.

## Projekt und CI

Nach Strukturänderungen `xcodegen generate --spec apps/macos/project.yml` ausführen und Projektdatei sowie YAML gemeinsam versionieren. Die CI verwendet denselben Prüfablauf auf `xcode-27`, Read-only-Rechte und gepinnte Checkout-Action. Sie hat keine Signing-/Notarisierungscredentials.

[Aktueller Testbericht](test-reports/M4-M5.md), [Release-Voraussetzungen](release/README.md), [XcodeGen-Spezifikation](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).
