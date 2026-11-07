import type { ReactNode } from "react";

function Glyph({ children }: { children: ReactNode }) {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {children}
    </svg>
  );
}

export const PlusIcon = () => (
  <Glyph>
    <path d="M9 3.5v11M3.5 9h11" />
  </Glyph>
);

export const MinusIcon = () => (
  <Glyph>
    <path d="M3.5 9h11" />
  </Glyph>
);

export const CloseIcon = () => (
  <Glyph>
    <path d="m4.5 4.5 9 9M13.5 4.5l-9 9" />
  </Glyph>
);

export const HomeIcon = () => (
  <Glyph>
    <circle cx="9" cy="9" r="4" />
    <path d="M9 1.5V4M9 14v2.5M1.5 9H4M14 9h2.5" />
  </Glyph>
);
