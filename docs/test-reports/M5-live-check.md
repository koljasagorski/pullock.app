# M5 — Abnahme des installierten Sperrtests

Vorbereiteter Stand: **0.4.1, Build 3, IPC-Protokoll 3**. Die nachstehenden realen Prüfungen sind **noch nicht durchgeführt**. Die 179 automatischen Tests ersetzen sie nicht. Kein Schritt dieses Dokuments wird von CI ausgeführt.

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
