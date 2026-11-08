// Records the Greenhouse demo with a Debug build of Moodboard, then writes the edit that render.swift cuts it with.
//   node tools/video/take.mjs <Moodboard.app> <folder>   records take.mov and take.json, then writes edit.json
//   node tools/video/take.mjs --edit <folder>            writes edit.json and chapters.vtt again from take.json
// A take wipes the Debug build's data and sets ~/Moodboard Demo aside until it ends.

import { execFileSync, spawn, spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const home = os.homedir();
const support = path.join(home, "Library/Application Support/Moodboard Debug");
const demo = path.join(home, "Moodboard Demo");
const plantFile = path.join(demo, "src/components/PlantCard.tsx");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// The welcome sheet sits in the middle of the 1440 by 900 window.
const sheet = { x: 440, y: 243 };
const demoButton = { x: 150, y: 270 };
const toolbar = { grid: { x: 603, y: 48 }, list: { x: 635, y: 48 } };
const closeButton = { x: 1415, y: 56 };

function ask(method, params = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(path.join(support, "mcp.sock"));
    let buffer = "";
    const timer = setTimeout(() => socket.destroy(new Error(`${method} timed out`)), 20000);
    socket.on("connect", () => socket.write(JSON.stringify({ id: 1, method, params }) + "\n"));
    socket.on("data", (data) => {
      buffer += data;
      const end = buffer.indexOf("\n");
      if (end < 0) return;
      socket.end();
      const reply = JSON.parse(buffer.slice(0, end));
      reply.error ? reject(new Error(`${method}: ${reply.error}`)) : resolve(reply.result);
    });
    socket.on("error", reject);
    socket.on("close", () => clearTimeout(timer));
  });
}

async function until(check, ms, what) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try {
      const value = await check();
      if (value) return value;
    } catch {}
    await sleep(250);
  }
  throw new Error(`Gave up waiting for ${what}.`);
}

function lines(child) {
  const waiting = [];
  readline.createInterface({ input: child.stdout }).on("line", (line) => {
    const event = JSON.parse(line);
    if (event.event === "error") console.error("record:", event.message);
    if (event.event === "gap") console.log(`  gap ${event.from.toFixed(2)} to ${event.to.toFixed(2)} ${JSON.stringify(event.statuses)}`);
    for (const each of waiting.filter((w) => w.name === event.event)) each.resolve(event);
  });
  child.on("exit", () => {
    for (const each of waiting) each.reject(new Error(`The recorder stopped before it said ${each.name}.`));
  });
  return (name) => new Promise((resolve, reject) => waiting.push({ name, resolve, reject }));
}

/** Everything the edit needs, in seconds of the movie. */
class Log {
  constructor(wallMs) {
    this.wallMs = wallMs;
    this.marks = {};
    this.pointer = [];
    this.cards = { radius: [], name: [] };
  }
  now() {
    return (Date.now() - this.wallMs) / 1000;
  }
  mark(name) {
    this.marks[name] = this.now();
    console.log(`  ${this.marks[name].toFixed(2)}  ${name}`);
  }
  data() {
    return { marks: this.marks, pointer: this.pointer, cards: this.cards };
  }
}

function inside(frame, margin = 0) {
  return frame.x >= margin && frame.y >= 70 + margin && frame.x + frame.w <= 1440 - margin && frame.y + frame.h <= 900 - margin;
}

const center = (r) => ({ x: r.x + r.w / 2, y: r.y + r.h / 2 });

async function story(log) {
  async function move(point) {
    log.pointer.push({ at: log.now(), kind: "move", x: point.x, y: point.y });
    await ask("debug.move", point).catch(() => {});
  }
  async function click(point, params = {}) {
    log.pointer.push({ at: log.now(), kind: "click", x: point.x, y: point.y });
    await ask("debug.click", { ...point, ...params });
  }
  // The bar, the panel's close button and Start over are SwiftUI, and a click handed straight to SwiftUI presses
  // nothing. So the take calls what those buttons call, while the cursor in the cut clicks them.
  async function press(point, method, params = {}) {
    log.pointer.push({ at: log.now(), kind: "click", x: point.x, y: point.y });
    await ask(method, params);
  }
  async function stageRect(selector) {
    const { stage } = await ask("debug.rects");
    const found = await ask("debug.eval", { js: `const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height, iw: innerWidth }` });
    const k = stage.w / found.iw;
    return { x: stage.x + found.x * k, y: stage.y + found.y * k, w: found.w * k, h: found.h * k };
  }

  log.pointer.push({ at: log.now() + 0.5, kind: "show", x: 960, y: 760 });
  await sleep(1800);
  const button = { x: sheet.x + demoButton.x, y: sheet.y + demoButton.y };
  await move(button);
  await sleep(450);
  log.mark("demo");
  // The sheet takes the click in its own coordinates. The cut draws it where the button is in the window.
  await click(button, { ...demoButton, sheet: true });
  log.pointer.push({ at: log.now() + 0.8, kind: "move", x: 760, y: 560 });

  await until(async () => (await ask("debug.onscreen")).length > 0, 60000, "the first tile");
  log.mark("arriving");
  // Only the most visible tiles get a live stage. The rest show a picture of their component.
  await until(async () => {
    const state = await ask("debug.state");
    const shown = state.tiles.filter((tile) => inside(tile.frame, -40));
    return shown.length >= 12 && state.platesPending === 0 && shown.every((tile) => tile.plate || tile.ready) && state.running >= 10;
  }, 120000, "the wall to run");
  log.mark("live");
  await sleep(2600);

  // Where each component lands depends on the order they arrive in, so the scroll aims for a Plant card. The wall
  // repeats, so there are several, and the one it aims for is the one about a screen's scroll further down.
  const goal = { x: 520, y: 560 };
  const plants = async () => (await ask("debug.onscreen")).filter((tile) => /PlantCard/.test(tile.id));
  const away = (tile) => ({ x: goal.x - center(tile.frame).x, y: goal.y - center(tile.frame).y });
  const cost = (d) => Math.abs(d.y + 550) + Math.abs(d.x) / 2;
  const aim = (await plants()).map(away).sort((a, b) => cost(a) - cost(b))[0];
  if (!aim) throw new Error("No Plant card is near enough to scroll to.");
  const frames = 120;
  log.mark("scroll");
  await ask("debug.scroll", { dx: Math.round(aim.x / frames), dy: Math.round(aim.y / frames), frames });
  await sleep(3400);
  const distance = (tile) => Math.hypot(away(tile).x, away(tile).y);
  const plant = (await plants()).filter((tile) => inside(tile.frame, 24)).sort((a, b) => distance(a) - distance(b))[0];
  if (!plant) throw new Error("No Plant card is fully on screen after the scroll.");
  log.marks.plant = plant.frame;

  await move(center(plant.frame));
  await sleep(500);
  log.mark("open");
  await click(center(plant.frame));
  await sleep(2600);

  const water = await stageRect("button");
  log.marks.card = await stageRect("article");
  // The tile's loop may have watered the plant before it was opened, and then Water does nothing.
  if (await ask("debug.eval", { js: "return document.querySelector('button').disabled" })) {
    const { stage } = await ask("debug.rects");
    const startOver = { x: stage.x + stage.w / 2 - 58, y: stage.y + stage.h + 29 };
    await move(startOver);
    await sleep(450);
    log.mark("startOver");
    await press(startOver, "debug.action", { name: "startOver" });
    await sleep(1300);
  }
  await move(center(water));
  await sleep(400);
  log.mark("water");
  await click(center(water));
  await sleep(1700);

  const { panel } = await ask("debug.rects");
  const radius = await ask("debug.eval", { target: "panel", js: `const label = [...document.querySelectorAll("body *")].find((el) => !el.children.length && el.textContent.trim() === "Radius"); const r = label.getBoundingClientRect(); return { x: r.x, y: r.y, w: r.width, h: r.height }` });
  const grip = { x: panel.x + radius.x + 120, y: panel.y + radius.y + radius.h / 2 };
  const literal = () => /rounded-\[\d+px\]/.exec(fs.readFileSync(plantFile, "utf8").split("\n").find((line) => line.includes("<article")) ?? "")?.[0];
  log.cards.radius.push({ at: log.now(), text: fs.readFileSync(plantFile, "utf8") });
  await move(grip);
  await sleep(700);
  let seen = literal();
  const watch = setInterval(() => {
    const now = literal();
    if (now && now !== seen) {
      seen = now;
      log.cards.radius.push({ at: log.now(), text: fs.readFileSync(plantFile, "utf8") });
    }
  }, 15);
  log.mark("drag");
  const dragged = { at: log.now(), kind: "drag", x: grip.x, y: grip.y, dx: 100, ease: true };
  await ask("debug.drag", { x: grip.x, y: grip.y, dx: 100, steps: 84, ease: true });
  dragged.dur = log.now() - dragged.at;
  log.pointer.push(dragged);
  log.mark("dragged");
  await sleep(1800);
  clearInterval(watch);

  const title = await stageRect("h3");
  log.marks.title = title;
  log.pointer.push({ at: log.now() + 0.3, kind: "move", x: title.x + title.w + 120, y: title.y + title.h + 70 });
  await sleep(900);
  log.mark("typing");
  const source = fs.readFileSync(plantFile, "utf8");
  log.cards.name.push({ at: log.now(), text: source });
  await sleep(2700);
  fs.writeFileSync(plantFile, source.replace('name = "Monstera"', 'name = "Fiddle leaf fig"'));
  log.mark("renamed");
  log.cards.name.push({ at: log.now(), text: fs.readFileSync(plantFile, "utf8") });
  await until(async () => (await ask("debug.eval", { js: "return document.querySelector('h3').textContent" })) === "Fiddle leaf fig", 10000, "the tile to redraw");
  log.mark("redrawn");
  await sleep(2000);

  await move(closeButton);
  await sleep(350);
  log.mark("close");
  await press(closeButton, "debug.close");
  await sleep(1600);
  await move(toolbar.grid);
  await sleep(350);
  log.mark("grid");
  await press(toolbar.grid, "debug.view", { mode: "grid" });
  await sleep(2600);
  await move(toolbar.list);
  await sleep(350);
  log.mark("list");
  await press(toolbar.list, "debug.view", { mode: "list" });
  await sleep(2800);
  log.pointer.push({ at: log.now(), kind: "hide" });
  await sleep(700);
  log.mark("end");
}

/** Where the whole picture is black. The app never draws that, but the capture does when the window leaves the display. */
function blackStretches(movie) {
  const { stderr } = spawnSync("ffmpeg", ["-hide_banner", "-i", movie, "-vf", "blackdetect=d=0.05:pic_th=0.98:pix_th=0.03", "-an", "-f", "null", "-"], { encoding: "utf8" });
  return [...stderr.matchAll(/black_start:([\d.]+) black_end:([\d.]+)/g)].map(([, from, to]) => `${(+from).toFixed(2)} to ${(+to).toFixed(2)} s`);
}

async function take(app, folder) {
  const binary = path.join(app, "Contents/MacOS/Moodboard");
  const record = path.join(folder, "bin/record");
  if (!fs.existsSync(record)) throw new Error(`${record} is missing. Run tools/video/make.sh, which builds it.`);
  const running = (() => {
    try {
      return Boolean(execFileSync("pgrep", ["-f", binary], { encoding: "utf8" }).trim());
    } catch {
      return false;
    }
  })();
  if (running) throw new Error("Quit the Debug build first.");
  fs.rmSync(support, { recursive: true, force: true });
  const aside = fs.existsSync(demo) ? `${demo} (before take ${Date.now()})` : null;
  if (aside) fs.renameSync(demo, aside);
  let recorder;
  try {
    // In the background, so the take doesn't take over the screen. The app parks its window off screen once it's sized.
    execFileSync("open", ["-g", "-n", app, "--args", "-MoodboardRecording", "YES"]);
    await until(() => ask("debug.state"), 30000, "the app to start");
    const pid = execFileSync("pgrep", ["-n", "-f", binary], { encoding: "utf8" }).trim();
    await ask("debug.resize", { w: 1440, h: 900 });
    const parked = await ask("debug.recording", { on: true });
    if (!parked.onDisplay) throw new Error("The parked window left the display, and it would stop drawing there.");
    await sleep(1000);
    recorder = spawn(record, ["--pid", pid, "--out", path.join(folder, "take.mov")], { stdio: ["ignore", "pipe", "inherit"] });
    const next = lines(recorder);
    const started = await next("started");
    const log = new Log(started.wallMs);
    let watching = true;
    const watcher = (async () => {
      let hidden = false;
      while (watching) {
        const asked = Date.now();
        const state = await ask("debug.state").catch(() => null);
        const slow = Date.now() - asked;
        if (state && state.occluded !== hidden) console.log(`  ${log.now().toFixed(2)}  window ${state.occluded ? "hidden" : "shown"}`);
        if (slow > 250) console.log(`  ${log.now().toFixed(2)}  the app took ${slow} ms to answer`);
        hidden = state?.occluded ?? hidden;
        await sleep(150);
      }
    })();
    await story(log).finally(() => (watching = false));
    await watcher;
    recorder.kill("SIGINT");
    const stopped = await next("stopped");
    console.log(`recorded ${stopped.frames} frames over ${stopped.seconds.toFixed(1)} s, ${stopped.dropped} dropped`);
    fs.writeFileSync(path.join(folder, "take.json"), JSON.stringify(log.data(), null, 1));
    const black = blackStretches(path.join(folder, "take.mov"));
    if (black.length) throw new Error(`The take goes black from ${black.join(", ")}. Something took the window off the display. Record it again.`);
  } finally {
    recorder?.kill("SIGINT");
    await ask("debug.recording", { on: false }).catch(() => {});
    try {
      execFileSync("pkill", ["-f", binary]);
    } catch {}
    await sleep(1000);
    fs.rmSync(demo, { recursive: true, force: true });
    if (aside) fs.renameSync(aside, demo);
  }
}

// MARK: The edit

/** The class list around a literal, cut at whole classes, the way an editor scrolled to it would show it. */
function classExcerpt(line, literal) {
  const [, head, list, tail] = /^(\s*<\w+ className=")([^"]*)(".*)$/.exec(line);
  const classes = list.split(" ");
  const at = classes.findIndex((each) => literal.test(each));
  const shown = classes.slice(Math.max(0, at - 1), at + 3);
  const text = `${head}${at > 1 ? "… " : ""}${shown.join(" ")}${at + 3 < classes.length ? " …" : ""}${tail}`;
  const start = text.indexOf(classes[at]);
  return { text, mark: [start, start + classes[at].length] };
}

function propsExcerpt(line) {
  const [, head, name, tail] = /^(export function \w+\(\{ )(name = "[^"]*")[^}]*(\}.*)$/.exec(line);
  const text = `${head}${name}, … ${tail}`;
  const start = text.indexOf('"') + 1;
  return { text, mark: [start, text.indexOf('"', start)] };
}

function radiusFrame(at, file) {
  const rows = file.split("\n");
  const index = rows.findIndex((row) => row.includes("<article"));
  const focus = classExcerpt(rows[index], /^rounded-\[\d+px\]$/);
  return { at, lines: [rows[index - 1], focus.text, rows[index + 1]], mark: [1, ...focus.mark] };
}

function nameFrames(log) {
  const [before, after] = log.cards.name;
  const rows = before.text.split("\n");
  const index = rows.findIndex((row) => row.startsWith("export function"));
  const rest = rows.slice(index + 1, index + 3);
  const was = propsExcerpt(rows[index]);
  const frames = [{ at: before.at, lines: [was.text, ...rest], caret: [0, was.mark[1]] }];
  frames.push({ at: before.at + 0.5, lines: [was.text, ...rest], mark: [0, ...was.mark] });
  const typed = "Fiddle leaf fig";
  const open = was.text.slice(0, was.mark[0]);
  const close = was.text.slice(was.mark[1]);
  const step = Math.min(0.075, (after.at - before.at - 1.2) / typed.length);
  for (let n = 0; n <= typed.length; n++) {
    frames.push({ at: before.at + 0.9 + n * step, lines: [open + typed.slice(0, n) + close, ...rest], caret: [0, open.length + n] });
  }
  const now = propsExcerpt(after.text.split("\n")[index]);
  frames.push({ at: after.at, lines: [now.text, ...rest], mark: [0, ...now.mark] });
  return frames;
}

function output(segments, source) {
  let start = 0;
  for (const segment of segments) {
    if (source < segment.from) return start;
    if (source <= segment.to) return start + (source - segment.from) / (segment.speed ?? 1);
    start += (segment.to - segment.from) / (segment.speed ?? 1);
  }
  return start;
}

function edit(take) {
  const m = take.marks;
  // The wall stays empty until the first tile arrives, so the cut dissolves from the closing sheet straight to the
  // arriving tiles, and plays their arrival a little faster.
  const lasting = (from, to, seconds) => ({ from, to, speed: Math.max(1, (to - from) / seconds) });
  const segments = [
    { from: 0.3, to: m.demo + 0.4 },
    { ...lasting(m.arriving, m.live - 0.4, 1.6), fade: 0.4 },
    { from: m.live - 0.4, to: m.end },
  ].filter((segment) => segment.to > segment.from);
  const card = m.card;
  const cardCenter = center(card);
  const title = m.title;
  const camera = [
    { at: 0, zoom: 1.3, x: 720, y: 450, snap: true },
    { at: m.demo + 0.3, zoom: 1, response: 1.3 },
    { at: m.open - 1.1, zoom: 1.12, x: center(m.plant).x, y: center(m.plant).y, response: 1 },
    { at: m.open - 0.05, zoom: 1, response: 0.7 },
    { at: m.water - 0.9, zoom: 1.5, x: cardCenter.x, y: cardCenter.y + 20, response: 0.85 },
    { at: m.drag - 1.4, zoom: 1.15, x: 860, y: 360, response: 0.9 },
    { at: m.typing - 0.7, zoom: 1.75, x: title.x + 210, y: title.y + 130, response: 0.9 },
    { at: m.redrawn + 0.9, zoom: 1.25, x: cardCenter.x + 120, y: cardCenter.y, response: 1 },
    { at: m.close - 0.5, zoom: 1, response: 0.9 },
  ];
  const cards = [
    { from: m.drag - 0.9, to: m.dragged + 1.5, title: "src/components/PlantCard.tsx", x: 64, bottom: 64, frames: take.cards.radius.map(({ at, text }) => radiusFrame(at, text)) },
    { from: m.typing - 0.4, to: m.redrawn + 1.4, title: "src/components/PlantCard.tsx", x: 64, bottom: 64, frames: nameFrames(take) },
  ];
  const at = (source) => output(segments, source);
  const chapters = [
    [0, "Try the demo, or connect a Next.js project."],
    [at(m.live - 0.4), "Every component runs live, in a loop."],
    [at(m.open - 0.6), "Open a tile and it's yours to play with."],
    [at(m.drag - 1.2), "Move a dial and it rewrites your source."],
    [at(m.typing - 0.6), "Edit the file and the tile redraws."],
    [at(m.close - 0.4), "See it all as a wall, a grid or a list."],
  ];
  return {
    edit: { source: "take.mov", out: "cut.mov", fps: 60, size: [1920, 1200], points: [1440, 900], segments, camera, pointer: take.pointer, cards, loopFade: 0.7, poster: at(m.scroll - 0.3) },
    chapters,
  };
}

function vtt(chapters, duration) {
  const stamp = (s) => new Date(s * 1000).toISOString().slice(11, 23);
  return "WEBVTT\n\n" + chapters.map(([start, text], i) => `${i + 1}\n${stamp(start)} --> ${stamp(chapters[i + 1]?.[0] ?? duration)}\n${text}\n`).join("\n");
}

function writeEdit(folder) {
  const take = JSON.parse(fs.readFileSync(path.join(folder, "take.json"), "utf8"));
  const { edit: cut, chapters } = edit(take);
  fs.writeFileSync(path.join(folder, "edit.json"), JSON.stringify(cut, null, 1));
  fs.writeFileSync(path.join(folder, "chapters.vtt"), vtt(chapters, output(cut.segments, Infinity)));
  console.log(`wrote ${path.join(folder, "edit.json")} and chapters.vtt`);
}

const args = process.argv.slice(2);
if (args[0] === "--edit") {
  writeEdit(path.resolve(args[1]));
} else {
  const [app, folder] = args.map((each) => path.resolve(each));
  if (!app || !folder) throw new Error("Usage: node tools/video/take.mjs <Moodboard.app> <folder>");
  fs.mkdirSync(folder, { recursive: true });
  await take(app, folder);
  writeEdit(folder);
}
