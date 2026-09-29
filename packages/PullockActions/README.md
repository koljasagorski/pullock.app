# PullockActions

Expliziter öffentlicher macOS-Sperrkurzbefehl. `ShortcutLock` prüft Eingabeberechtigung, eigene aktive Konsolensitzung und das Q-Zeichen im Command-Layer des aktuellen Layouts. `requestLock()` erstellt beide Tastenevents und postet Control–Command–Q.

Der einzige erfolgreiche Rückgabewert lautet `requested`. Das Modul beobachtet keinen bestätigten Sperrerfolg. Es enthält weder private Lock-APIs noch AppleScript, Shell-Aufrufe oder Shutdown. `requestPermission()` ist ausschließlich für einen bewusst betätigten UI-Button bestimmt.

Tests verwenden einen internen Mock-Backend und posten niemals echte Eingaben. Gegenwärtig linkt nur die App das Modul für einen ausdrücklich gestarteten manuellen Test. Agent und Daemon enthalten noch keinen echten Aktionsadapter. [Produktentscheidung und Qualifikationsgrenzen](../../docs/decisions/0003-connection-switch-and-shortcut.md).
