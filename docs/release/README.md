# Vorbereitung des ersten GitHub-Releases

Der Benutzer hat die Veröffentlichung der ersten fertigen App auf GitHub beauftragt. Nach erfüllten Build-, Funktions- und Distributionsbedingungen ist keine weitere organisatorische Freigabe nötig. Der aktuelle Entwicklungsstand ist noch kein Schutzprodukt.

## Bereits ausführbar

Die gemeinsame Prüfung baut Debug und Release und überprüft Tests, Selbstdiagnosen, Signaturen und direkte Imports. Ein anschließender lokaler Verpackungsschritt erzeugt App-ZIP, Source-ZIP mit Lizenz, Manifest und SHA-256-Prüfsummen. Er überprüft außerdem die Signatur der wieder entpackten App und überschreibt keine vorhandenen Pakete.

```sh
export PULLOCK_VALIDATION_ROOT=$(mktemp -d "${TMPDIR%/}/pullock-release-review.XXXXXX")
bash tools/validation/check.sh
python3 tools/release/package-development.py \
  --products "$PULLOCK_VALIDATION_ROOT/xcode/Build/Products/Release" \
  --output "$PULLOCK_VALIDATION_ROOT/review-bundle"
```

Das Ergebnis heißt ausdrücklich `PullockDevelopment` und ist nur für die lokale Prüfung bestimmt. Der Quellstand enthält den integrierten automatischen Sperrtest; dieses ad-hoc-signierte, nicht notarisierte Paket kann jedoch keine authentifizierten installierten Dienste bereitstellen. Deshalb meldet das Manifest `automaticActions: false` für dieses Paket und zusätzlich `automaticActionCodeIncluded: true` mit den nötigen Voraussetzungen. Der manuelle App-Sperrtest bleibt eine ausdrücklich bestätigte UI-Aktion. Der Packager lädt nichts hoch, erzeugt keinen Tag und behauptet keine bitidentischen Xcode-Builds. Die Source-Dateien werden einzeln gehasht; der Manifest-Digest identifiziert diesen Quellstand unabhängig vom lokalen Git-Index.

## Noch offene Bedingungen

| Bedingung | Tatsächlicher Stand |
| --- | --- |
| USB-Identität und reale Wiedererkennung | Nutzerentscheidung: beliebige aktuelle USB-Verbindung ohne Seriennummer auswählen; implementiert, reale Removal-Matrix offen |
| Sitzungssperre und ehrliches Erfolgskriterium | Öffentlicher Control–Command–Q-Adapter in manuellem Test und Agent integriert; keine behauptete Sperrbestätigung, reale Tests offen |
| Dienste, authentifiziertes XPC, sichere Konfiguration | Autoritative Beobachtung/Auswahl, Policy-Store, Rückkanal, Lease-Watchdog und ausdrückliche Agent-Berechtigungseinrichtung; integrierte Mock-Kette bestanden. Build 4 korrigiert Helfer-Signierkennungen und prüft die exakten XPC-Anforderungen; installierte Prüfung offen |
| Power, Session, Koexistenz, Fehlerszenarien | Modelltests vorhanden; reale Matrix offen |
| UI, Installation, Update und Uninstall | USB-Auswahl, Diagnose- und Sperrtestfenster; Produkt-/Installationsabnahme offen |
| Developer ID Application / Installer | Bezahltes Team in Xcode bestätigt. Direkter Organizer-Export des Testarchivs erfolgreich; App und beide Helfer mit Developer ID Application signiert. Installer nur für ein späteres PKG erforderlich |
| Notarisierung, Stapling, Gatekeeper, frisches Testsystem | Export von 0.4.1 Build 4 besteht Developer ID, exakte XPC-Anforderungen, Stapling und Gatekeeper vor/nach lokaler Installation. App-Start und installierte Selbsttests bestanden; Dienst-/Sperrtest und frisches Testsystem offen |
| Privater Sicherheitsmeldeweg | Vor ausführbarem öffentlichem Release festlegen und verifizieren |

Diese Tabelle ist ein Nachweisstand, keine automatische Freigabe durch umgesetzte boolesche Flags. Ein erfolgreicher Paket- oder CI-Build ersetzt die fehlenden Prüfungen nicht.

Aktuell lokal installiert: **0.4.1, Build 4, IPC 3**. Der notarisiert exportierte Developer-ID-Build besteht die genauen Zertifikat-/Identifier-Anforderungen von App, Agent und Daemon. Frühere Archive enthielten abweichende Helfer-Kennungen, die trotz gültiger Signaturen den authentifizierten Verbindungsaufbau verhindern; deren Notarisierung ist kein Funktionsnachweis. Der nächste Schritt ist die [installierte Dienst- und Sperrabnahme](../test-reports/M5-live-check.md) des korrigierten Builds.

## Veröffentlichung nach Qualifikation

1. Den tatsächlich geprüften Commit festlegen und CI genau dieses Commits prüfen. Git-Tag und Artefakte müssen zum selben Quellstand gehören.
2. Die produktiven ausführbaren Komponenten mit Developer ID Application und Hardened Runtime signieren; ein PKG zusätzlich mit Developer ID Installer signieren. Signiermaterial bleibt außerhalb des Repositorys.
3. Das endgültige Paket über `notarytool` prüfen lassen, Ticket mit `stapler` anheften und Signaturen, Gatekeeper sowie Erstinstallation auf einem frischen Zielsystem prüfen.
4. Paket, Source-Archiv, Lizenz, Prüfsummen und konkrete Release Notes als GitHub-Release-Entwurf hochladen. Assets und Hashes nach dem Download gegen die lokalen geprüften Dateien vergleichen.
5. Den vollständigen Entwurf veröffentlichen. Version, Mindest-OS, Hardware-Unterstützung, Einschränkungen und Installationsweg nennen; keine stärkeren Schutzversprechen als die Testnachweise.

Der Nutzerauftrag deckt diesen letzten Veröffentlichungsschritt ab, sobald die Voraussetzungen erfüllt sind. Ein vorgezogenes öffentliches Diagnose-Prerelease ist derzeit nicht als Ersatz für die angeforderte fertige App beschlossen.

Referenzen: [Apple: Notarisierung](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [GitHub: Releases verwalten](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository), [Projektplan](../../PLAN.md).

## Apple-Einrichtung

Der Account wird direkt in **Xcode → Settings → Accounts** eingerichtet. Danach in der Zertifikatsverwaltung `Developer ID Application` bereitstellen; für ein späteres signiertes PKG zusätzlich `Developer ID Installer`. Ein App-ZIP benötigt keinen Installer-Signierer. Account-Rolle, Vertragszustand und Zertifikatsrechte bestimmt Apple. Der Archivhelfer in [development.md](../development.md) kann den tatsächlichen Export anschließend prüfen; Zugangsdaten gehören nicht ins Repository oder in den Chat.

Xcodes Organizer kann über **Direct Distribution** mit dem bereits angemeldeten Account signieren und notarisieren. Dieser Weg wurde erfolgreich geprüft. Alternativ kann `notarytool` einen lokal hinterlegten Zugang (Keychain-Profil oder geeigneten API-Key) verwenden. Ein zusätzliches Notarytool-Passwort ist für den funktionierenden Organizer-Weg nicht nötig. Keine Notarisierungsdaten werden geraten oder aus anderen Anwendungen ausgelesen. Ein erfolgreich signiertes Diagnosearchiv bleibt bis zur funktionalen Qualifikation ein lokaler Test-Build.

Der Kommandozeilenexport meldete trotz bestätigtem bezahlten Team weiter `No Accounts`. Geprüft wurden dieselbe Xcode-Installation und derselbe macOS-Benutzer. Das ist kein Beleg für einen nicht eingerichteten Benutzeraccount: Die über die Xcode-Oberfläche exportierte App wurde anschließend unabhängig auf Developer ID, Hardened Runtime, gültiges Ticket und Gatekeeper-Akzeptanz geprüft. Das Archiv und seine privaten Distributionslogs bleiben lokal.

[Apple: Developer-ID-Zertifikate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates), [Apple: Notarisierungsablauf](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
