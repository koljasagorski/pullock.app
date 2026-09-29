import type { Metadata, Viewport } from "next";
import "@fontsource/poppins/latin-400.css";
import "@fontsource/poppins/latin-500.css";
import "@fontsource/poppins/latin-600.css";
import "./globals.css";
import { Header, Footer } from "@/components/site-shell";
import { asset, description, origin } from "@/lib/site";

export const metadata: Metadata = {
  metadataBase: new URL(origin),
  title: { default: "Pullock | Pull the key. Lock the Device.", template: "%s | Pullock" },
  description, applicationName: "Pullock", referrer: "strict-origin-when-cross-origin",
  icons: {
    icon: [{ url: asset("/favicon.svg"), type: "image/svg+xml" }, { url: asset("/favicon.ico"), sizes: "any" }],
    apple: [{ url: asset("/apple-touch-icon.png"), sizes: "180x180" }],
  },
};
export const viewport: Viewport = { width: "device-width", initialScale: 1, colorScheme: "light dark", themeColor: [{ media: "(prefers-color-scheme: light)", color: "#f6f6f5" }, { media: "(prefers-color-scheme: dark)", color: "#151516" }] };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body><a className="skip-link" href="#main">Skip to content</a><Header />{children}<Footer /></body></html>;
}
