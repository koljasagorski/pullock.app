import type { Metadata } from "next";

export const repository = "https://github.com/koljasagorski/pullock.app";
export const basePath = process.env.NEXT_PUBLIC_BASE_PATH || "";
export const origin = process.env.NEXT_PUBLIC_SITE_ORIGIN || "https://pullock.app";
export const asset = (path: string) => `${basePath}${path}`;
export const absolute = (path: string) => `${origin}${basePath}${path}`;
export const description = "Pullock is a macOS killswitch in development for any compatible USB device. Select a detected device, arm the app and disconnect it to request a screen lock.";
export function pageMetadata(title: string, description: string, path: string): Metadata {
  return {
    title, description, alternates: { canonical: absolute(path) },
    openGraph: {
      title: `${title} | Pullock`, description, url: absolute(path),
      siteName: "Pullock", type: "website", locale: "en_US",
      images: [{ url: absolute("/brand/social.png"), width: 1200, height: 630, alt: "Pullock. Pull the key. Lock the Device." }],
    },
    twitter: { card: "summary_large_image", title: `${title} | Pullock`, description, images: [absolute("/brand/social.png")] },
  };
}
