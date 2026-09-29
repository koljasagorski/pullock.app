# PullockIPC

Version 1 des lokalen Nachrichtenvertrags. **Dieses Package authentisiert keinen Prozess und öffnet keinen XPC-Endpunkt.** Die spätere M4-Integration muss Signatur, Identifier, Team, effektive UID und Sitzung durch das Betriebssystem prüfen, bevor sie einen `WireSession` mit den daraus abgeleiteten Rollen erzeugt. Ein `hello(role:)` ist kein Herkunftsnachweis.

Vor dem ersten weiteren Request wird ein nicht sensitiver Hello geprüft. Boot-ID, Connection-ID, Protokollversion und steigende Sequenzen binden Nachrichten an die aktuelle Verbindung. Ein Verbindungswechsel verlangt eine neue Connection-ID und einen neuen Validator; alte Nachrichten werden nicht übernommen.

| Sender → Empfänger | Erlaubte Nachrichten nach Hello |
| --- | --- |
| App → Daemon | Health lesen, Policy setzen, Arm, Disarm, abgeschlossenen Trigger zurücksetzen |
| SessionAgent → Daemon | Health lesen, Fortschritt melden, Lock-Ergebnis melden |
| Daemon → SessionAgent | Health-Snapshot, eng begrenzte Lock-Anforderung |
| Daemon → App | Health-Snapshot |

Es existieren kein generischer Shutdown-Aufruf, kein Shell-/Pfad-/argv-Feld und kein vom Client einspeisbares USB-Event. Der SessionAgent kann keine Policy ändern und nicht disarmen. Der Lock-Kanal akzeptiert keine Shutdown-Aktion.

JSON-Pakete sind auf 16 KiB begrenzt. Unbekannte Felder/Operationen, ungültige Policy-Daten, veraltete Snapshots, falsche Rollen und unzulässige Sequenzen werden vor Rückgabe an den Host abgelehnt. Optionale bekannte Felder dürfen JSON-null sein; unbekannte Zusatzfelder auch in verschachtelten Strukturen nicht. Der Kern validiert Policy und Zustandswechsel anschließend erneut.

`StateSnapshot` wird ausschließlich als Health-Antwort verwendet und enthält keine rohe Gerätekennung. Policy-Transaktionen enthalten notwendige lokale Enrollment-Daten und dürfen deshalb erst nach der separaten OS-Authentisierung gesendet werden.

XPC-Lifetime, `NSSecureCoding`-/Klassen-Allowlist für den Transport, Signatur-/UID-Negativtests, Rate-Limits und tatsächliche Handshake-Timeouts gehören zu M4. Die vorliegenden Unit-Tests belegen den Nachrichtenvertrag, nicht diese noch fehlende Systemintegration.
