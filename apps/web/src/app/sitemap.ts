import type { MetadataRoute } from "next";
import { absolute } from "@/lib/site";
import { pages } from "@/lib/pages";
export const dynamic = "force-static";
export default function sitemap(): MetadataRoute.Sitemap {
  return ["/", ...Object.keys(pages).map(slug => `/${slug}/`)].map(path => ({ url: absolute(path) }));
}
