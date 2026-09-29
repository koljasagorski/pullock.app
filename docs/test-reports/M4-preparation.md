# M4 — Rollen- und Verbindungsregeln vorbereitet

Stand: 29. September 2026. **M4 ist begonnen, nicht abgeschlossen.** Vorbereitende Regeln liegen in `PullockIPC`; Agent und Daemon bleiben ungefährliche Entwicklungshüllen ohne Listener oder Service-Registrierung.

## Implementiert

Produktive Signaturanforderungen beschränken sich auf Developer ID, eine validierte zehnstellige Team-ID und den exakten Identifier der App, des SessionAgents oder Daemons. Die Anforderungen werden vor Übergabe an NSXPC durch `SecRequirementCreateWithString` geprüft. Es gibt weder PID-basierte Signaturprüfung noch eine freischaltbare ad-hoc-Ausnahme.

Die geplanten Daemon-Endpunkte sind nach App und Agent getrennt: `app.pullock.daemon.app` und `app.pullock.daemon.session-agent`. Der Listener muss jedem Endpunkt seine feste Rollenanforderung zuordnen. Ein Wire-Hello kann diese Rolle nicht ändern. Die vorbereitete Client-Verbindung benutzt den privilegierten System-Mach-Namespace und fordert die genaue Daemon-Identität.

Ein eingehender Kanal wird vor Aktivierung auf die OS-abgeleitete effektive UID und Audit-Session geprüft. Bei jedem Methodenaufruf prüft der Gate zusätzlich die aktuelle NSXPC-Verbindung und frische vertrauenswürdige Owner-/Sessiondaten. Die Prüfung muss im synchronen exportierten Methodenaufruf vor einem Actor-/Queue-Wechsel stattfinden.

Das typisierte XPC-Interface hat ausschließlich einen `NSData`-Container für Request und Antwort. JSON-Decoding folgt erst nach der Größenprüfung. Das neue Budgetmodell begrenzt Requests, Rate und Fristen und bleibt nach einem Verstoß geschlossen.

## Durchgeführte Prüfungen

`PullockIPC`: **24 Tests bestanden**, davon 13 neue Prüfungen. Die drei produktiven Requirements wurden durch Apples Security-Framework kompiliert. Keine davon akzeptierte den laufenden Testprozess. Team-ID-Injection, Root-/Fremd-UID, falsche oder inaktive Sitzung, ungültige Ownerwerte und unzulässige Client-Rolle wurden abgelehnt. Die native NSXPC-Klassen-Allowlist enthielt ausschließlich den vorgesehenen Datencontainer.

Die Budgettests prüfen Übergröße vor Decoding, maximal acht offene Requests, Burst trotz sofortiger Antworten, zeitabhängiges Nachfüllen, exakt ablaufende Fristen, späte/doppelte Antworten, Clock-Rücklauf, Integer-Grenzen und explizite Invalidierung. Größen-, Mengen-, Raten- und Fristenfehler verwerfen sämtliche offenen Requests im Modell.

Die gemeinsame lokale Gesamtprüfung bestand mit **83 Tests**, Debug-/Release-Builds der drei nativen Targets sowie deren Selbstdiagnosen, Signatur- und direkten Importprüfungen. Es wurden dabei keine Dienste gestartet oder reale Systemaktionen ausgeführt. Eine erfolgreiche Regelprüfung allein ist kein Systemintegrationsnachweis.

## Noch offen

- Rollengetrennte tatsächliche Listener, gegenseitiger harmloser Handshake und Verbindung zum Reducer.
- Vertrauenswürdige Ermittlung und Aktualisierung der Owner-/Audit-Session im installierten Prozessverbund.
- Globale Verbindungsgrenzen, echte Deadline-Timer, Rückruf-/Abbruchbehandlung und Prozessausfälle.
- Positive und negative Tests mit tatsächlich getrennten, passend beziehungsweise falsch signierten Prozessen.
- SMAppService-Bündelung, Registrierung/Freigabe/Entzug, sicherer root-Policy-Store und Install-/Update-/Uninstall-Tests.

Kein installierter Kanal verwendet diese Regeln bisher; deswegen wird keine fertige XPC-Authentisierung behauptet. Auch bleibt ein erster ausgehender Request grundsätzlich nicht sensitiv: die eingehende Signaturprüfung beweist den Empfänger nicht vorab.

Referenzen: lokaler macOS-27-SDK-Header `Foundation/NSXPCConnection.h`, [Apple: setCodeSigningRequirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)), [Apple DTS zur XPC-Signaturprüfung](https://developer.apple.com/forums/thread/681053), [Apple: Code Signing Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).
