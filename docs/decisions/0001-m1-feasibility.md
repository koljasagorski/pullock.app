# ADR 0001 — M1-Machbarkeit und verbleibende Gates

Datum: 29. September 2026. Status: Untersuchungsentscheidungen umgesetzt; **keine Freigabe eines Schutzprodukts oder von M2**.

Der Auftrag „starte den plan“ gibt M1 nach dem dokumentierten M0-Plan frei. Die Untersuchung liegt isoliert unter `tools/hardware-harness`; Produktionskern, App-Hüllen, Dienste und Website folgen erst ihren eigenen Meilensteinen. Die im Plan festgehaltenen Sicherheitsanforderungen bleiben bestehen.

## Sitzungssperre

Die öffentliche SDK-Oberfläche von CoreGraphics (`CGSession.h`, `CGEvent.h`), AppKit, Security und ServiceManagement wurde erneut geprüft. Es wurde keine direkt dokumentierte lokale Lock-Funktion samt belastbarer öffentlicher Erfolgsbestätigung identifiziert. Diese Aussage beschreibt den Suchbefund, keinen Vollständigkeitsbeweis über alle Apple-APIs.

`CGPreflightPostEventAccess` ist eine lesende Freigabeprüfung. Control-Command-Q ist eine dokumentierte Benutzeraktion. Daraus folgt keine zugesicherte Wirkung synthetischer Events in jeder Sitzung. Deshalb gibt es in M1 keinen Event-Posting-Adapter, keinen Permission-Request und keinen Versuch, einen Lock zu bestätigen. Siehe [Apple: Preflight](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()) und [Apple: Tastaturkurzbefehle](https://support.apple.com/en-ie/102650).

`CGSessionCopyCurrentDictionary` liefert laut öffentlichem SDK unter anderem Console-Zugehörigkeit, abgeschlossenen Login und die Benutzer-ID. Ein dokumentierter Schlüssel zum Nachweis der Bildschirmsperre fehlt in diesem Header. Das Werkzeug liest ausschließlich diese öffentlichen Kontextfelder und gibt `lock_state=unknown` aus; es protokolliert weder Benutzer-ID noch Benutzername. Aktive Sitzung und abgeschlossener Login werden nicht als entsperrt interpretiert.

Private APIs, interne `CGSession`-Programme, private Notifications, Screensaver und Overlay-Ersatz bleiben ausgeschlossen. Der dokumentierte [MDM-DeviceLock-Befehl](https://developer.apple.com/documentation/devicemanagement/devicelockcommand) wäre eine andere Produktarchitektur. EndpointSecurity wäre eine separate Entitlement-/Integrationsentscheidung und löst die lokale Sperranforderung nicht automatisch.

**Gate bleibt offen:** Vor M2 entweder einen qualifizierbaren öffentlichen Weg belegen oder ausdrücklich ein eingeschränktes Betriebsprofil entscheiden. Eine mögliche Accessibility-/Systemaktionslösung müsste Berechtigungsentzug, Secure Input, Layouts, modale Fenster, Fullscreen, Last und Sessionwechsel prüfen; ein gesendetes Event dürfte nur `requestSubmitted`/`unknown` ergeben. M1 aktiviert diese Alternative nicht stillschweigend.

Eine konkrete, noch **nicht versendete** [DTS-/Feedback-Frage](apple-lock-question.md) ist vorbereitet.

## USB-Identität

Die Untersuchung verwendet physische `IOUSBHostDevice`-Services mit VID `0x1050`, die SDK-Konstanten für VID/PID und `kUSBHostDevicePropertySerialNumberString` sowie den benannten Legacy-Registry-Schlüssel `USB Serial Number`. Sie verändert keine USB-Eigenschaften. Werte werden typgeprüft, begrenzt und exakt verglichen; widersprüchliche Quellen werden verworfen. Eine gelesene Kennung bleibt `present_unqualified`.

Yubicos [Geräteübersicht](https://developers.yubico.com/Developer_Program/Guides/YubiKey_Hardware.html) beschreibt Seriennummern und Composite-Interfaces. Die [Management-Dokumentation](https://developers.yubico.com/yubikey-manager/Config_Reference.html) beschreibt aktive Geräteinformations-Kommandos. Eine über ein solches Kommando lesbare Seriennummer belegt ihre passive Verfügbarkeit im USB-Deskriptor nicht. M1 führt kein solches Kommando aus.

**Gate bleibt hardwareabhängig:** Reconnect, Portwechsel, zweite Geräte, PID-/Interface-Konfigurationen und stabile Kennungen müssen tatsächlich beobachtet werden. Ohne Kennung kein persistentes spezifisches Enrollment. Session-Key-Modus oder aktive Herstellerabfrage bedürften der im Plan genannten Scope-Entscheidung.

## USB-/Power-Reihenfolge

Attach- und Termination-Notifications werden separat mit eigenen Matching-Dictionaries registriert und initial vollständig geleert; ein einmaliger Snapshot ergänzt den Bootstrap. Callbacks werden auf einer seriellen Main Queue verarbeitet. Die Untersuchung ist kein privilegierter Dienst und diese Queue ist keine Festlegung für die spätere Daemon-Implementierung. Siehe [Apple: Matching Notifications](https://developer.apple.com/documentation/iokit/1514362-ioserviceaddmatchingnotification).

Nachgewiesen im aktuellen `IOPMLib.h`: `IORegisterForSystemPower` liefert Sleep-/Wake-, aber keine Shutdown-/Restart-Notifications. `canSleep` und `willSleep` verlangen Bestätigung, `willPowerOn`/`hasPoweredOn` nicht. Die Untersuchung bestätigt vor Logging/Enumeration und greift während frühem Wake nicht auf Geräte zu. Bestandsabgleich erst nach abgeschlossenem Wake. Session-Deaktivierung verwirft Presence; Display-Sleep allein tut dies nicht.

Die seriellen Callbacks schaffen **keine belegte gemeinsame Ereignisordnung** zwischen USB und Power. Ein deterministischer Test demonstriert ausdrücklich unterschiedliche Mock-Ergebnisse für `termination → willSleep` und `willSleep → termination`. Dies ist ein reproduzierbarer Grenzfall und keine bestandene Hardwarequalifikation. Automatischer Shutdown bleibt ausgeschlossen.

NSWorkspace liefert ergänzende Session-, Display-, Sleep-/Wake- und Power-off-Meldungen in der Benutzersitzung. Für Root-Daemon, Fast User Switching, Logout und Teardown ist deren sichere Zuordnung später mit authentifiziertem SessionAgent zu prüfen. Eine Subscription allein bestätigt keine vollständige Zustellung auf Zielhardware.

## Konsequenz

M1 liefert einen kompilierbaren, testbaren Diagnoseaufbau und dokumentierte Grenzen. Ein erfolgreiches Diagnoseresultat bedeutet weder ARMED noch PROTECTED. [Bericht](../test-reports/M1.md) und [Kompatibilitätsmatrix](../compatibility/M1.md) trennen durchgeführte Prüfungen von offenen Hardware- und Release-Gates.
