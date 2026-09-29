# PullockActions

Expliziter öffentlicher macOS-Sperrkurzbefehl. `ShortcutLock` prüft Eingabeberechtigung, eigene aktive Konsolensitzung und das Q-Zeichen im Command-Layer des aktuellen Layouts. `requestLock()` erstellt beide Tastenevents und postet Control–Command–Q.

Der einzige erfolgreiche Rückgabewert lautet `requested`. Das Modul beobachtet keinen bestätigten Sperrerfolg. Es enthält weder private Lock-APIs noch AppleScript, Shell-Aufrufe oder Shutdown. `requestPermission()` ist ausschließlich für einen bewusst betätigten UI-Button bestimmt.

Fünf Tests verwenden einen internen Mock-Backend und posten niemals echte Eingaben. Die App linkt das Modul für den ausdrücklich gestarteten manuellen Test; der SessionAgent verwendet es nach authentifizierten automatischen Sperranforderungen. `requestPermissionForActiveSession()` prüft zusätzlich die aktive Sitzung und fordert nur beim expliziten Einrichtungsauftrag die eigene Berechtigung an. Der Root-Daemon linkt diesen Adapter nicht. [Produktentscheidung und Qualifikationsgrenzen](../../docs/decisions/0003-connection-switch-and-shortcut.md).
