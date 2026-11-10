import { PSEUDO } from "./pseudo";
import type { Script, Step, Target, CursorKind } from "../demos/types";

class Stopped extends Error {}

const CLICKABLE = "a[href], button:enabled, [role='button'], [role='tab'], [role='switch'], [role='menuitem'], [role='menuitemradio'], [role='option'], [role='radio'], summary, label";
const TYPEABLE = "input:not([type='checkbox'], [type='radio']), textarea, [contenteditable='true']";

/** Each glyph's hot spot, from the cursor set's own rules. */
const GLYPHS = {
  arrow: { src: "cursors/arrow.svg", x: 4, y: 3 },
  hand: { src: "cursors/hand.svg", x: 14, y: 2 },
  pressed: { src: "cursors/hand-pressed.svg", x: 14, y: 3 },
  nib: { src: "cursors/nib.svg", x: 16, y: 16 },
} as const;

type Glyph = keyof typeof GLYPHS;

const raf = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
const easeInOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - (-2 * t + 2) ** 3 / 2);

function chain(element: Element | null) {
  const nodes: Element[] = [];
  for (let node = element; node; node = node.parentElement) nodes.push(node);
  return nodes;
}

function find(target: Target): HTMLElement | null {
  if (typeof target === "string") return document.querySelector<HTMLElement>(target);
  const all = Array.from(document.querySelectorAll<HTMLElement>(target.sel));
  const matches = target.text === undefined ? all : all.filter((node) => node.textContent?.trim().includes(target.text as string));
  return matches[target.nth ?? 0] ?? null;
}

function fire(node: Element, type: string, x: number, y: number, extra: MouseEventInit = {}) {
  const init = { bubbles: !type.endsWith("enter") && !type.endsWith("leave"), cancelable: true, composed: true, clientX: x, clientY: y, view: window, ...extra };
  const isPointer = type.startsWith("pointer");
  node.dispatchEvent(isPointer ? new PointerEvent(type, { pointerId: 1, pointerType: "mouse", isPrimary: true, ...init }) : new MouseEvent(type, init));
}

const timeout = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Brings running transitions to their end. A covered window's animation clocks don't advance, so waiting wouldn't finish them. */
async function settle() {
  for (let pass = 0; pass < 3; pass++) {
    await timeout(50);
    for (const animation of document.getAnimations()) {
      try {
        animation.finish();
      } catch {
        // An endless animation has no end to reach.
      }
    }
  }
}

/**
 * Plays a script against a real component: a cursor glides across the card and the elements under
 * it get real pointer and mouse events, the pseudo-state classes and real clicks, so the component
 * runs its own handlers and its own CSS. A person's real pointer on the card takes over from it.
 */
export class Director {
  private generation = 0;
  private paused = false;
  private instant = false;
  private x = 0;
  private y = 0;
  private hovered: Element | null = null;
  private pressing: { node: Element; live: Element[] } | null = null;
  private readonly cursor = document.createElement("div");
  private readonly glyph = document.createElement("img");
  private readonly touch: boolean;
  private readonly script: Script;
  private readonly restart: () => Promise<void>;

  constructor(script: Script, kind: CursorKind, restart: () => Promise<void>) {
    this.script = script;
    this.restart = restart;
    this.touch = kind === "touch";
    this.cursor.className = this.touch ? "stage-cursor stage-cursor-touch" : "stage-cursor";
    this.cursor.style.display = kind === "none" ? "none" : "";
    this.cursor.setAttribute("popover", "manual");
    this.cursor.setAttribute("aria-hidden", "true");
    if (!this.touch) this.cursor.append(this.glyph);
    document.body.append(this.cursor);
    this.x = innerWidth * 0.7;
    this.y = innerHeight * 0.8;
    this.paint("arrow");
  }

  /** Plays the script from this beat, and from the top on every pass after that. `once` ends it after one pass. */
  start(from = 0, once = false) {
    const generation = ++this.generation;
    this.show();
    void this.loop(generation, from, once);
  }

  /** Plays the first beats at once and out of sight, so the component starts in the state they reach. */
  async pose(beats: number) {
    const generation = ++this.generation;
    this.instant = true;
    this.cursor.hidden = true;
    for (const step of this.script.slice(0, beats)) await this.exec(step, generation);
    this.instant = false;
    await settle();
  }

  /** Stops the script and releases its press and hover, leaving the component in its current state. */
  stop() {
    this.generation++;
    this.releasePress();
    this.pointAt(null);
    this.cursor.hidden = true;
  }

  setPaused(paused: boolean) {
    this.paused = paused;
  }

  private async loop(generation: number, from: number, once: boolean) {
    try {
      let steps = this.script.slice(from);
      while (true) {
        for (const step of steps) await this.exec(step, generation);
        await this.sleep(700, generation);
        if (once) return this.stop();
        await this.restart();
        await this.sleep(200, generation);
        steps = this.script;
      }
    } catch (reason) {
      if (!(reason instanceof Stopped)) throw reason;
    }
  }

  private show() {
    this.cursor.hidden = false;
    this.raise();
  }

  /** A modal dialog sits in the top layer, so the cursor goes back on top of whatever just opened. */
  private raise() {
    if (this.cursor.isConnected && typeof this.cursor.showPopover === "function") {
      if (this.cursor.matches(":popover-open")) this.cursor.hidePopover();
      this.cursor.showPopover();
    }
  }

  private async sleep(ms: number, generation: number) {
    if (this.instant) {
      await timeout(Math.min(ms, 30));
      if (generation !== this.generation) throw new Stopped();
      return;
    }
    let left = ms;
    let last = performance.now();
    while (left > 0) {
      const now = await raf();
      if (generation !== this.generation) throw new Stopped();
      if (!this.paused) left -= now - last;
      last = now;
    }
  }

  private async exec(step: Step, generation: number) {
    this.raise();
    if ("wait" in step) return this.sleep(step.wait, generation);
    if ("hover" in step) return this.glideTo(step.hover, step.ms, generation);
    if ("click" in step) {
      await this.glideTo(step.click, step.ms, generation);
      return this.press(generation, step.hold);
    }
    if ("leave" in step) return this.leave(generation);
    if ("type" in step) return this.typeText(step.type, step.cps ?? 14, generation);
    if ("key" in step) return this.pressKey(step.key);
    if ("scroll" in step) return this.scrollTo(step.scroll, step.to, step.ms ?? 900, generation);
  }

  private async glideTo(target: Target, ms: number | undefined, generation: number) {
    const node = await this.waitFor(target, generation);
    if (!node) return;
    const box = node.getBoundingClientRect();
    await this.glide(box.left + box.width / 2, box.top + box.height / 2, ms, generation);
  }

  /** The target may still be animating in, so it gets a moment to appear before the step gives up. */
  private async waitFor(target: Target, generation: number) {
    for (let tries = 0; tries < 60; tries++) {
      const node = find(target);
      if (node) return node;
      await this.sleep(20, generation);
    }
    console.warn("[stage] no element for", target);
    return null;
  }

  private async glide(toX: number, toY: number, ms: number | undefined, generation: number) {
    if (this.instant) {
      this.x = toX;
      this.y = toY;
      this.pointAt(document.elementFromPoint(toX, toY));
      return;
    }
    const fromX = this.x;
    const fromY = this.y;
    const distance = Math.hypot(toX - fromX, toY - fromY);
    const duration = ms ?? Math.min(820, 260 + distance * 1.1);
    const bow = Math.min(36, distance * 0.08);
    let elapsed = 0;
    let last = performance.now();
    while (elapsed < duration) {
      const now = await raf();
      if (generation !== this.generation) throw new Stopped();
      if (!this.paused) elapsed += now - last;
      last = now;
      const t = Math.min(1, elapsed / duration);
      const eased = easeInOut(t);
      this.x = fromX + (toX - fromX) * eased;
      this.y = fromY + (toY - fromY) * eased - Math.sin(t * Math.PI) * bow;
      this.pointAt(this.touch ? this.hovered : document.elementFromPoint(this.x, this.y));
      this.paint();
    }
  }

  private async press(generation: number, hold = 110) {
    const node = this.touch ? document.elementFromPoint(this.x, this.y) : this.hovered;
    if (!node) return;
    this.pointAt(node);
    const live = chain(node);
    live.forEach((each) => each.classList.add(PSEUDO.active));
    this.paint("pressed");
    this.cursor.toggleAttribute("data-pressed", true);
    fire(node, "pointerdown", this.x, this.y, { button: 0, buttons: 1 });
    fire(node, "mousedown", this.x, this.y, { button: 0, buttons: 1 });
    this.pressing = { node, live };
    const focusable = (node as HTMLElement).closest<HTMLElement>("a[href], button, input, textarea, select, [tabindex]");
    focusable?.focus({ preventScroll: true });
    await this.sleep(hold, generation);
    this.releasePress();
    fire(node, "click", this.x, this.y, { button: 0, detail: 1 });
    this.paint();
    if (this.touch) this.pointAt(null);
    await this.sleep(60, generation);
  }

  private releasePress() {
    if (!this.pressing) return;
    const { node, live } = this.pressing;
    this.pressing = null;
    fire(node, "pointerup", this.x, this.y, { button: 0 });
    fire(node, "mouseup", this.x, this.y, { button: 0 });
    live.forEach((each) => each.classList.remove(PSEUDO.active));
    this.cursor.toggleAttribute("data-pressed", false);
  }

  private async leave(generation: number) {
    await this.glide(innerWidth * 0.82, innerHeight * 0.86, undefined, generation);
    this.pointAt(null);
  }

  private async typeText(text: string, cps: number, generation: number) {
    const field = document.activeElement as HTMLInputElement | HTMLTextAreaElement | null;
    if (!field || !field.matches("input, textarea")) return;
    const proto = field instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setValue = Object.getOwnPropertyDescriptor(proto, "value")?.set;
    for (const letter of text) {
      const erase = letter === "\b";
      field.dispatchEvent(new KeyboardEvent("keydown", { key: erase ? "Backspace" : letter, bubbles: true }));
      setValue?.call(field, erase ? field.value.slice(0, -1) : field.value + letter);
      field.dispatchEvent(new Event("input", { bubbles: true }));
      field.dispatchEvent(new KeyboardEvent("keyup", { key: erase ? "Backspace" : letter, bubbles: true }));
      await this.sleep(1000 / cps + Math.random() * 40, generation);
    }
  }

  private pressKey(key: string) {
    const node = document.activeElement ?? document.body;
    node.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
    node.dispatchEvent(new KeyboardEvent("keyup", { key, bubbles: true, cancelable: true }));
  }

  private async scrollTo(target: Target, to: number, ms: number, generation: number) {
    const node = await this.waitFor(target, generation);
    if (!node) return;
    if (this.instant) {
      node.scrollTop = to;
      return;
    }
    const from = node.scrollTop;
    let elapsed = 0;
    let last = performance.now();
    while (elapsed < ms) {
      const now = await raf();
      if (generation !== this.generation) throw new Stopped();
      if (!this.paused) elapsed += now - last;
      last = now;
      node.scrollTop = from + (to - from) * easeInOut(Math.min(1, elapsed / ms));
    }
  }

  /** Moves real hover from what was under the cursor to what is under it now. */
  private pointAt(next: Element | null) {
    const previous = this.hovered;
    if (next === this.cursor || this.cursor.contains(next)) return;
    if (next === previous) {
      if (next) {
        fire(next, "pointermove", this.x, this.y);
        fire(next, "mousemove", this.x, this.y);
      }
      return;
    }
    const was = chain(previous);
    const now = chain(next);
    if (previous) {
      fire(previous, "pointerout", this.x, this.y, { relatedTarget: next });
      fire(previous, "mouseout", this.x, this.y, { relatedTarget: next });
    }
    for (const node of was) {
      if (now.includes(node)) continue;
      node.classList.remove(PSEUDO.hover);
      fire(node, "pointerleave", this.x, this.y, { relatedTarget: next });
      fire(node, "mouseleave", this.x, this.y, { relatedTarget: next });
    }
    for (const node of [...now].reverse()) {
      if (was.includes(node)) continue;
      node.classList.add(PSEUDO.hover);
      fire(node, "pointerenter", this.x, this.y, { relatedTarget: previous });
      fire(node, "mouseenter", this.x, this.y, { relatedTarget: previous });
    }
    if (next) {
      fire(next, "pointerover", this.x, this.y, { relatedTarget: previous });
      fire(next, "mouseover", this.x, this.y, { relatedTarget: previous });
    }
    this.hovered = next;
  }

  private paint(forced?: Glyph) {
    if (this.touch) {
      this.cursor.style.transform = `translate(${this.x}px, ${this.y}px)`;
      return;
    }
    const over = this.hovered as Element | null;
    const glyph: Glyph = forced ?? (over?.closest(TYPEABLE) ? "nib" : over?.closest(CLICKABLE) ? "hand" : "arrow");
    const { src, x, y } = GLYPHS[glyph];
    const url = `${import.meta.env.BASE_URL}${src}`;
    if (this.glyph.getAttribute("src") !== url) this.glyph.setAttribute("src", url);
    this.cursor.style.transform = `translate(${this.x - x}px, ${this.y - y}px)`;
  }
}
