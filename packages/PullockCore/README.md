# PullockCore

Deterministischer Zustandskern ohne native Systemaktionen. Eingaben sind typisierte Ereignisse mit Boot-ID, Quelle, Sequenz und monotoner Beobachtungszeit; Seiteneffekte werden als Werte zurückgegeben. Der Host verarbeitet alle Eingaben seriell und führt Effekte erst nach dem Commit aus. Zwischen Prüfung und Zustandsänderung gibt es kein `await`.

```sh
swift test --package-path packages/PullockCore --scratch-path "$PULLOCK_PROBE_BUILD/core"
```

`PULLOCK_PROBE_BUILD` zuvor auf ein temporäres Buildverzeichnis setzen; vollständige Befehle stehen im [Entwicklungsleitfaden](../../docs/development.md).

## Verträge

- Alle Zeitwerte sind monotone Millisekunden seit derselben Host-Boot-Epoche. Der Transport darf keine Client-Zeit als autoritative Zeit behandeln. Der Host injiziert `at:` beziehungsweise eine `HealthClock`.
- Jede Quelle hat eine steigende Sequenz. Falsche Boot-IDs, Quellen, Zukunftszeiten und alte Sequenzen/Epochen werden verworfen. Health-Expiry wird auch bei verworfenen Nachrichten ausgewertet.
- Arming verlangt eine aktive Owner-Sitzung und eine passende Policy-Revision. Danach fordert der Kern einen neuen Inventory-Snapshot für die aktuelle Watcher-/Power-/Arming-Epoche an. Ein vor dem Arming gecachter Snapshot reicht nicht.
- Live-Qualifikationen kommen bei Konstruktion vom vertrauenswürdigen Host. Der Standard ist `unavailable`. Weder Preferences noch ein Wire-Befehl können Mock-Fähigkeiten in Live-Schutz umwandeln.
- Eine exakte, validierte Seriennummer, passende VID und freigegebene PID-Variante sind erforderlich. Mehrdeutige Identität führt zu ERROR. Rohkennungen bleiben interne Policy-/Beobachtungsdaten; öffentliche `StateSnapshot`-Werte enthalten sie nicht.
- Fortschrittszähler müssen pro Health-Komponente innerhalb ihrer Generation steigen. Wiederholtes Ping ohne Fortschritt verlängert keine Lease. Standard: 3000 ms; der Host muss auch bei Ereignisstille Ticks liefern.
- Fehler verriegeln die notwendige explizite Wiederaufnahme. Ein weiterhin gültiger Presence-Nachweis bleibt für eine echte Removal bestehen, solange keine Power-/Session-/Watcher-Grenze ihn verwirft. Health-Ausfall allein erzeugt höchstens eine Lock-Fallback-Anforderung je Arming-Zyklus, niemals Shutdown.
- Removal verriegelt einen Trigger pro Arming-Epoche. Reconnect/Disarm ändern ihn nicht. Die Effektliste enthält zuerst Lock und gegebenenfalls Shutdown; der spätere Host muss beide unabhängig zustellen, ohne auf den Abschluss des ersten zu warten.
- Nach Sleep werden Health und Presence neu aufgebaut. Abwesenheit nach Wake erzeugt keinen Removal-/Shutdown-Trigger. Sessionwechsel und Watcher-Neustart verlangen explizites erneutes Arming.
- `submitted`, `confirmed`, `failed`, `unknown` und `simulated` sind verschiedene Aktionsresultate. Ein Live-Request akzeptiert kein simuliertes Ergebnis. Ein expliziter Trigger-Reset ist erst nach terminalen Ergebnissen aller angeforderten Removal-Aktionen möglich.

`StateSnapshot.isProtected(at:)` prüft am Anzeigezeitpunkt Profil, Status, Invarianten und Ablaufzeit. Oberflächen dürfen `status == .armed` nicht allein als grünen Schutzstatus verwenden. Simulationen bleiben auch bei logisch scharfem Kern ungeschützt. Ein bloß angehaltener UI-Prozess kann sein letztes Bild dennoch nicht selbst ändern.

## Grenzen

Der Kern beweist weder die Ursache einer USB-Terminierung noch die physische Reihenfolge verschiedener OS-Eventquellen. Die Tests machen den Sleep-/Removal-Konflikt ausdrücklich sichtbar. Es gibt keine Persistenz, echte IPC-Authentisierung, native Gerätequelle oder ausführbare Lock-/Shutdown-Implementierung in diesem Target.

`PullockSimulation` ist ein getrenntes Produkt desselben Packages. Es enthält sechs illustrative Abläufe, eine manuelle Clock und einen idempotenten Mock-Recorder. Nur Entwicklungs-App und Tests linken es; die Daemon-/Agent-Targets verwenden `PullockCore` und `PullockIPC`.
