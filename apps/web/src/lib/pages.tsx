import Link from "next/link";
import { repository } from "./site";

type Section = { title: string; body: React.ReactNode };
type ContentPage = { title: string; description: string; lang?: string; sections: Section[] };

export const pages: Record<string, ContentPage> = {
  "how-it-works": {
    title: "A connection becomes a switch.",
    description: "The planned workflow: Pullock detects compatible USB devices. Select one, arm the app and disconnect that device to request a screen lock.",
    sections: [
      { title: "Choose what to track", body: <p>Pullock detects connected USB devices. Choose any compatible device from the list, including a USB stick or another USB peripheral. The selection is tied to that connection and the current system session. The development app already supports passive inspection and selection.</p> },
      { title: "Check, then arm Pullock", body: <p>The intended protection mode requires healthy local services, macOS permission to post the lock shortcut and an explicit activation. Automatic activation is not available in the current development build.</p> },
      { title: "Removal requests a lock", body: <p>Once Pullock is armed, disconnecting the selected USB device is intended to request the standard Control + Command + Q shortcut. A successful handoff means <strong>Lock requested</strong>. It cannot confirm that macOS actually locked. The current app offers a separate, explicitly started manual shortcut test.</p> },
      { title: "Start fresh after a change", body: <p>Removal, sleep, a session change, a watcher restart or a Mac restart invalidate the selection. Reconnecting the same device does not restore it. Choose the new connection and explicitly activate again when the finished protection mode becomes available.</p> },
      { title: "Separate local responsibilities", body: <p>The native app provides controls, a daemon observes connections, and the planned session agent handles the shortcut in your session. The website does not participate in this chain. See <Link href="/security/">the security model</Link> for its limits.</p> },
    ],
  },
  compatibility: {
    title: "Check your setup.",
    description: "The initial target is macOS 27 on Apple Silicon. Hardware combinations still need real-world qualification.",
    sections: [
      { title: "Mac and operating system", body: <p>The development targets and local automated checks use Apple Silicon and macOS 27. The initial release targets current macOS 27 patches. Intel Macs, Windows, Linux and older macOS versions are not qualified.</p> },
      { title: "USB devices", body: <p>Pullock is intended to work with any compatible USB device, including USB sticks and other peripherals. The app detects devices whose USB connection macOS exposes for observation, regardless of manufacturer. Select a device and explicitly arm Pullock to use its disconnection as the trigger. Detection does not by itself certify reliable protection for every device or dock; actual combinations still need qualification.</p> },
      { title: "Adapters and docks", body: <p>Direct ports, adapters and docks can expose different connection lifecycles. Power loss, a hub reset or disconnecting a dock may end the selected connection. Each setup must be tested, including sleep and wake.</p> },
      { title: "Permissions and keyboard layout", body: <p>The lock shortcut needs the relevant macOS input permission and an active local session. Modified system shortcuts, keyboard layouts and full-screen applications can affect the result. Permission is requested only after an explicit user action.</p> },
      { title: "Current availability", body: <p>There is no finished protection release yet. The <Link href="/releases/">release page</Link> explains what has been tested and what remains open.</p> },
    ],
  },
  security: {
    title: "Know what a lock request means.",
    description: "Pullock is intended as an additional physical trigger. It cannot guarantee that macOS locks in every situation.",
    sections: [
      { title: "Development is not protection", body: <p>The current build does not provide automatic live protection. Selection, diagnostic status or a running helper must not be mistaken for an armed killswitch. The automatic removal-to-lock chain remains unfinished.</p> },
      { title: "Request, not confirmation", body: <p>The public shortcut adapter posts Control + Command + Q after checking permission, session and keyboard layout. Its success result only confirms that input was requested. It does not prove the screen is locked or set a guaranteed lock time.</p> },
      { title: "A connection can end for several reasons", body: <p>macOS reports an observed USB connection ending. It does not prove someone physically pulled the stick. A hub reset or power change can produce the same event. The connection selection deliberately expires instead of silently attaching to another device.</p> },
      { title: "Limits of the threat model", body: <p>Taking the Mac and device together may leave the connection intact. A frozen operating system, root or kernel compromise, or compromised trusted application code cannot be overcome by this utility. Keep your password, FileVault and normal security controls enabled.</p> },
      { title: "Public evidence", body: <p>The repository contains the state-machine tests, transport checks, architecture decisions and qualification limits. Mock tests do not replace physical removal, installation or real lock tests. Read the <a href={`${repository}/blob/main/docs/test-reports/M4-M5.md`}>current test report</a>.</p> },
      { title: "Report a vulnerability", body: <p>Contact <a href="mailto:legal@patchletter.com">legal@patchletter.com</a> with a description, affected version and reproduction steps. Avoid putting secrets or exploit details into a public GitHub issue. General questions belong on the <Link href="/support/">support page</Link>.</p> },
    ],
  },
  download: {
    title: "The first release is being built.",
    description: "There is no finished protection app to download yet. Follow the public source and qualification work.",
    sections: [
      { title: "What is available today", body: <p>The source includes a development app with passive USB inspection, service diagnostics, simulations and an explicit manual lock test. It is not an automatic security product. <a href={repository}>Source on GitHub</a>.</p> },
      { title: "What must happen before download", body: <p>The automatic action chain, real removal and lock behavior, permission handling, installation, update and uninstall still need end-to-end qualification. The final code must then be signed, notarized and verified as the actual distribution artifact.</p> },
      { title: "Where the release will appear", body: <p>Qualified app packages, source and checksums will be published in <a href={`${repository}/releases`}>GitHub Releases</a> for this repository. This page will link to the verified package once it exists.</p> },
    ],
  },
  releases: {
    title: "An open record of progress.",
    description: "Current development work and the remaining steps toward the first protection release.",
    sections: [
      { title: "Development 0.4.0", body: <p>The current native source has 147 automated tests across state handling, USB observation, IPC, services, the daemon runtime, the shortcut adapter and diagnostics. Debug and Release builds pass locally. These checks do not run real locks or install services.</p> },
      { title: "Brand and website", body: <p>The provided Pullock identity is integrated into the app icon, native header and this website. The website uses a static export, local fonts and no analytics integration. The browser demonstration never accesses hardware.</p> },
      { title: "Distribution evidence", body: <p>An earlier test archive passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. That result does not qualify later source changes or demonstrate an operational killswitch.</p> },
      { title: "Still in progress", body: <p>The automatic daemon-to-agent action path, real hardware and session checks, final installation flow and distribution of the completed app remain open. <a href={`${repository}/blob/main/docs/test-reports/M4-M5.md`}>Read the native test report</a> or <a href={`${repository}/releases`}>check published releases</a>.</p> },
    ],
  },
  support: {
    title: "Get in touch.",
    description: "Pullock is developed by patchletter UG (haftungsbeschränkt). Contact us for questions, bug reports and legal matters.",
    sections: [
      { title: "General questions", body: <p>Email <a href="mailto:hello@patchletter.com">hello@patchletter.com</a> or call <a href="tel:+4920973085753">+49 209 73085753</a>. Contact details and company registration are in the <Link href="/impressum/">Impressum</Link>.</p> },
      { title: "Report a bug", body: <p>Use <a href={`${repository}/issues`}>GitHub Issues</a> for non-sensitive reports. Include your macOS version, app version, device model, connection through a direct port or dock, and reproduction steps. Review any diagnostics before sharing; do not include passwords, credentials or private device identifiers.</p> },
      { title: "Security and legal matters", body: <p>Write to <a href="mailto:legal@patchletter.com">legal@patchletter.com</a>. Please use a private channel for security-sensitive findings.</p> },
    ],
  },
  privacy: {
    title: "Privacy, on your Mac and online.",
    description: "The native app, the website and contact by email have different data flows. This page explains each one.",
    sections: [
      { title: "Who is responsible", body: <p>patchletter UG (haftungsbeschränkt), Meisterweg 16, 45896 Gelsenkirchen, Germany, represented by Kolja Sagorski, is responsible for this website. Contact <a href="mailto:hello@patchletter.com">hello@patchletter.com</a> for privacy requests. Full details are in the <Link href="/impressum/">Impressum</Link>.</p> },
      { title: "Native application", body: <p>The development code processes local USB descriptors, connection identifiers and session state to show devices and maintain the selected connection. It does not read device files, passwords or key credentials, and includes no analytics or automatic diagnostic upload. A report you deliberately share with support is a separate disclosure.</p> },
      { title: "Website and hosting", body: <p>This website is hosted on GitHub Pages. When the site is requested, the hosting provider receives connection information such as your IP address, request time and browser details. Delivery and security rely on our legitimate interest in operating this site (Article 6(1)(f) GDPR). GitHub describes its own processing, retention and international transfers in its <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">Privacy Statement</a>.</p> },
      { title: "No website tracking integration", body: <p>We have not added analytics, advertising pixels, external font requests or third-party embeds. The demonstration keeps its state in memory and does not access USB hardware. The site sets no application cookies and does not use local storage. This does not mean a hosting provider receives no network data.</p> },
      { title: "Email and GitHub", body: <p>If you email us, we process the information you provide to answer your request. Depending on the request, the basis is Article 6(1)(b) GDPR for pre-contractual or contractual matters, or Article 6(1)(f) for handling other enquiries. We retain correspondence as long as needed for the request and any applicable legal retention duties. Email delivery involves our mail service providers. GitHub links open a separate service subject to GitHub’s privacy terms; public issue content is visible to others.</p> },
      { title: "Your rights", body: <p>Where the GDPR applies, you may request access, correction, erasure, restriction and portability, subject to the statutory conditions. You may object to processing based on legitimate interests. You can also complain to a supervisory authority, including the <a href="https://www.ldi.nrw.de/">North Rhine-Westphalia data protection authority</a>. Contact us at the email above to exercise your rights.</p> },
    ],
  },
  impressum: {
    title: "Impressum",
    description: "Anbieter und inhaltlich Verantwortlicher für Pullock.", lang: "de",
    sections: [
      { title: "Angaben gemäß § 5 DDG", body: <><p><strong>patchletter UG (haftungsbeschränkt)</strong><br />Meisterweg 16<br />45896 Gelsenkirchen<br />Deutschland</p><p>Vertreten durch Geschäftsführer Kolja Sagorski.</p></> },
      { title: "Registereintrag", body: <p>Registergericht: Amtsgericht Gelsenkirchen<br />Registernummer: HRB 20118</p> },
      { title: "Kontakt", body: <p>E-Mail: <a href="mailto:hello@patchletter.com">hello@patchletter.com</a><br />Telefon: <a href="tel:+4920973085753">+49 209 73085753</a><br />Rechtliches: <a href="mailto:legal@patchletter.com">legal@patchletter.com</a></p> },
      { title: "Verantwortlich gemäß § 18 Abs. 2 MStV", body: <p>Kolja Sagorski<br />Meisterweg 16<br />45896 Gelsenkirchen<br />Deutschland</p> },
      { title: "Marken und Quellen", body: <p>Pullock ist ein unabhängiges Projekt. Genannte Produkt- und Unternehmensnamen gehören ihren jeweiligen Inhabern. Eine Partnerschaft oder Unterstützung wird nicht behauptet. Die Anbieterdaten entsprechen dem <a href="https://patchletter.com/de/impressum">Impressum von patchletter</a>.</p> },
    ],
  },
};
