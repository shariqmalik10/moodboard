# Demo video tools

These tools make the film on the website. A script drives the app while one of its windows records, and the recording is then cut with zooms, a drawn cursor, code cards, and chapters.

| File | What it does |
| --- | --- |
| `make.sh` | Records the Greenhouse demo with a Debug build of Moodboard and writes the film to `docs/media/`. |
| `take.mjs` | Drives Moodboard through a take, logs it, and writes the edit. |
| `record.swift` | Records one window of any Mac app into a movie. |
| `render.swift` | Cuts a movie as an edit file describes: segments, camera, cursor, and code cards. |

`record` and `render` work with any Mac app. `take.mjs` is specific to Moodboard.

## Record the demo again

You need Xcode, Node 20.19 or newer, and ffmpeg (`brew install ffmpeg`). The app you run the script from, such as Terminal, needs Screen Recording permission in **System Settings > Privacy & Security**.

1. Clone the repository fresh. The film shows every component the build contains, and a checkout with private demos in `src/demos/` would put them in it.
2. Quit any Debug build of Moodboard. If the installed app has the Greenhouse demo connected, quit it too, because the take moves `~/Moodboard Demo` aside while it records.
3. Run the script from the repository root:

   ```bash
   tools/video/make.sh
   ```

The script installs the packages, builds the web parts and a Debug app, and records a take of about 40 seconds. It writes `demo.mp4`, `poster.jpg`, and `chapters.vtt` to `docs/media/`. The take, its log, and the edit stay in `build/video/`.

The window records off screen. Only a strip one point wide shows at the right edge of your rightmost display, and the script never moves your pointer, so you can keep working. Don't open Mission Control or switch Spaces while it records.

A take starts from nothing. It deletes the Debug build's data in `~/Library/Application Support/Moodboard Debug`, and it moves an existing `~/Moodboard Demo` aside until the take ends. It never touches the installed app's data in `~/Library/Application Support/Moodboard`.

If the take goes black, the script stops and says where. Something took the window off the display, so run the script again.

To record with a Debug build you already have, pass its path:

```bash
tools/video/make.sh native/build/Build/Products/Debug/Moodboard.app
```

## Change the cut

The edit is the `edit()` function in `take.mjs`. It decides which stretches to keep and how fast they play, where the camera goes, what the code cards show, and the chapter titles. After you change it, cut the last take again without recording:

```bash
tools/video/make.sh --recut
```

To check a few frames before you cut the whole film, write the edit again and ask `render` for stills at output times in seconds. It writes them as PNG files next to `cut.mov`:

```bash
node tools/video/take.mjs --edit build/video
```

```bash
build/video/bin/render build/video/edit.json --stills 2.5,12,25
```

## Record another app

1. Build the two tools:

   ```bash
   swiftc -O -parse-as-library -swift-version 6 tools/video/record.swift -o record
   ```

   ```bash
   swiftc -O -parse-as-library -swift-version 6 tools/video/render.swift -o render
   ```

2. Open the app and find its process ID with `pgrep`.
3. Start the recorder with `./record --pid <pid> --out take.mov`. Note the `wallMs` in the first line it prints.
4. Drive the app. Log each moment you want to cut on, and each pointer event, in seconds since `wallMs`.
5. Stop the recorder with Control-C.
6. Write `edit.json` from your log, as [the edit file](#the-edit-file) describes.
7. Run `./render edit.json`, then encode `cut.mov` with the `ffmpeg` lines at the end of `make.sh`.

These lessons from the Moodboard take apply to any app:

- `record` captures the window, not the screen, so the window can sit almost entirely off screen. Keep at least one point of it on a display. macOS stops a view's display link when its window is on no display, and the recording freezes.
- WebKit stops drawing a page when it decides the window is covered. A Moodboard take turns that detection off. See `makeWebView` in `native/Moodboard/Web/WebHost.swift`.
- Drive the app through its own hooks rather than the system pointer, so the person at the Mac keeps their mouse. The cut draws a cursor from the pointer log instead.
- SwiftUI controls ignore mouse events sent straight to a view. Call what the control calls, and log a click where the control is, so the cut still shows the press.
- Mission Control or a change of Space can take the window off the display halfway through. Make the window join all Spaces and stay put while it records, and check the movie for black frames afterwards.
- Aim at what the app reports, such as a tile's frame, rather than at fixed coordinates. A layout can change from one take to the next.

## Reference

### `record`

```
record --pid <pid> --out take.mov [--fps 60] [--mbps 40]
```

`record` captures the largest window of the app with that process ID, with its sheets and other child windows, as HEVC at the window's size in pixels. It stops on SIGINT or SIGTERM, and prints one JSON object per line:

| Event | Fields |
| --- | --- |
| `started` | `wallMs`, the wall-clock time of the first frame in milliseconds, and the window's size and position. |
| `gap` | `from` and `to` in seconds of the movie, when no new frame arrived for over 0.3 seconds, and `statuses`, which tell a still window from a stall. |
| `stopped` | `frames`, `dropped`, `seconds`, and `status`. |
| `error` | `message`. |

### `render`

```
render edit.json [--stills 1.5,8,20.25]
```

`render` cuts `source` into `out` as the edit file describes. With `--stills`, it writes PNG files at those output times instead of a movie.

### The edit file

Times are seconds of the source movie, and positions are window points from the top left, unless a field says otherwise.

| Field | Meaning |
| --- | --- |
| `source` | The movie to cut, relative to the edit file. |
| `out` | The movie to write. |
| `fps` | The output frame rate. The default is 60. |
| `size` | The output size in pixels, as `[width, height]`. The default is `[1920, 1200]`. |
| `points` | The window's size in points. The default is `[1440, 900]`. |
| `segments` | The stretches to keep, in order. Each has `from` and `to`, an optional `speed`, where 2 plays the stretch twice as fast, and an optional `fade`, in output seconds, to dissolve in from the stretch before. |
| `camera` | Camera keys. Each has `at`, a `zoom` of 1 or more, and the point to center, `x` and `y`, which default to the window's center. The camera eases to each key with a spring whose `response` defaults to 0.9 seconds. `snap: true` jumps to the key instead. |
| `pointer` | The drawn cursor, as `show`, `move`, `click`, `drag`, and `hide` events with `at`, `x`, and `y`. The cursor arrives at a `move` point at `at`. For a `click`, it arrives 0.12 seconds early and shows a press and a ripple at `at`. A `drag` presses at `at`, then moves the cursor `dx` points along x over `dur` seconds, 0.3 by default, and eases if `ease` is true. |
| `cards` | Code cards. Each has `from`, `to`, `title`, and `x` and `bottom` in output pixels. Each of its `frames` has `at`, `lines`, an optional `mark` of `[line, first column, end column]`, and an optional `caret` of `[line, column]`. |
| `loopFade` | Output seconds at the end that dissolve into the first frame, so the film loops cleanly. |

`take.mjs` also writes `poster`, the output time that `make.sh` takes the poster from. `render` ignores it.

### `take.mjs`

```
node tools/video/take.mjs <Moodboard.app> <folder>
node tools/video/take.mjs --edit <folder>
```

The first form needs `<folder>/bin/record`. It records `take.mov`, logs the take to `take.json`, and writes `edit.json` and `chapters.vtt`. The `--edit` form writes those two files again from `take.json`.

The take drives the app through its debug socket, which only a Debug build answers. It calls `debug.state`, `debug.resize`, `debug.recording`, `debug.move`, `debug.click`, `debug.drag`, `debug.scroll`, `debug.onscreen`, `debug.rects`, `debug.eval`, `debug.view`, `debug.close`, and `debug.action`, which `native/Moodboard/MCP/Tools.swift` answers.

The website builds the chapter strip under the film from `chapters.vtt`, so a new cut brings its own chapters.
