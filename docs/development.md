# Native Entwicklung

Die aktuelle Entwicklungsfassung enthält reine Swift-Packages, einen ungefährlichen Hardware-Probe und drei native Xcode-Targets. Es gibt keinen installierten Schutzdienst und keinen funktionsfähigen Live-Schutzmodus.

## Voraussetzungen und Gesamtprüfung

Lokal geprüft: Apple Silicon, macOS 27.0, Xcode 27.0 und Swift 6.4. XcodeGen 2.45.4 wurde zur Projektgenerierung verwendet. Das generierte Xcode-Projekt und das Shared Scheme sind versioniert; zum Bauen wird XcodeGen nicht benötigt.

```sh
bash tools/validation/check.sh
```

Der Befehl testet `PullockCore`, `PullockUSB`, `PullockIPC` und den Hardware-Probe (insgesamt 83 Tests), baut die drei nativen Targets in Debug und Release und prüft deren Selbstdiagnose, Signatur sowie direkte Imports gefährlicher Aktionsfunktionen. Er registriert keine Dienste, startet keine GUI und führt keine echten Hardware-, Lock- oder Shutdown-Tests aus.

Build-Artefakte werden in einem neuen temporären Verzeichnis abgelegt; der Pfad wird ausgegeben. Das vermeidet Finder-/File-Provider-Metadaten, die lokal die Testbundle-Signierung im Projektordner gestört haben. Ein vorhandenes **eigenes** Buildverzeichnis lässt sich mit `PULLOCK_VALIDATION_ROOT` wiederverwenden.

## Einzelne Targets

```sh
export PULLOCK_PROBE_BUILD=$(mktemp -d "${TMPDIR%/}/pullock-development.XXXXXX")
swift test --package-path packages/PullockCore --scratch-path "$PULLOCK_PROBE_BUILD/core"
swift test --package-path packages/PullockIPC --scratch-path "$PULLOCK_PROBE_BUILD/ipc"
xcodebuild -project apps/macos/Pullock.xcodeproj -scheme PullockDevelopment \
  -configuration Debug -derivedDataPath "$PULLOCK_PROBE_BUILD/xcode" build
open "$PULLOCK_PROBE_BUILD/xcode/Build/Products/Debug/PullockDevelopment.app"
```

Die App startet mit einer passiven USB-Geräteansicht. Sie verwendet dieselbe `PullockUSB`-Implementierung wie der Hardware-Probe und erklärt, warum ein sichtbares Gerät noch nicht registriert werden kann. Ein zweites Fenster zeigt sechs **SIMULATION**-Abläufe. Auch ein simuliertes ARMED bedeutet keinen Live-Schutz. Das Menu-Bar-Menü ist entsprechend bezeichnet; es gibt keine scheinbar funktionierenden Installations-/Arming-Schalter.

Ein expliziter passiver App-Snapshot ohne GUI ist über `PullockDevelopment.app/Contents/MacOS/PullockDevelopment --usb-inspect` möglich. Die normale Selbstdiagnose `--self-check` greift weiterhin nicht auf Hardware zu. Die Geräteansicht pausiert bei NSWorkspace-Sleep-/Sessionmeldungen und startet ihre Diagnosebeobachtung mit neuer Epoche; das ist noch keine qualifizierte Power-Strategie des Daemons.

Agent und Daemon sind kurz laufende Entwicklungshüllen:

```sh
"$PULLOCK_PROBE_BUILD/xcode/Build/Products/Debug/PullockSessionAgent" --self-check
"$PULLOCK_PROBE_BUILD/xcode/Build/Products/Debug/PullockDaemon" --self-check
```

Sie öffnen keinen Listener und installieren sich nicht bei launchd. Die Targets haben eigene `.development`-Identifier und linken keinen echten Aktionsadapter. Die Xcode-Builds verwenden ad-hoc-Signaturen; Xcode deaktiviert dabei trotz gesetztem Build-Setting die Hardened Runtime. Dies ist **kein** Developer-ID-/Distributionsnachweis. Der separat Apple-Development-signierte M1-Probe ist im [M1-Bericht](test-reports/M1.md) dokumentiert.

## Projektstruktur und Generierung

```text
packages/PullockCore/  Reducer, Policy, Identität, Health; separates Simulationsprodukt
packages/PullockIPC/   Versionierter, rollenbegrenzter Nachrichtenvertrag
packages/PullockUSB/   Passiver IOKit-Watcher, Deskriptoren, Enrollment-Prüfung
apps/macos/           Xcode-Projekt, Shared Scheme und drei Entwicklungs-Targets
tools/hardware-harness/  Passiver Probe mit gemeinsamem USB-Modul und Power-Beobachtung
tools/validation/     Gemeinsamer lokaler/CI-Prüfablauf
tools/release/        Lokale Paketierung zur Release-Vorbereitung
```

Nach Änderungen an der Projektstruktur:

```sh
xcodegen generate --spec apps/macos/project.yml
```

`project.yml` und generierte Projektdateien gemeinsam prüfen und versionieren. Referenz: [XcodeGen Project Spec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md).

## CI

`.github/workflows/swift.yml` führt denselben ungefährlichen Prüfablauf für Codeänderungen aus. Er verwendet den aktuellen Apple-Silicon-Runner `xcode-27`, Read-only-Repositoryrechte und eine auf Commit-SHA fixierte Checkout-Action ohne persistierte Credentials. Die Label-/Toolchain-Auswahl basiert auf den [offiziellen Runner-Images](https://github.com/actions/runner-images#available-images) und der [Xcode-27-Imagebeschreibung](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md).

CI-Builds sind kein Hardware- oder Schutzfunktionsnachweis. Physische Keys, Power-Sequenzen, signiertes XPC, Service-Freigaben und echte Sperr-/Shutdown-Proben bleiben eigene Prüfungen.

Die [Release-Vorbereitung](release/README.md) beschreibt die bereits ausführbare lokale Paketierung und die noch offenen Bedingungen für das angeforderte erste GitHub-Release.
