type GardenerStackProps = { names?: string[]; shown?: number };

const TONES = ["#d3e6c8", "#dceaf4", "#f1d9c9", "#ece3c4"];

/** Who else looks after these plants. */
export function GardenerStack({ names = ["Ada", "Bo", "Cy", "Dee", "Eli"], shown = 3 }: GardenerStackProps) {
  const visible = names.slice(0, shown);
  const rest = names.length - visible.length;
  return (
    <div className="flex items-center gap-3 rounded-[999px] bg-paper py-2 pr-4 pl-2">
      <div className="flex">
        {visible.map((name, at) => (
          <span key={name} title={name} className="-ml-2 grid h-9 w-9 place-items-center rounded-full border-2 border-paper text-[13px] font-semibold first:ml-0" style={{ backgroundColor: TONES[at % TONES.length] }}>
            {name.slice(0, 1).toUpperCase()}
          </span>
        ))}
        {rest > 0 && <span className="-ml-2 grid h-9 w-9 place-items-center rounded-full border-2 border-paper bg-linen text-[12px] text-loam">+{rest}</span>}
      </div>
      <span className="text-[13px] text-loam">{names.length === 1 ? "1 gardener" : `${names.length} gardeners`}</span>
    </div>
  );
}
