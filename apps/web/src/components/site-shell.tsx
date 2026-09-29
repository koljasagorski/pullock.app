import Link from "next/link";
import { ArrowUpRightIcon } from "@phosphor-icons/react/dist/ssr";
import { BrandSymbol } from "./brand";
import { repository } from "@/lib/site";

export function Header() {
  return <header className="site-header shell">
    <Link href="/" className="wordmark" aria-label="Pullock home"><BrandSymbol size={36} /><span>Pullock</span></Link>
    <nav aria-label="Main navigation" className="main-nav">
      <Link href="/how-it-works/">How it works</Link>
      <Link href="/security/">Security</Link>
      <Link href="/download/" className="nav-action">Release status <ArrowUpRightIcon size={16} aria-hidden="true" /></Link>
    </nav>
  </header>;
}
export function Footer() {
  return <footer className="site-footer shell">
    <div className="footer-top">
      <div><Link href="/" className="wordmark"><BrandSymbol size={36} /><span>Pullock</span></Link><p>Pull the key. Lock the Device.</p></div>
      <nav aria-label="Footer navigation" className="footer-links">
        <Link href="/compatibility/">Compatibility</Link><Link href="/releases/">Releases</Link>
        <Link href="/support/">Support</Link><a href={repository}>Source on GitHub</a>
        <Link href="/privacy/">Privacy</Link><Link href="/impressum/" lang="de">Impressum</Link>
      </nav>
    </div>
    <div className="footer-bottom"><span>© 2026 patchletter UG (haftungsbeschränkt)</span><span>Native for macOS. Open source.</span></div>
  </footer>;
}
