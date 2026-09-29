# PullockServices

Native NSXPC-Verbindungen, ein flüchtiger Diagnose-Host und ein separat geprüfter Policy-Store. Der laufende Transport bietet ausschließlich Bootstrap, Hello und Health. Er lehnt Konfiguration, Arming, USB-Injektion und Aktionen ab.

- Client/Server prüfen die Signaturanforderung vor Aktivierung. Entwicklungsverbindungen pinnen das eigene Apple-Zertifikat und die exakte Peer-Bundle-ID. Ad-hoc-Binaries können diesen Weg nicht verwenden; Produktionsanforderungen bleiben Developer-ID-/Team-/rollenbegrenzt.
- Der Server erzeugt Verbindungs- und Boot-Kennungen; Nonce-Echo, Rollen, Reihenfolge und Snapshot-Ablauf werden geprüft. Keine sensiblen Daten vor dem Handshake.
- Pro Listener höchstens acht Verbindungen, 2 Sekunden für Handshake/Antwort, 5 Sekunden Inaktivität; Limits und Fehler schließen die Verbindung. Zwei Rollenlistener bedeuten maximal 16 angenommene Verbindungen insgesamt.
- Exportierte Methoden prüfen synchron die aktuelle OS-Verbindung und nochmals den Besitzer. Mutex/Actor schützen Zustand; schmale Sendable-Brücken erlauben nur OS-Credential-Lesen und Invalidation, keine parallele Neukonfiguration.
- Die Entwicklungsdiagnose prüft Konsolen-UID und Kernel-Audit-Session. `auditon` ist öffentlich, aber deprecated; Nichtverfügbarkeit verweigert Zugang. Das ist keine qualifizierte dauerhafte Owner-Autorität für Live-Aktionen.
- `PolicyStore.production()` verwendet nur den festen root-eigenen Pfad `/Library/Application Support/Pullock`. Descriptor-relative Zugriffe, private Modi, ACL-/Symlink-/Hardlink-/FIFO-Abweisung, nicht blockierende Dateisperre, Größen-/Schema-/Owner-/Revision-Prüfung und atomarer Austausch. Dieser Produktionspfad wird von den Diagnose-Diensten **nicht aufgerufen**. Tests benutzen isolierte temporäre Verzeichnisse.
- Eine flüchtige USB-Verbindungswahl wird niemals gespeichert.

Tests prüfen echte anonyme NSXPC-Verbindungen mit exakter Testhost-Code-Signatur, falsche Gegenstellensignaturen, Sitzungsentzug, Limits, Slotfreigabe und Leerlaufablauf. Sie sind kein Beweis für installierte, separat laufende Developer-ID-Dienste, Fast User Switching oder Root-Aktionssicherheit.

## Autorität und Command-Anbindung

`ProtectionAuthority` ist ein synchroner, Mutex-geschützter Host des Reducers. Der vertrauenswürdige Daemon liefert aktuelle Watcher-/Power-/Session-Ereignisse; Clients können keine Hardwareereignisse injizieren. Owner-Bindung, Rollengrenzen, aktuelle Verbindungsauswahl, Revisionen und Aktionsrückmeldungen werden erneut geprüft. Nur Lock-Verbindungs-Policies sind zulässig; der öffentliche Shortcut darf keine bestätigte Sperre zurückmelden. Effekte werden nach dem Commit abgeholt. Ein nicht bedienter Effektpuffer stoppt weitere Aktivierung, ohne Lock-Anforderungen zu verwerfen.

Native Listener können ausdrücklich einen Command-Handler erhalten. Dieser bekommt `ServicePeer` aus den aktuell geprüften OS-Credentials, nicht aus JSON. Der Default bleibt Health-only; die bestehenden Entwicklungs-Targets aktivieren keinen solchen Aktions-Handler. Die Defaults der Autorität erlauben ebenfalls kein reales ARMED. Tests mit Mock-Fähigkeiten prüfen die komplette Auswahl→Arm→Inventar→Removal→Ergebnis-Transaktion, aber keine echte Sitzungssperre.
