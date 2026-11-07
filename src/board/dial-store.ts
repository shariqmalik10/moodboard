import { DialStore } from "dialkit";

type Preserve = (saved: unknown, rest: unknown, control?: { type: string }) => unknown;

const store = DialStore as unknown as { normalizePreservedValue: Preserve };
const preserve = store.normalizePreservedValue.bind(store);

const isTransition = (value: unknown) => {
  const type = (value as { type?: unknown } | null)?.type;
  return type === "spring" || type === "easing";
};

// DialKit restores a transition only when it is the same kind as the default, so a spring set on an
// easing dial would vanish from the panel and its saved versions the next time the panel opened.
store.normalizePreservedValue = (saved, rest, control) => (control?.type === "transition" && isTransition(saved) ? saved : preserve(saved, rest, control));
