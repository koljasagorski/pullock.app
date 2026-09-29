# M5 — Abnahme des installierten Sperrtests

Installierter Stand: **0.4.1, Build 4, IPC-Protokoll 3**. Exportprüfung, lokale Installation, App-Start und laufende Hintergrunddienste sind bestätigt. Die eigene Sperrbereitschaft des SessionAgent und die nachstehenden realen Sperrprüfungen sind **noch nicht bestätigt**. Die 179 automatischen Tests ersetzen sie nicht. Kein Schritt dieses Dokuments wird von CI ausgeführt.

## Bestätigter Export und lokaler Start

Geprüft auf Apple Silicon, **macOS 27.0.1 (26A434)** am vorhandenen Entwicklungs-Mac:

- Der vom Nutzer übergebene Export enthält Version 0.4.1 und Build 4. Sein äußerer Ordner hatte keine `.app`-Endung; eine Kopie wurde als `PullockDevelopment.app` geprüft und installiert. Der Originalexport blieb unverändert.
- App, SessionAgent und Daemon bestehen strikte Signaturprüfung, Developer ID Application, dieselbe Team-ID, Hardened Runtime und die exakten, auf das App-Zertifikat gebundenen XPC-Identifier-Anforderungen. Kein Debug-Entitlement.
- `stapler validate` und Gatekeeper-Prüfung bestehen vor und nach der Installation.
- Alle Dateien der Installation unter `/Applications/PullockDevelopment.app` sind bytegleich mit der geprüften Exportkopie. Es wurde keine vorhandene App überschrieben.
- Die drei installierten Binaries bestehen `--self-check` mit Protokoll 3 und null Aktionen. Der anschließend geöffnete App-Prozess wurde am Installationspfad nachgewiesen.
- Der installierte Daemon besteht die separate passive USB-/Power-/Sitzungsprüfung. Dabei waren null USB-Geräte sichtbar; es wurden weder ein Listener gestartet noch Aktionen ausgeführt.

Maschinenbezogene Prüfsummen und der lokale Prüfbeleg bleiben außerhalb von Git. Die Installation auf dem vorhandenen Entwicklungs-Mac ersetzt keine frische Systeminstallation.

## Bestätigte Dienstregistrierung

- Der Nutzer meldet in der App **Authenticated device connection** und nach erneuter Registrierung für den SessionAgent **Registered and approved**.
- Unabhängig davon zeigt `launchctl` den Daemon im Systembereich und den SessionAgent in der GUI-Sitzung als registriert und laufend, jeweils mit einem Start und ohne vorherigen Exit. Die erste Prüfung hatte nur den Daemon bestätigt; erst nach dem zweiten Registrierungsschritt liefen beide Helfer.
- Die App-Anzeige ist der Nutzerbericht zur authentifizierten Verbindung. Laufende Prozesse allein beweisen weder die Sperrbereitschaft des Agenten noch einen erfolgreichen Sperrvorgang; diese Prüfungen stehen noch aus.

## Installation und Einrichtung

1. Das aktuelle `PullockDevelopment.xcarchive` in Xcodes Organizer über **Distribute App → Direct Distribution** exportieren. Apple-Anmeldung und Developer-ID-Zertifikat sind bereits eingerichtet; der bekannte CLI-Fehler `No Accounts` verlangt keine erneute Anmeldung. Den exportierten App-Pfad für die anschließende Signatur-, Ticket- und Gatekeeper-Prüfung festhalten.
2. Nur den verifizierten Export unter `/Applications/PullockDevelopment.app` installieren. Bei einem Update zuerst disarmen und die alten Dienste über die alte App entfernen. Alle drei Komponenten müssen gemeinsam auf Protokoll 3 aktualisiert werden.
3. App öffnen → **Set up services… → Register services**. Erforderliche macOS-Adminfreigabe abschließen; beide Registrierungsanzeigen prüfen.
4. **Check connection** wählen. Im entschärften Zustand **Request session agent permission** anklicken. Den Systemdialog beziehungsweise die Accessibility-Einstellungen abschließen. Bei fehlendem Dialog zeigt **Show session agent in Finder** das hinzuzufügende Binary. Die Anfrage soll weder sperren noch beim nächsten Login erneut erscheinen.
5. Zur App zurückkehren. Der SessionAgent muss seine eigene Readiness melden. Die Berechtigung des separaten manuellen App-Tests genügt nicht.

## Bewusster Funktionstest

Vor jedem Sperrtest laufende Arbeit sichern und die normale Entsperrmethode bereithalten. Die eigentliche Sperranforderung wird erst durch den ausdrücklichen ARM-Dialog freigegeben.

| Prüfung | Erwartetes Verhalten | Ergebnis |
| --- | --- | --- |
| Auswahl | Ein sichtbares USB-Gerät auswählen; kein Inhaltszugriff | Offen |
| ARM | Dialog bestätigen; frischer Zustand zeigt „Armed · lock requests enabled“ | Offen |
| Fremdes Gerät entfernen | Gewählte Verbindung bleibt scharf, keine Sperranforderung | Offen |
| Gewähltes Gerät entfernen | Tatsächlicher macOS-Sperrbildschirm erscheint; normale Authentisierung erforderlich | Offen |
| Replug | Trigger bleibt verriegelt; Reset und neue Auswahl erforderlich | Offen |
| Disarm | Danach verursacht Removal keine neue Anforderung | Offen |
| Sleep/Wake | Auswahl verfällt; alte Berechtigungsanfrage erscheint nach Wake nicht verspätet | Offen |
| Berechtigung entziehen | Readiness fällt aus; kein neues ARM möglich | Offen |
| Berechtigung erneuern | Nur ausdrücklich angeforderte Einrichtung; aktueller Preflight entscheidet | Offen |
| Dienste entfernen | Disarm, Unregister, beide Statusanzeigen und fehlende Prozesse prüfen | Offen |

Pro Test App-Build, macOS-Version, Gerätetyp, Port/Hub und tatsächlich beobachtetes Verhalten festhalten. Keine Seriennummern, Passwörter oder privaten Systemlogs veröffentlichen. „Lock requested“ beziehungsweise `unknown` sind keine automatisch bestätigte Sperre.

Diese erste lokale Abnahme ersetzt weder die gesamte [System-/Hardwarematrix](../../PLAN.md) noch die [Release-Voraussetzungen](../release/README.md). Der deprecated Owner-/Session-Prüfweg, UI-Abnahme, Updateverhalten und das frische Testsystem bleiben gesonderte Nachweispunkte.
