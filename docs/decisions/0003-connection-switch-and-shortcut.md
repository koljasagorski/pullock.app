# ADR 0003 — Gewählte USB-Verbindung und öffentlicher Sperrkurzbefehl

Datum: 29. September 2026. Status: vom Nutzer beauftragt; implementiert, reale Qualifikation ausstehend.

Der Nutzer hat präzisiert, dass das Gerät nur als physischer Killswitch dient: Beliebigen angeschlossenen USB-Stick in der App auswählen; Inhalt und dauerhafte Geräteidentität sind dafür unerheblich. Anschließend wurde der öffentliche Sperrweg mit erforderlicher macOS-Eingabeberechtigung und ehrlicher Meldung „Sperre angefordert“ ausdrücklich beauftragt.

Diese Entscheidung ersetzt für die erste App die bisherige Pflicht zu einer passiven YubiKey-Seriennummer und die offene Produktentscheidung über einen Eingabe-basierten Lock. Sie gibt keine realen automatischen Sperrtests oder Shutdowns auf dem Arbeitsrechner frei.

## USB-Modell

- Die App zeigt passiv beobachtete `IOUSBHostDevice`-Instanzen verschiedener Hersteller; Inhalte, Volumes und Authentisierungsinterfaces werden nicht geöffnet.
- Gewählt wird eine konkrete aktuell vorhandene Registry-Instanz. Gleiche VID/PID, Produktnamen oder Seriennummern ersetzen diese Instanz nicht.
- Die Auswahl ist flüchtig: Entfernung, fehlender Abgleich, Watcher-Neustart, Sleep oder Sitzungswechsel machen sie ungültig. Neustart stellt keine Auswahl wieder her. Danach erneut auswählen und ausdrücklich aktivieren.
- Der Zustandskern bindet eine Auswahl an Daemon-Boot, Watcher- und Power-Epoche. Er akzeptiert sie nur für seine aktuelle Inventarliste. Der Policy-Store verweigert die Speicherung solcher Verbindungswahlen.
- Das Ende einer USB-Service-Instanz kann auch durch Hub-/Bus-Reset entstehen. Die App kann den mechanischen Grund nicht beweisen. Shutdown wird dadurch nicht qualifiziert.
- Die bisherige Seriennummern-Implementierung bleibt als getesteter separater Weg vorhanden, ist aber keine Voraussetzung dieser neuen Auswahl.

## Sperrweg

`PullockActions.ShortcutLock` verwendet öffentliche CoreGraphics-APIs für Control–Command–Q. Der Q-Keycode wird aus dem Command-Layer des aktuellen Tastaturlayouts aufgelöst, nicht für jedes Layout fest angenommen. Vor Auslösung werden Eingabeberechtigung und aktive eigene Konsolensitzung geprüft. Beide Tastenevents werden vor dem ersten Posten erstellt.

Konstruktion, Preflight, CI und Selbstdiagnose lösen weder Eingaben noch Berechtigungsdialoge aus. Der Berechtigungsaufruf und ein echter manueller Sperrtest sind ausschließlich eigene UI-Aktionen. Die App zeigt nach erfolgreicher Event-Übergabe **Lock requested**, niemals eine automatisch bestätigte Sperre. Auch ein erfolgreicher Post-Aufruf garantiert keine Sperre bei umkonfigurierten Shortcuts oder Systemproblemen.

Für eine Freigabe fehlen weiterhin reale Sperr-/Removal-Tests, integrierte Agent-/Daemon-Aktionsausführung, Power-/Session-Matrix sowie signierte Installation und Distribution. Native XPC-Health-Tests und Mock-Eingabetests ersetzen diese Nachweise nicht.

Quellen: [Apple: Control–Command–Q](https://support.apple.com/en-ie/102650), [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent), [Preflight](https://developer.apple.com/documentation/coregraphics/cgpreflightposteventaccess()).
