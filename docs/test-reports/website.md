# Website-Prüfung

Stand: 29. September 2026. Marketingseite für den Entwicklungsstand, kein fertiger
App-Download. Autorisierter erster Host: `koljasagorski.github.io/pullock.app/`.

## Funktions- und Darstellungsprüfung

- TypeScript strict, ESLint und Next.js-Produktions-Static-Export bestehen.
- Neun Browserfälle in Chromium Desktop hell, Chromium Mobil dunkel und WebKit
  Desktop dunkel mit reduzierter Bewegung bestehen. Jeder Routenfall prüft alle
  neun Inhaltsseiten, interne Links, Bildladen, Canonical und CSP.
- Dieselben Prüfungen bestehen mit `/pullock.app`-Basispfad. Direkte Unterseiten,
  404 mit Rückkehr, Tastatur-Sprunglink, FAQ und Demo-Rücksetzung sind abgedeckt.
- axe meldet in den geprüften Seiten keine WCAG-2-A/AA-/2.1-AA-Verstöße. Dies
  ersetzt keine vollständige manuelle Barrierefreiheitszertifizierung.
- Keine externen Browseranfragen, Anwendungscookies oder localStorage-Einträge
  im geprüften Seitenablauf. Schriften und Grafiken kommen vom eigenen Host.
- Startseite hell/dunkel, Mobilansicht und Impressum wurden als Screenshots
  visuell geprüft. Das vorhandene Logo bleibt in seiner SVG-Geometrie erhalten.
- API-freie Simulation: kein USB-Zugriff und kein echter Sperrvorgang.

## Lokale Labormessung

Lighthouse 13.5.0, simuliertes Mobilgerät, lokaler statischer Server mit Gzip,
Projektbasispfad: Performance **99**, Accessibility **100**, Best Practices
**100**, SEO **100**. FCP **0,8 s**, LCP **2,2 s**, CLS **0,001**, TBT **20 ms**.
Dies sind lokale Laborwerte, keine Feldwerte oder Garantie für das öffentliche
Hosting. Ein früherer Lauf zeigte LCP 5,0 s; daraufhin wurden responsive WebP-
Größen, frühes Laden des mobilen Hauptbilds und realistische Transferkompression
ergänzt. INP wurde nicht als Nutzer-Feldwert erhoben.

## Quellen und Betriebsgrenzen

Anbieterdaten: [vom Nutzer genanntes Impressum](https://patchletter.com/de/impressum).
Hostinginformationen: [GitHub Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).
Statischer Export: [Next.js](https://nextjs.org/docs/app/guides/static-exports).

GitHub Pages liefert statische Dateien. Der Export ergänzt CSP-Meta-Tags mit
Hashes der Inline-Skripte; dies ersetzt keine frei konfigurierbaren HTTP-Header.
Keine Drittanbieter-Embeds, Newsletter, Analytics oder Anmeldefunktion. Die
Website beteiligt sich nicht an der nativen Schutzkette.

Echte automatische Schutzfunktion, finaler Installer und Domain-Umstellung
sind getrennte, noch offene Arbeitspunkte. Ihre Fertigstellung wird nicht aus
diesem Website-Nachweis abgeleitet.

## Öffentliche Bereitstellung

Die Website wurde über [CI 36614406143](https://github.com/koljasagorski/pullock.app/actions/runs/36614406143)
aus Commit `8ecdbe509535c7c244697510e3dd220cd7f09073` veröffentlicht.
Live geprüft unter <https://koljasagorski.github.io/pullock.app/>: Startseite und
Impressum HTTP 200, aktuelle „Any compatible USB device“-Texte, geladenes Logo
und Bilder, Demo und Rücksetzung, keine Browser-/Ressourcenfehler. Die Pages-
Konfiguration verwendet Workflow-Deployment, kein CNAME und erzwungenes HTTPS.
