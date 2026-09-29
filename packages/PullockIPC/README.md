# PullockIPC

Version 1 des lokalen Nachrichtenvertrags sowie vorbereitende M4-Bausteine. **Dieses Package betreibt keine vollständige authentifizierte Dienstverbindung und öffnet keinen XPC-Listener.** Die Integration muss Signatur, Identifier, Team, effektive UID und Sitzung durch das Betriebssystem prüfen, bevor sie einen `WireSession` mit den daraus abgeleiteten Rollen erzeugt. Ein `hello(role:)` ist kein Herkunftsnachweis.

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

## Vorbereitete M4-Bausteine

- `DeveloperIDPeerRequirement` kompiliert eine feste Developer-ID-Anforderung aus validierter Team-ID und einer von drei konkreten Produktions-Identitäten. Keine frei vom Client gelieferten Identifier, Requirements oder ad-hoc-Ausnahmen.
- `IncomingPeerGate` konfiguriert einen neuen eingehenden NSXPC-Kanal vor dessen Aktivierung für genau eine feste Rolle. UID und Audit-Session kommen direkt von NSXPC. Jede exportierte Methode muss synchron vor einem Queue-/Actor-Wechsel `validateCurrentCall(owner:)` mit aktuell vertrauenswürdig ermittelter Owner-Sitzung aufrufen.
- `DaemonClientConnection` erzeugt einen noch inaktiven Kanal zu einem rollengetrennten Endpunkt im privilegierten System-Mach-Namespace und setzt die exakte Daemon-Signaturanforderung. Der Besitzer muss den Kanal aktivieren oder invalidieren; Konstruktion und API-Erfolg sind noch keine Authentisierung.
- `PullockXPCInterface` erlaubt ausschließlich `NSData` für Anfrage und Antwort. Vor JSON-Decoding bleibt die 16-KiB-Prüfung erforderlich. Die Grenze beschränkt nicht rückwirkend den Speicher, den das System beim Empfang eines XPC-Pakets verwendet.
- `ConnectionBudget` begrenzt parallele Requests auf 8 und den Burst auf 16; ein Token wird je 100 ms ergänzt. Einzelne Requests laufen nach 2 Sekunden ab. Fehler schließen das Modell dauerhaft. Der Host muss Fristen auch ohne neue Nachrichten prüfen und die tatsächliche Verbindung invalidieren.

Eine Listener-Integration mit globaler Verbindungsgrenze, Timer, korrekter Antwortbehandlung und gegenseitigem Hello fehlt noch. Die Owner-Sitzung darf niemals aus Client-Nachrichten konstruiert werden. Signaturanforderungen kontrollieren eingehende Nachrichten; die erste ausgehende Nachricht muss deshalb nicht sensitiv bleiben. Policy-Daten dürfen erst nach validierter Antwort fließen.

24 Tests prüfen den Nachrichtenvertrag und die neuen Regeln. Darunter: echte Kompilierung durch Apples Security-Framework, Ablehnung des Testprozesses durch alle Produktionsanforderungen, strikte Container-Allowlist, UID-/Sitzungsregeln sowie Mengen-/Raten-/Fristenfehler. Sie belegen noch **keine** positive signierte Verbindung, installierte Dienste oder eine fertige XPC-Sicherheitskette. Siehe [M4-Vorbereitung](../../docs/test-reports/M4-preparation.md).
