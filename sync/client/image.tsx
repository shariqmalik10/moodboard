import type { ImgHTMLAttributes } from "react";

type Props = Omit<ImgHTMLAttributes<HTMLImageElement>, "src"> & { src: string | { src: string }; fill?: boolean; priority?: boolean; quality?: number; placeholder?: string; blurDataURL?: string; unoptimized?: boolean; loader?: unknown };

/** The picture itself, without Next's image server. */
export default function Image({ src, fill, priority: _priority, quality: _quality, placeholder: _placeholder, blurDataURL: _blur, unoptimized: _unoptimized, loader: _loader, style, ...rest }: Props) {
  const filled = fill ? { position: "absolute" as const, inset: 0, width: "100%", height: "100%" } : undefined;
  return <img {...rest} src={typeof src === "string" ? src : src.src} style={{ ...filled, ...style }} />;
}
