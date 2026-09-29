import { notFound } from "next/navigation";
import { pages } from "@/lib/pages";
import { pageMetadata } from "@/lib/site";

export const dynamicParams = false;
export function generateStaticParams() { return Object.keys(pages).map(slug => ({ slug })); }
export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const page = pages[slug];
  if (!page) notFound();
  return pageMetadata(page.title, page.description, `/${slug}/`);
}
export default async function Page({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params;
  const page = pages[slug];
  if (!page) notFound();
  return <main id="main" className="document shell" lang={page.lang || "en"}>
    <div className="document-heading"><h1>{page.title}</h1><p>{page.description}</p></div>
    <div className="document-body">{page.sections.map(section => <section key={section.title}><h2>{section.title}</h2>{section.body}</section>)}</div>
  </main>;
}
