# ADR 0002 — Sichere Weiterarbeit nach M1

Datum: 29. September 2026. Status: umgesetzt für M2.

Nach dem M1-Bericht hat der Benutzer mit „immer weiter“ die fortlaufende Entwicklungsarbeit autorisiert. Die frühere organisatorische Pause nach jedem Meilenstein ist damit für sichere Implementierungsarbeit aufgehoben. Die bekannten fachlichen Grenzen werden dadurch weder gelöst noch als bestanden umgedeutet.

## Entscheidung

Der deterministische Zustandskern, der Nachrichtenvertrag, Mock-Aktionen, automatisierte Prüfungen und native Entwicklungshüllen werden aufgebaut, obwohl M1 noch keinen qualifizierten Live-Sperrweg und für den beobachteten Key keine passive Seriennummer belegt hat. Diese Arbeit ist unabhängig von der Wahl einer späteren Lock-/Identitätsalternative prüfbar.

Live- und Simulationsprofil sind explizit getrennt. Live startet mit nicht verfügbaren Aktionsfähigkeiten. Die Oberfläche bietet ausschließlich bezeichnete Simulationen und zeigt kein grünes echtes ARMED. Der Daemon linkt weder das Simulationsprodukt noch einen realen Aktionsadapter. Agent und Daemon werden nicht als Dienste registriert.

Der IPC-Vertrag ist bereits rollenbegrenzt und versioniert, stellt jedoch ausdrücklich **keine** OS-Authentisierung dar. Es existiert noch kein laufender XPC-Endpunkt. Ein erfolgreicher Schema-/Handshake-Test kann deshalb keinen gesunden produktiven Dienst vortäuschen.

Die Automatismen des sicheren Builds dürfen weder echte Sperren/Shutdowns auslösen noch Key-Konfigurationen verändern. Ein Produktionsrelease, ein qualifizierter Live-Adapter und die physische Hardwarematrix behalten ihre Nachweispflichten. Session-Key-Modus, aktive Key-Abfragen oder Accessibility-basierter Lock werden nicht aus dem allgemeinen Weiterarbeitsauftrag als fachlich akzeptierte Scope-Änderung abgeleitet.

## Präzisierungen für M2

- Ein Arm-Request fordert einen frischen Inventory-Snapshot derselben Watcher-/Power-/Arming-Epoche. Die GUI darf einen angenommenen Request nicht als ARMED interpretieren. Während System-Sleep wird die Enumeration bis Wake aufgeschoben.
- Health-Leases setzen steigenden Verarbeitungsfortschritt voraus. Ein bloßer wiederholter Ping hält ARMED nicht frisch. Nach Fehlerbehebung ist eine explizite neue Scharfschaltung erforderlich.
- Ein zuvor gebundenes Gerät bleibt im Fehlerzustand für einen späteren Removal-Trigger relevant; Power-/Session-/Watcher-Grenzen verwerfen diesen Nachweis. Alle Trigger bleiben verriegelt, bis Ergebnisse vorliegen und der Benutzer ausdrücklich zurücksetzt.
- Für Lock + Shutdown enthält der Reducer zwei getrennte Effekte in Anforderungsreihenfolge. Eine spätere Ausführung darf den Shutdown nicht vom Abschluss des Lock-Aufrufs abhängig machen. M2 beweist nur diesen Vertrag, nicht echte Scheduler-/XPC-Latenzen.
- Öffentlich dargestellte Snapshots enthalten keine Rohkennung. Empfänger prüfen Ablaufzeit und strukturelle ARMED-Invarianten erneut.

## Konsequenz

M2 ist eine funktionsfähige sichere Entwicklungsbasis, kein freigegebenes Schutzprodukt. M3 kann darauf mit passiver USB-Beobachtung und strikt abgelehntem Enrollment unqualifizierter Keys aufbauen. Die fortbestehenden M1-Grenzen stehen weiterhin in [Supportmatrix](../compatibility/M1.md) und [M1-Entscheidungen](0001-m1-feasibility.md).
