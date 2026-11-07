export type Cam = { x: number; y: number; z: number };

const MIN_ZOOM = 0.4;
const MAX_ZOOM = 1.6;
/** Travel past this is a drag, not a press on a card. */
const DRAG_SLOP = 4;
const EASE = (t: number) => 1 - (1 - t) ** 3;

/**
 * Where the wall is looking: a screen point is `world * z + (x, y)`. Writes straight to the world
 * layer's transform, so panning never re-renders React. Subscribers hear about every move.
 */
export class Camera {
  cam: Cam = { x: 0, y: 0, z: 1 };
  /** True for the press that just finished dragging, so its click doesn't open a card. */
  dragged = false;
  locked = false;

  private readonly listeners = new Set<() => void>();
  private frame = 0;
  private world: HTMLElement | null = null;

  bind(world: HTMLElement) {
    this.world = world;
    this.write();
  }

  subscribe(listener: () => void) {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  }

  set(cam: Cam) {
    this.cam = cam;
    this.write();
    this.listeners.forEach((listener) => listener());
  }

  private write() {
    if (this.world) this.world.style.transform = `translate3d(${this.cam.x}px, ${this.cam.y}px, 0) scale(${this.cam.z})`;
  }

  private stop() {
    cancelAnimationFrame(this.frame);
  }

  panBy(dx: number, dy: number) {
    this.set({ ...this.cam, x: this.cam.x + dx, y: this.cam.y + dy });
  }

  zoomAt(px: number, py: number, factor: number) {
    const z = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, this.cam.z * factor));
    const k = z / this.cam.z;
    this.set({ x: px - (px - this.cam.x) * k, y: py - (py - this.cam.y) * k, z });
  }

  easeTo(target: Partial<Cam>, ms = 420) {
    this.stop();
    const from = this.cam;
    const to = { ...from, ...target };
    const start = performance.now();
    const step = (now: number) => {
      const t = Math.min(1, (now - start) / ms);
      const e = EASE(t);
      this.set({ x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e, z: from.z + (to.z - from.z) * e });
      if (t < 1) this.frame = requestAnimationFrame(step);
    };
    this.frame = requestAnimationFrame(step);
  }

  private glide(vx: number, vy: number) {
    let last = performance.now();
    const step = (now: number) => {
      const dt = now - last;
      last = now;
      const decay = 0.95 ** (dt / 16);
      vx *= decay;
      vy *= decay;
      this.panBy(vx * dt, vy * dt);
      if (Math.hypot(vx, vy) > 0.02) this.frame = requestAnimationFrame(step);
    };
    this.frame = requestAnimationFrame(step);
  }

  /** Wheel and trackpad pan, a pinch or ctrl-wheel zooms, and a press drags with momentum. */
  attach(element: HTMLElement) {
    const onWheel = (event: WheelEvent) => {
      event.preventDefault();
      if (this.locked) return;
      this.stop();
      const unit = event.deltaMode === 1 ? 16 : 1;
      if (event.ctrlKey || event.metaKey) this.zoomAt(event.clientX, event.clientY, Math.exp(-event.deltaY * unit * 0.008));
      else this.panBy(-event.deltaX * unit, -event.deltaY * unit);
    };

    const pointers = new Map<number, { x: number; y: number }>();
    let press: { x: number; y: number; moved: boolean; vx: number; vy: number; time: number } | null = null;
    let spread = 0;

    const onDown = (event: PointerEvent) => {
      if (this.locked || event.button !== 0) return;
      this.stop();
      this.dragged = false;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
      if (pointers.size === 1) press = { x: event.clientX, y: event.clientY, moved: false, vx: 0, vy: 0, time: event.timeStamp };
      if (pointers.size === 2) {
        const [a, b] = [...pointers.values()];
        spread = Math.hypot(a.x - b.x, a.y - b.y);
        if (press) press.moved = true;
        this.dragged = true;
      }
    };

    const onMove = (event: PointerEvent) => {
      const previous = pointers.get(event.pointerId);
      if (!previous) return;
      pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });

      if (pointers.size === 2) {
        const [a, b] = [...pointers.values()];
        const next = Math.hypot(a.x - b.x, a.y - b.y);
        if (spread > 0) this.zoomAt((a.x + b.x) / 2, (a.y + b.y) / 2, next / spread);
        this.panBy((event.clientX - previous.x) / 2, (event.clientY - previous.y) / 2);
        spread = next;
        return;
      }
      if (!press) return;
      if (!press.moved && Math.hypot(event.clientX - press.x, event.clientY - press.y) < DRAG_SLOP) return;
      if (!press.moved) {
        press.moved = true;
        this.dragged = true;
        element.dataset.dragging = "";
        element.setPointerCapture(event.pointerId);
      }
      const dx = event.clientX - previous.x;
      const dy = event.clientY - previous.y;
      const dt = Math.max(1, event.timeStamp - press.time);
      press.vx = press.vx * 0.7 + (dx / dt) * 0.3;
      press.vy = press.vy * 0.7 + (dy / dt) * 0.3;
      press.time = event.timeStamp;
      this.panBy(dx, dy);
    };

    const onUp = (event: PointerEvent) => {
      pointers.delete(event.pointerId);
      delete element.dataset.dragging;
      if (pointers.size > 0 || !press) return;
      const { moved, vx, vy, time } = press;
      press = null;
      if (moved && event.timeStamp - time < 60) this.glide(vx, vy);
    };

    let pinchFrom = 1;
    const onGestureStart = (event: Event) => {
      event.preventDefault();
      pinchFrom = 1;
    };
    const onGesture = (event: Event) => {
      event.preventDefault();
      const gesture = event as Event & { scale: number; clientX: number; clientY: number };
      if (!this.locked) this.zoomAt(gesture.clientX, gesture.clientY, gesture.scale / pinchFrom);
      pinchFrom = gesture.scale;
    };

    element.addEventListener("wheel", onWheel, { passive: false });
    element.addEventListener("pointerdown", onDown);
    element.addEventListener("pointermove", onMove);
    element.addEventListener("pointerup", onUp);
    element.addEventListener("pointercancel", onUp);
    element.addEventListener("gesturestart", onGestureStart);
    element.addEventListener("gesturechange", onGesture);
    return () => {
      this.stop();
      element.removeEventListener("wheel", onWheel);
      element.removeEventListener("pointerdown", onDown);
      element.removeEventListener("pointermove", onMove);
      element.removeEventListener("pointerup", onUp);
      element.removeEventListener("pointercancel", onUp);
      element.removeEventListener("gesturestart", onGestureStart);
      element.removeEventListener("gesturechange", onGesture);
    };
  }
}
