/** The little drawn plant the cards share. */
export function Leaf({ size = 56, tone = "#3d6a46" }: { size?: number; tone?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 56 56" aria-hidden="true">
      <path d="M17 40h22l-3 12H20z" fill="#c2653d" />
      <path d="M15 37h26v5H15z" fill="#a9532f" />
      <path d="M28 37c0-10 0-17 0-22" stroke={tone} strokeWidth="2.4" strokeLinecap="round" fill="none" />
      <path d="M28 26c-8 0-13-5-14-12c8 0 13 4 14 12z" fill={tone} />
      <path d="M28 21c7-1 11-6 12-12c-7 0-11 5-12 12z" fill={tone} opacity="0.8" />
    </svg>
  );
}
