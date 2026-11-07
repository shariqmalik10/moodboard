import { lazy, Suspense, type ComponentType } from "react";

type Loader = () => Promise<{ default: ComponentType<Record<string, unknown>> } | ComponentType<Record<string, unknown>>>;

/** `next/dynamic` without the server half. */
export default function dynamic(load: Loader) {
  const Lazy = lazy(async () => {
    const loaded = await load();
    return "default" in loaded ? loaded : { default: loaded };
  });
  return function Dynamic(props: Record<string, unknown>) {
    return (
      <Suspense fallback={null}>
        <Lazy {...props} />
      </Suspense>
    );
  };
}
