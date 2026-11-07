import type { HostMessage, StageMessage } from "./protocol";

type Native = { postMessage: (message: unknown) => void };

const native = (window as unknown as { webkit?: { messageHandlers?: { moodboard?: Native } } }).webkit?.messageHandlers?.moodboard;

/** True inside the Mac app, which owns saved dials and carries every message. */
export const inApp = native !== undefined;

export const tellNative = (message: unknown) => native?.postMessage(message);

export const tell = (message: StageMessage) => (native ? native.postMessage(message) : parent.postMessage(message, location.origin));

export function onHost(handle: (message: HostMessage) => void) {
  if (native) {
    (window as unknown as { __host: typeof handle }).__host = handle;
    return;
  }
  addEventListener("message", (event: MessageEvent<HostMessage>) => {
    if (event.origin === location.origin) handle(event.data);
  });
}

/** What the app has saved for this component: DialKit's state, whose `values` hold each dotted path. */
export async function savedByApp(id: string): Promise<{ values?: Record<string, unknown> } | null> {
  const response = await fetch(`api/dials?id=${encodeURIComponent(id)}`);
  return response.ok ? ((await response.json()) as { values?: Record<string, unknown> } | null) : null;
}
