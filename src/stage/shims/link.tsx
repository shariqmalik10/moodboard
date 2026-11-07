import type { AnchorHTMLAttributes, MouseEvent, ReactNode, Ref } from "react";

type LinkProps = Omit<AnchorHTMLAttributes<HTMLAnchorElement>, "href"> & {
  href: string | { pathname?: string };
  prefetch?: boolean;
  replace?: boolean;
  scroll?: boolean;
  children?: ReactNode;
  ref?: Ref<HTMLAnchorElement>;
};

/** A link inside a card still runs its handlers and looks like a link, but it never leaves the card. */
export default function Link({ href, prefetch: _prefetch, replace: _replace, scroll: _scroll, onClick, ...rest }: LinkProps) {
  const target = typeof href === "string" ? href : (href.pathname ?? "#");
  return (
    <a
      {...rest}
      href={target}
      onClick={(event: MouseEvent<HTMLAnchorElement>) => {
        onClick?.(event);
        event.preventDefault();
      }}
    />
  );
}
