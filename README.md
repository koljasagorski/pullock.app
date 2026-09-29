# Pullock

**Pull the key. Lock the Device.**

Pullock wird eine native macOS-Menu-Bar-App für einen physischen USB-Killswitch. Die App erkennt beobachtbare, kompatible USB-Geräte verschiedener Hersteller: USB-Sticks und andere USB-Devices. Du wählst eines aus und schaltest Pullock ausdrücklich scharf; sobald genau dieses Gerät getrennt wird, soll Pullock eine Sitzungssperre anfordern. Inhalte, Dateien und Credentials des Geräts werden nicht gelesen. Ein bestimmter Hersteller oder eine Seriennummer sind für diesen Modus nicht erforderlich.

> **Entwicklungsstand 0.4.0: noch kein automatischer Live-Schutz und kein öffentlicher App-Release.** Die App bietet passive Geräteauswahl, Simulationen, Dienstdiagnose und einen ausdrücklich gestarteten manuellen Sperrtest. Der Benutzer hat die Veröffentlichung der ersten qualifizierten App auf GitHub beauftragt. Ein Prototyp ersetzt diesen Release nicht.

## Was bereits funktioniert

| Bestandteil | Nachweisstand |
| --- | --- |
| Zustandskern | 41 Tests; Auswahl an Boot/Watcher/Power gebunden, Health-Leases, Ereignisreihenfolge, verriegelte Trigger und getrennte Aktionsanforderungen |
| USB-Beobachtung | 20 Tests; passiver IOKit-Watcher, aktuelle Geräte verschiedener Hersteller, Auswahl einer einzelnen Verbindung und deren sichere Invalidierung |
| IPC | 29 Vertrag-/Signatur-/Rollen-/Budgettests einschließlich begrenztem Sperrnachrichtenformat |
| Native Dienste / Speicher | 31 Tests; reale anonyme NSXPC-Verbindungen, Signaturablehnung, Owner-Neuprüfung, Verbindungslimits/Timeouts, Dateispeicherhärtung und Aktions-Deduplizierung |
| Daemon-Laufzeit | 9 Tests; serialisierte Geräteauswahl, frische Inventare, Sleep-/Session-Grenzen, eingefrorene Snapshots und begrenzte Befehlsübergabe |
| Sperrkurzbefehl | 4 Mock-Tests; öffentlicher Control–Command–Q-Adapter, Berechtigungs-/Sitzungsprüfung und Tastaturlayout-Auflösung |
| Hardware-Probe | 8 Tests; passive Diagnose, bereinigte Reports, keine echten Aktionen |
| App und eingebettete Helfer | Debug-/Release-Builds; Selbstdiagnosen, Signatur- und Importprüfung; feste Launch-Definitionen |

Die **142 automatischen Tests** führen keine echten Sperren, Shutdowns, Gerätebefehle oder Dienstregistrierungen aus. Native anonyme XPC-Tests ersetzen keine Prüfung installierter, separat laufender Produktionsdienste.

## So ist der Killswitch vorgesehen

1. USB-Gerät anschließen und seine aktuelle Verbindung in Pullock auswählen.
2. Erforderliche Dienste und macOS-Eingabeberechtigung einrichten; den Sperrweg bewusst testen.
3. Bei gültigem Systemzustand den Killswitch aktivieren.
4. Beim Ende der gewählten USB-Verbindung Control–Command–Q anfordern.

Die Auswahl wird **nicht dauerhaft gespeichert**. Abziehen, Sleep, Sitzungs-/Watcher-Wechsel und Neustart erfordern eine neue Auswahl und ausdrückliche Aktivierung. Ein gleiches Modell oder dasselbe Gerät nach erneutem Einstecken ersetzt die alte Verbindung nicht.

Nach Event-Übergabe lautet das Ergebnis **„Lock requested“ / „Sperre angefordert“**. Die verwendete öffentliche API bestätigt nicht, dass macOS tatsächlich gesperrt hat. Die aktuelle Oberfläche erlaubt nur Auswahl-/Erkennungstests und einen separaten manuellen Sperrtest; die automatische Aktionskette ist noch nicht freigegeben.

[Die vom Nutzer bestätigte Produktentscheidung](docs/decisions/0003-connection-switch-and-shortcut.md) ersetzt frühere Planannahmen zu einer zwingenden YubiKey-Seriennummer und zur Wahl des Sperrwegs.

## Entwicklung

Voraussetzungen: Apple Silicon, macOS 27.x, Xcode 27 / Swift 6.4. Das generierte Xcode-Projekt ist versioniert. XcodeGen wird nur nach Änderungen an `project.yml` benötigt.

```sh
bash tools/validation/check.sh
```

Der gemeinsame lokale/CI-Ablauf testet die Packages, baut drei Targets in Debug und Release und prüft die ausführbaren Dateien einschließlich eingebetteter Helfer. Build-Artefakte liegen in einem ausgegebenen temporären Verzeichnis. Er öffnet keine App und löst keine Berechtigungsdialoge aus.

```text
packages/PullockCore/      Deterministischer Zustand und separates Simulationsprodukt
packages/PullockUSB/       Passiver USB-Watcher und aktuelle Verbindungsauswahl
packages/PullockIPC/       Nachrichten, Signaturen, Rollen und Limits
packages/PullockServices/  XPC, Policy-Store und getrenntes Daemon-Laufzeitprodukt
packages/PullockActions/   Öffentlicher Sperrkurzbefehl, ausdrücklich ausgelöst
apps/macos/               SwiftUI-App, Agent, Daemon und Launch-Definitionen
tools/hardware-harness/  Passiver Hardware-Probe
tools/validation/        Gemeinsame Prüfung
tools/release/           Lokale Archive/Pakete, noch keine Veröffentlichung
```

Details: [Entwicklung](docs/development.md), [M4-/M5-Nachweis](docs/test-reports/M4-M5.md), [Release-Vorbereitung](docs/release/README.md).

## Architektur und Grenzen

Die Schutzkette trennt Oberfläche, sitzungsspezifischen Aktionsagenten und autoritativen Daemon. Der Entwicklungsdaemon beobachtet USB, Power und Konsolensitzung und bestätigt die flüchtige Geräteauswahl über authentifiziertes XPC. Ein geschlossenes Auswahlfenster stoppt diese Beobachtung nicht. Die separate lokale USB-Diagnose bleibt ohne Dienstinstallation verfügbar. Die Registrierung erfolgt nur über einen ausdrücklichen UI-Schritt und die macOS-Freigabe. Automatische Aktionen bleiben deaktiviert; ein registrierter oder erreichbarer Dienst bedeutet noch keinen funktionierenden Schutz.

- IORegistry-Terminierung beweist das Ende einer beobachteten Verbindung, nicht den mechanischen Grund. Hub-/Bus-Resets können dieselbe Wirkung haben.
- Der Systemkurzbefehl setzt Eingabeberechtigung, geeignete Sitzung und Tastaturkonfiguration voraus. Umkonfigurierte Systemshortcuts und Systemstörungen müssen praktisch berücksichtigt werden.
- Gerät und Mac können gemeinsam entwendet werden, ohne dass die Verbindung endet. Pullock ersetzt keine macOS-Authentisierung, FileVault oder Datensicherung.
- Root-/Kernel-Kompromittierung, vollständig eingefrorene Rechner und kompromittierter vertrauenswürdiger Code liegen außerhalb einer durchsetzbaren Schutzgarantie.
- Optionaler Shutdown bleibt ein später zu qualifizierender Modus. Er ist derzeit nicht implementiert oder getestet; ein Live-Shutdown wird durch keinen Build-/Testbefehl ausgelöst.

Vor Freigabe fehlen die durchgängige automatische Agent-/Daemon-Aktionskette, reale Removal-/Lock-/Power-/Session-Tests und Installation/Update/Uninstall. Der direkte Xcode-Export des bisherigen Testarchivs wurde mit Developer-ID-Signierung, akzeptierter Notarisierung, gültigem Ticket und Gatekeeper-Akzeptanz unabhängig bestätigt. Der neueste Funktionsstand muss diesen Distributionsweg ebenfalls durchlaufen. Der Kommandozeilenexport meldet weiterhin `No Accounts`; die funktionierende Xcode-Anmeldung wurde bestätigt.

## Website und Distribution

Die statische Next.js-Website liegt unter `apps/web`: Startseite, Ablauf, Kompatibilität, Sicherheit, Datenschutz, Support, Release-Status und Impressum. Der Nutzer hat zunächst die GitHub-Pages-Adresse `https://koljasagorski.github.io/pullock.app/` gewählt. Der Pages-Workflow prüft den Export vor jeder Veröffentlichung; die eigene Domain bleibt ein späterer Schritt. Downloads werden als GitHub Releases dieses Repositorys bereitgestellt, sobald die App ihre Funktions- und Distributionsprüfungen besteht. Es gibt noch keinen Download eines fertigen Schutzprodukts.

Das vom Nutzer bereitgestellte Logo und der Slogan sind in die native App übernommen. Die [Brand-Assets](assets/brand/README.md) enthalten beide Farbschemata, App-Icons und vorbereitete Website-Favicons. Anbieter ist gemäß Nutzerangabe [patchletter UG (haftungsbeschränkt)](https://patchletter.com/de/impressum); die Daten für das Pullock-Impressum sind [dokumentiert](docs/brand-owner.md).

Der lokale Review-Packager erzeugt App-/Source-Archive, Manifest und SHA-256-Prüfsummen. Er veröffentlicht nichts. Der separate Archivhelfer kann mit einem vorhandenen Apple-Zertifikat signieren und optional Xcodes Developer-ID-Export anstoßen; er führt keine Notarisierung oder Veröffentlichung aus.

## Lizenz

Es gilt der vorhandene GPL-v3-Lizenztext in [LICENSE](LICENSE). Source und Lizenz gehören zur Distribution. Pullock ist ein unabhängiges Projekt; YubiKey ist eine Marke von Yubico. Eine Unterstützung oder Partnerschaft wird nicht behauptet.

Historischer Architektur-/Abnahmeplan: [PLAN.md](PLAN.md). Maßgeblich für geänderte Produktannahmen sind die verlinkten neueren Entscheidungen und aktuellen Testberichte.
