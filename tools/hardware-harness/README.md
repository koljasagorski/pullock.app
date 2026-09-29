# Pullock M1 Hardware Probe

Native, ungefährliche Machbarkeitsuntersuchung. **Dieses Werkzeug schützt und sperrt den Mac nicht.** Es installiert keine Dienste, verändert keine Key-Konfiguration und enthält keinen echten Lock-/Shutdown-Adapter.

## Bauen und testen

Lokal vorgesehen: Apple Silicon, macOS 27.0+, Xcode 27 und Swift 6.4. Die Paketbeschreibung verwendet Swift-6-Sprachmodus. Keine Drittanbieter-Abhängigkeiten. Befehle vom Repository-Stamm aus:

```sh
export PULLOCK_PROBE_BUILD=$(mktemp -d "${TMPDIR%/}/pullock-probe.XXXXXX")
swift test --package-path tools/hardware-harness --scratch-path "$PULLOCK_PROBE_BUILD"
swift build --package-path tools/hardware-harness --scratch-path "$PULLOCK_PROBE_BUILD" -c release
```

Das temporäre Buildverzeichnis vermeidet File-Provider-/Finder-Metadaten aus synchronisierten Projektordnern, an denen macOS die Signierung eines Testbundles ablehnen kann. Es enthält ausschließlich generierte Dateien. Zum erneuten Bauen in einer anderen Shell die Variable wieder setzen.

```sh
swift run --package-path tools/hardware-harness --scratch-path "$PULLOCK_PROBE_BUILD" pullock-probe inspect
swift run --package-path tools/hardware-harness --scratch-path "$PULLOCK_PROBE_BUILD" pullock-probe simulate
swift run --package-path tools/hardware-harness --scratch-path "$PULLOCK_PROBE_BUILD" pullock-probe watch --seconds 30
```

`inspect` registriert die Beobachter, leert die Initial-Iteratoren, gleicht den Bestand einmal ab und beendet sich. `watch` läuft standardmäßig 30 Sekunden, maximal 3600 Sekunden; Ctrl-C/SIGTERM beendet kontrolliert. `simulate` verwendet ausschließlich künstliche Presence-/Removal-Daten und initialisiert keine Hardwarebeobachter.

Die reine Event-Posting-Preflight-Abfrage liest die vorhandene Freigabe. Sie fragt keine Berechtigung an und sendet keine Tastaturereignisse. `event_posting_allowed=true` ist **kein** Nachweis einer funktionierenden Sperre.

## Harmlose Hardwareuntersuchung

1. Modell, Interface-Konfiguration, OS-Version und Direktanschluss/Adapter/Dock separat notieren. Das Werkzeug leitet diese Informationen nicht aus einer PID allein ab.
2. `watch --seconds 60` starten und den Test-Key einmal abziehen und wieder einstecken. Es werden nur Mock-Ereignisse aufgezeichnet; ein nicht eingeschriebener Key kann keine reale Aktion auslösen.
3. Nach Ablauf die JSONL-Ausgabe prüfen: neue `instance_token` nach Reconnect; falls passiv verfügbar, gleiche `serial_token` innerhalb desselben Laufs. `serial_status=present_unqualified` bedeutet nur beobachtet, nicht stabil oder echt bewiesen.
4. Erst in separat geplanten Durchläufen Portwechsel, einen zweiten Key, eigene Interface-Varianten, Sleep/Wake und Sitzungswechsel prüfen. Das Werkzeug löst diese Vorgänge nicht selbst aus.
5. Messergebnisse in der [Supportmatrix](../../docs/compatibility/M1.md) ergänzen. Firmware, Seriennummern, Koexistenz und Systemereignisse niemals aus einem leeren erfolgreichen Lauf ableiten.

Auf Wunsch lokal speichern:

```sh
mkdir -p .local
swift run --package-path tools/hardware-harness --scratch-path "$PULLOCK_PROBE_BUILD" \
  pullock-probe watch --seconds 60 > .local/probe.jsonl
```

Die Ausgabe erfolgt gesammelt **nach** dem Stoppen der Beobachter; damit blockiert eine langsame Pipe keine Power-Bestätigung. Bis dahin erscheint nur der Hinweis auf stderr. Der Speicherpuffer ist auf 10.000 Events und der aktuelle Gerätebestand auf 128 Yubico-Instanzen begrenzt. Überschreitungen/IOKit-Fehler markieren den Lauf als unvollständig und führen zu Exitcode 1; ungültige Argumente zu 64. Exitcode 0 bestätigt lediglich den abgeschlossenen Diagnoseablauf.

## Was die Ausgabe belegt

| Ereignis/Feld | Bedeutung |
| --- | --- |
| `observers_ready` | Notification-Registrierung, Initial-Drain und Bestandsabgleich abgeschlossen; kein Schutzstatus |
| `candidate` | Eine aktuelle `IOUSBHostDevice`-Instanz mit Yubico-VID beobachtet |
| `terminated` | Service-Instanz terminiert; mechanische Ursache unbekannt |
| `would_request_lock`, `executed=false` | Mock-Reaktion auf den Verlust einer zuvor beobachteten Instanz; keine Enrollment-/Arming-Policy |
| `serial_status=missing` | In den geprüften lokalen Registry-Eigenschaften keine Seriennummer verfügbar |
| `serial_status=invalid/conflicting` | Ungültiger Deskriptor oder widersprüchliche Quellen; kein Identitätsnachweis |
| `serial_status=present_unqualified` | Begrenzte nichtleere Kennung passiv gelesen; Stabilität noch zu testen |
| `power_epoch` | Diagnose-Epoche nach verworfener Presence, auch bei Session-/Fehlergrenzen |
| `lock_state=unknown` | Öffentliche Session-Eigenschaften liefern hier keinen Sperrnachweis |

Zähler und Zeitstempel messen **Callback-Verarbeitung im Prozess**. Sie sind kein Beleg für physische E2E-Latenz oder eine gemeinsame Reihenfolge von Power- und USB-Ereignissen. Die bewusst kleine Mock-Logik ist nicht der M2-Reducer: alle beobachteten Yubico-Instanzen können eine Mock-Reaktion erzeugen, auch bei fehlender Seriennummer; sie kennt keine echte Scharfschaltung und keine persistente Identität.

## Daten und Quellcodegrenzen

Es werden ausschließlich bekannte IORegistry-Eigenschaften physischer Yubico-USB-Services gelesen. Keine Credential-/Management-/HID-/CCID-Abfragen, kein exklusives USB-Öffnen, kein Polling externer Programme. Bereinigte Ausgabe enthält VID/PID, Quellen-/Qualitätsstatus und HMAC-Tokens mit zufälligem Schlüssel pro Lauf. Rohseriennummern, Registry-IDs, Benutzernamen und UIDs fehlen. Die Tokens sind zwischen Läufen absichtlich nicht vergleichbar; auch bereinigte Reports vor Veröffentlichung prüfen.

`PowerMessagesC` macht fünf öffentliche SDK-Makros für Swift verfügbar; es enthält keine Aktionsimplementierung. Swift kann die verschachtelten `iokit_common_msg`-Makros nicht direkt importieren. Der Compiler berechnet die Werte aus dem installierten SDK.

Power-Callbacks bestätigen nur die zwei vom SDK vorgeschriebenen Sleep-Meldungen und blockieren Sleep nicht. Session-/Workspace-Meldungen ergänzen die Beobachtung. Quelle und Lebensdauer der geplanten root-seitigen Sitzungskontrolle bleiben Gegenstand von M4/M8.

Ergebnisse und offene Gates: [M1-Bericht](../../docs/test-reports/M1.md), [API-Entscheidungen](../../docs/decisions/0001-m1-feasibility.md).
