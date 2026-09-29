import { asset } from "@/lib/site";

export function BrandSymbol({ className = "", size = 40 }: { className?: string; size?: number }) {
  return <picture className={className}>
    <source media="(prefers-color-scheme: dark)" srcSet={asset("/brand/pullock-symbol-dark.svg")} />
    {/* Existing brand SVGs keep their original geometry and theme variants. */}
    <img src={asset("/brand/pullock-symbol-light.svg")} alt="" width={size} height={size} />
  </picture>;
}
