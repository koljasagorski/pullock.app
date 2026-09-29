import Link from "next/link";
export default function NotFound() {
  return <main id="main" className="document shell"><div className="document-heading"><p>404</p><h1>This page isn’t connected.</h1><p>The address may have changed. Return to Pullock to find what you need.</p><Link className="button" href="/">Back to Pullock</Link></div></main>;
}
