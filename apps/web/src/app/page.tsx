import Link from "next/link";
import Image from "next/image";
import { ArrowUpRightIcon, ArrowRightIcon } from "@phosphor-icons/react/dist/ssr";
import { ConnectionDemo } from "@/components/connection-demo";
import { asset, repository, pageMetadata, description } from "@/lib/site";

export const metadata = pageMetadata("Pull the key. Lock the Device.", description, "/");
export default function Home() {
  return <main id="main">
    <section className="hero shell">
      <div className="hero-copy"><p className="eyebrow">A physical switch for your Mac</p>
        <h1>Pull the key.<br />Lock the Device.</h1>
        <p className="hero-description">Choose a compatible USB device. Arm Pullock. Disconnect that device to request a Mac screen lock.</p>
        <div className="actions"><Link className="button" href="/download/">Release status <ArrowUpRightIcon size={18} aria-hidden="true" /></Link><Link className="text-link" href="/how-it-works/">How it works <ArrowRightIcon size={18} aria-hidden="true" /></Link></div>
      </div>
      <div className="hero-mark"><Image src={asset("/brand/pullock-app-dark.svg")} alt="Pullock app icon: an open padlock with a USB key" width={360} height={360} priority /></div>
    </section>
    <aside className="development-note shell" aria-label="Development status"><strong>In development</strong><p>Automatic protection is not available yet. There is no finished app download.</p><Link href="/releases/">See progress <ArrowRightIcon size={16} aria-hidden="true" /></Link></aside>
    <section className="hardware-section shell" aria-labelledby="your-device">
      <figure className="hardware-photo"><picture><source type="image/webp" srcSet={[640, 768, 1024, 1280].map(width => `${asset(`/brand/usb-detail-${width}.webp`)} ${width}w`).join(", ")} sizes="(max-width: 767px) calc(100vw - 48px), (max-width: 1279px) 55vw, 644px" /><img src={asset("/brand/usb-detail.webp")} alt="Illustrative close-up of an unbranded metal USB-C stick with a key loop" width={1536} height={1024} loading="eager" fetchPriority="high" /></picture><figcaption>Choose a USB connection. No special key is required.</figcaption></figure>
      <div className="hardware-copy"><h2 id="your-device">Any compatible<br />USB device.</h2><p>Pullock detects connected USB devices. Choose the one to use as your switch: a USB stick or any other compatible device.</p><Link className="text-link" href="/compatibility/">Check compatibility <ArrowRightIcon size={18} aria-hidden="true" /></Link></div>
    </section>
    <section className="behavior-section shell" aria-labelledby="one-connection">
      <div><h2 id="one-connection">One connection.<br />A clear boundary.</h2><p className="section-description">Detect. Select. Arm. The selected USB device becomes your physical trigger.</p>
        <ol className="workflow-list"><li><h3>Choose the connection</h3><p>Pullock lists detected USB devices. Select the compatible device you want to track.</p></li><li><h3>Arm Pullock</h3><p>After the required checks, explicitly arm the app for that selected device.</p></li><li><h3>Remove the device</h3><p>Once armed, disconnecting that selected device is intended to request the macOS lock shortcut.</p></li></ol>
      </div><ConnectionDemo />
    </section>
    <section className="principles shell" aria-labelledby="local-heading"><h2 id="local-heading">Designed to stay local.</h2><div className="principles-grid"><div><h3>No account to connect.</h3><p>The native code observes USB connections locally. It does not read files from your device or send telemetry.</p><Link href="/privacy/" className="text-link">Privacy details <ArrowRightIcon size={18} aria-hidden="true" /></Link></div><div><h3>Limits you can understand.</h3><p>A shortcut request cannot prove the screen is locked. Disconnecting a hub can also end the selected connection.</p><Link href="/security/" className="text-link">Security model <ArrowRightIcon size={18} aria-hidden="true" /></Link></div></div></section>
    <section className="faq-section shell"><h2>Before you pull.</h2><div className="faq-list">
      <details><summary>Can I use Pullock for protection today?</summary><p>No. The current build includes an automatic lock test after explicit arming, alongside inspection, diagnostics and a manual lock test. Real hardware and installed-service qualification are still required before a protection release.</p></details>
      <details><summary>Can I use any USB device?</summary><p>The goal is any compatible USB device that Pullock can detect and monitor, including USB sticks. Choose a device from the list and arm Pullock. No particular manufacturer, credential or stable serial number is required. Actual hardware combinations still need qualification.</p></details>
      <details><summary>What happens after I reconnect?</summary><p>The old selection expires. The intended workflow requires selecting the new connection and explicitly enabling protection again. Sleep and session changes also invalidate the selection.</p></details>
      <details><summary>Does Pullock replace FileVault or a password?</summary><p>No. It is intended as an additional physical trigger. Keep macOS authentication, FileVault and your usual device security in place.</p></details>
    </div></section>
    <section className="source-section shell"><div><h2>Follow the build.</h2><p>Source, decisions and test reports are public.</p></div><a href={repository} className="button">Source on GitHub <ArrowUpRightIcon size={18} aria-hidden="true" /></a></section>
  </main>;
}
