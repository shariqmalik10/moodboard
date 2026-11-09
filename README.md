# Moodboard

A Mac app that puts your React components on an endless wall, running live. Each tile plays its component in a loop. Open one to use it, tune it with dials, and the dials rewrite the literals in your source. Edit the source and the tile changes.

[![The wall, running the Greenhouse demo. Click to watch the demo film on the website.](docs/media/poster.jpg)](https://moodboard.shariqmalik.dev/)

Moodboard runs on your Mac only. It has no account and sends nothing anywhere. It connects to three things you may already have:

- **Next.js projects.** Point it at a project folder and its client components join the wall.
- **Paper.** Import frames from the Paper design app and tune them before they become code.
- **Claude Code.** Claude Code can see the wall, open components, and set dials. **Send** hands a tuned component to Claude Code to build into your project.

Website: <https://moodboard.shariqmalik.dev/>

## Install it

Moodboard needs macOS 26 or later. To connect projects, it also needs Node 20.19 or newer.

### Download the app

The prebuilt app is for Apple silicon. This command downloads the latest release into `~/Applications` and opens it:

```bash
curl -fsSL https://raw.githubusercontent.com/shariqmalik10/moodboard/main/scripts/install.sh | sh
```

To install somewhere else, set `MOODBOARD_DIR` before `sh`.

You can also download `Moodboard.zip` from the [latest release](https://github.com/shariqmalik10/moodboard/releases/latest). The app is not notarized, so macOS blocks a copy downloaded with a browser. To open it, try once, then open **System Settings > Privacy & Security** and click **Open Anyway**. The command above doesn't hit this, because `curl` doesn't mark the file as downloaded.

### Build from source

Building needs Xcode and Node 20.19 or newer. It works on Intel Macs too.

```bash
git clone https://github.com/shariqmalik10/moodboard.git
```

```bash
cd moodboard && scripts/build.sh
```

`scripts/build.sh` installs the packages, builds the web parts and the app, copies the app to `~/Applications`, and opens it. `scripts/build.sh --zip` writes `build/Moodboard.zip` instead, which is how a release is made.

## Start

The first launch opens a welcome sheet with three steps:

1. **Node.** The sheet checks for Node 20.19 or newer, which runs your projects.
2. **Something for the wall.** **Try the Greenhouse demo** copies a small Next.js app to `~/Moodboard Demo` and connects it. Fourteen plant-care components arrive within a few seconds. Edit a file in `~/Moodboard Demo/src/components` and watch its tile change. **Connect a project…** picks one of your own instead.
3. **Claude Code.** **Add to Claude Code** registers the app as an MCP server for your user. It runs this command, which you can also run yourself:

   ```bash
   claude mcp add -s user moodboard -- ~/Applications/Moodboard.app/Contents/MacOS/Moodboard --mcp
   ```

Every step is optional. **Help > Welcome to Moodboard** opens the sheet again.

**Send** runs the `claude` command, which signs in separately from the Claude desktop app. Sign it in once:

```bash
claude auth login
```

The demo's source is in [`demo/`](demo).

## Use the wall

- Scroll or drag to move. Pinch or ⌘-scroll to zoom.
- A tile assembles as you scroll onto it. Its position decides how far along it is, so stopping halfway leaves it halfway.
- Click a tile to open it. Press Esc or click outside it to close it. Click it again while it flies home to bring it back.
- Press Tab and Shift-Tab to walk the tiles. Press Return or Space to open one.
- To add a picture or a film, drop the file on the wall or click **+**. The app keeps its own copy and deletes the copy when you remove the tile.

## Use a component yourself

Click a tile. The loop stops where it stands and the component is yours, so hover it, click it, and type in it. Nothing plays again until you ask.

- **Start over** puts the component back to how it began.
- **Watch it play** plays the demo once and stops. Move the pointer or press a key to end it early.
- Closing the tile puts it back in its loop.

## Change what you see

The bar at the top of the window switches the view and the project. The app opens on the Wall with every project each time.

| View | Keys | What it shows |
| --- | --- | --- |
| Wall | ⌘1 | The endless wall. Every tile in full view runs its loop. |
| Grid | ⌘2 | Every item in an equal cell, grouped by project, with a top and a bottom. Only the tile under the pointer runs. Press − or + in the strip, or ⌘− and ⌘+, to change the cell size. |
| List | ⌘3 | Every component in a sidebar with a thumbnail, one in your hands, and its dials beside it. The arrow keys, ⌘[, and ⌘] move through the rows. |

Choose a project in the bar to show only its items. **Pictures** appears once the wall has a picture, and List does not offer it. A filter never changes your board. Adding something takes you to the Wall with every project showing, so you see it arrive.

## See where each component stands

Grid captions and List rows show one mark for each component. The Wall shows none.

| Mark | Meaning |
| --- | --- |
| **Paper changed** | The frame in Paper no longer matches the design here. |
| **Changed since built** | You tuned or updated it after it was built. Moving it back returns it to **Built**. |
| **N tuned** | You moved N dials and it has never been built. |
| **Built** | The code was built from exactly this tune and design. |

A note shows beside the mark. To find components, press ⌘F or type in **Search**. Press Return to use the first result, and Esc to clear. On the Wall, ⌘F goes to Grid first.

The chips under the search answer **To build**, **Notes**, **Paper changed**, and **Built**. A chip appears only when its count is above zero. **Paper changed** adds **Update all**, and ⇧⌘U does the same from anywhere.

## Tune and compare

- To see the design without your tune, hold **Hold to compare** or hold Option. Letting go puts the tune back.
- The list under the dials shows each dial you moved, from what to what. Revert one dial with its arrow, or use **Reset all**. **Copy** puts the list on the clipboard.
- DialKit's own menu at the top of the panel saves named versions of a tune.

## Go from Paper to your code

1. Design the component in Paper. In Claude Code, the `design_in_paper` prompt starts this step.
2. Import the frame. Click the import button in the bar at the top of the window and pick a frame, or ask Claude Code to import it by name. An import only reads from Paper.
3. Open the tile and tune it. Every dial and motion curve applies at once and saves itself. When the frame changes in Paper, the panel says so and offers **Update**.
4. Hand it to Claude Code. Write what you want in the note, choose the folder, and press **Send** or ⌘Return. Return does not send. You can also ask Claude Code for "the component open on my wall", or use the `implement_component` prompt.

**Send** runs `claude -p` in the folder you chose, with permission to edit files there. The brief carries your note under "What the person wants". When the run succeeds, the component reads **Built** and the note clears. A failed run keeps the note. The **…** menu has **Copy Brief for Claude Code** and **Mark as Built** for work you hand over another way.

While the app is in front, it reads each imported frame from Paper every 20 seconds to compare it. It never writes to Paper.

An update keeps your tune on every dial whose value the design still has. Paper dials are named after their values, so a dial on a changed value no longer applies. The panel names each one, and `get_component` reports them too.

## Connect a Next.js project

To put a project's components on the wall, do one of these:

- Drag the project's folder from Finder onto the wall.
- Choose **File > Connect Next.js Project…** (⇧⌘O), or click the link button in the bar and then **Connect a project…**, and pick the folder.
- Ask Claude Code. See [Connect from Claude Code](#connect-from-claude-code).

The folder can be the app itself, any folder inside it, or a monorepo. In a monorepo with one Next.js app, the app connects. With several, the app asks which one. The project needs its packages installed, and Node 20.19 or newer on your PATH. If something is missing, the app says what to do, such as which install command to run. Connecting a project again is safe, and restarts one that stopped.

The first time, macOS may ask whether Moodboard can read files in your Documents, Desktop, or Downloads folder. Choose **Allow**. If you choose **Don't Allow**, turn Moodboard on later in System Settings, under **Privacy & Security > Files and Folders**. The app is signed ad hoc, so macOS may ask again after you install a new build.

What happens next:

- The app starts a small Vite server for the project, on this Mac only. It runs each exported client component in isolation, inside every `*Provider` your `layout.tsx` files wrap around the page. Its cache lives under `~/Library/Application Support/Moodboard/vite/`, so nothing is written into the project.
- The first tiles arrive within a few seconds. The first time a project connects, Vite prepares its packages, which can take up to half a minute. A component that throws or draws nothing stays off the wall, and the link popover lists it with the reason under **can't stand alone**.
- Saving a file in your editor redraws its tile, usually in under 200 ms. A new file adds a tile, and a deleted file removes it. While a file has a syntax error, its tile keeps its last good look.
- The demo loop presses real buttons, so the page refuses every request except reads, and links and forms go nowhere.

### Dials edit your source

Open a project tile to see two kinds of dials:

- **Sample props** are values the app made up from the component's TypeScript types, so it has something to show. They stay in the app and never touch your files.
- Every other dial is a literal in your code, such as a Tailwind class, an inline style, or a value in a stylesheet. Moving it rewrites that one literal in the file, while you drag. The tile then redraws through the project's own hot reload.

Keep these in mind:

- A dial only writes when you move it. Opening the panel writes nothing.
- A dial in a stylesheet changes every component that uses that rule. The line under the panel names each file its dials edit.
- If the file changes in your editor while you tune, your editor wins. The panel reloads from the file and the app says so.
- **Hold to compare** and **Mark as Built** are hidden for project components, because the source is the record. The mark reads **N written** and lists what the dials changed since the app started.
- To disconnect, open the link popover, click **…** beside the project, and choose **Disconnect**. Its tiles leave the wall. Your files stay as they are.

### Connect from Claude Code

After you add Moodboard to Claude Code (see [Start](#start)), open Claude Code in your project's folder and ask:

```text
connect this project to moodboard
```

Claude Code calls `connect_project` with no path, which means the folder it's working in. Moodboard opens behind your other windows if it's closed. The tool waits for the first tiles, then says how many components are on the wall, which ones aren't and why, and what to do about any problem. The `connect` prompt asks for the same thing. In Claude Code, type `/mcp__moodboard__connect`.

If Claude Code says it has no `moodboard` tools, add the server and start Claude Code again:

```bash
claude mcp add -s user moodboard -- ~/Applications/Moodboard.app/Contents/MacOS/Moodboard --mcp
```

Server components that are `async`, fonts from `next/font/local`, and unsaved editor changes are not shown as they are in the real app. Google fonts load only while you are online.

## What Claude Code can call

The app answers through `Moodboard --mcp`. If the wall is closed, the first tool call opens it.

| Tool | What it does |
| --- | --- |
| `status` | Reports the component count, the open component, and what Paper has open and selected. |
| `list_components` | Lists every component with its id, title, project, whether it is on the wall, and its place in the loop: `tuned`, `needsBuilding`, `paper`, `builtAt`, `changedSinceBuilt`, `builtInto`, `tuneNoLongerApplies`, and `note`. |
| `get_component` | Returns the same place fields and the brief for `id`, or for the open component. The brief holds your note, the tuned values, the JSX with the tune applied, and the CSS. |
| `import_from_paper` | Imports the selected frames, the frame named by `frame`, or the node named by `fileId` and `nodeId`. Importing a frame again updates it, and the result lists any tune that no longer applies. |
| `open_component` | Brings the window forward and opens `id`, or selects it in List. It shows every project first if a filter hides `id`. |
| `set_dials` | Sets dial values on `id`, or on the open component. An unknown dial returns the real names. On a project component it writes the source file, even with the panel closed. |
| `set_note` | Writes the note on `id`, or on the open component. |
| `mark_built` | Records that `id` is built from its current tune and design, and clears its note. |
| `connect_project` | Connects the Next.js project at `path`, or the folder Claude Code is working in. A relative `path` starts from that folder. It waits for the first tiles and reports how many are on the wall, which aren't and why, and any problem. |
| `list_projects` | Lists connected projects, how many components are on the wall, which are not shown and why, and any problem. |
| `disconnect_project` | Disconnects `project` and removes its tiles. The files stay as they are. |

The app also offers five prompts: `connect`, `design_in_paper`, `implement_component`, `build_tuned`, and `apply_notes`.

## Where your data lives

The app keeps everything in `~/Library/Application Support/Moodboard/`.

| Path | Contents |
| --- | --- |
| `board.json` | The columns and the pictures on the wall. |
| `state.json` | Where the wall was when it last came to rest. |
| `dials/` | One file of tuned values per component. |
| `notes.json` | Your notes, what was built and from what, and tunes an update could not keep. |
| `components/` | The designs imported from Paper. |
| `materials/` | The app's copies of pictures and films. |
| `plates/` | Cached stills of each component. The app can rebuild these. |
| `projects.json` | The connected Next.js projects and the components found in each. |
| `vite/` | The project servers' cache. The app can rebuild it. |
| `welcomed` | Marks that the welcome sheet was seen. Delete it to see the sheet on the next launch. |
| `mcp.sock` | The private socket between `Moodboard --mcp` and the wall. |

To remove Moodboard, delete the app and that folder, and run `claude mcp remove moodboard -s user` if you added it to Claude Code.

## Work on the code

| Path | Contents |
| --- | --- |
| `native/Moodboard/App/` | Startup, the menus, and the welcome sheet. |
| `native/Moodboard/Board/` | The board, the Wall and Grid layouts, the project filter, and each component's status. |
| `native/Moodboard/Canvas/` | The canvas behind the Wall and Grid, tile formation, plates, and live stages. |
| `native/Moodboard/Focus/` | The open tile, the inspector, and the List view. |
| `native/Moodboard/Paper/` | The Paper client, the importer, the import popover, and the watch for changed frames. |
| `native/Moodboard/MCP/` | The stdio server, the tools, and **Send**. |
| `native/Moodboard/Projects/` | Connected projects, their servers, measuring new components, and turning dial moves into writes. |
| `sync/` | The project server: finding components, sample props, reading and writing literals, and the shims that let Next.js code run under Vite. `tools/build-sync.mjs` bundles it into `dist-sync/`. |
| `src/paper/` | Turns Paper JSX into a running component and writes the brief. |
| `src/stage/` | The page that runs one component and plays its loop. |
| `src/demos/` | Hand-written components bundled into the app. The public build has none. |
| `demo/` | Greenhouse, the demo project. `tools/build-demo.mjs` copies it and the packages it needs into `dist-demo/`, and the app bundles that. |
| `docs/` | The website, served by GitHub Pages. The demo film is in `docs/media/`. |
| `tools/video/` | The recorder, the editor, and the script that records the demo film. |

After you change anything under `src/`, `sync/`, or `demo/`, run `npm run build` and build the app again. After you add a Swift file, run `xcodegen generate --spec native/project.yml`.

A Debug build keeps its data in `~/Library/Application Support/Moodboard Debug`, so it never touches the installed app's data. It also answers `debug.*` calls on the socket, which is how the scroll numbers were measured and how the demo film is recorded. A Release build refuses them.

### Record the demo film

`tools/video/make.sh` records the Greenhouse demo with a Debug build and writes the film the website plays to `docs/media/`. `tools/video/make.sh --recut` cuts the last take again after you change the edit. [`tools/video/README.md`](tools/video/README.md) explains both, and how to record another app with the same tools.

### Check your work

Run these commands in the project root.

```bash
npm run typecheck
```

```bash
npm test
```

```bash
xcodebuild test -project native/Moodboard.xcodeproj -scheme Moodboard -derivedDataPath native/build -destination 'platform=macOS'
```

### Add a hand-written component

A hand-written component bundles into the app instead of coming from a connected project. Use one when a component needs a scripted demo or CSS dials that don't exist in its source.

1. Write the demo in `src/demos/<project>/`.
2. Add its dials to `src/demos/<project>/dials.ts`.
3. Export an array of rows from `src/demos/<project>/index.ts`. Each row needs an `id`, `title`, `project`, `viewport`, `ground`, `cursor`, `script`, `dials`, and `load`. `src/demos/types.ts` describes each field. The tile appears on the wall by itself.

A dial is a DialKit control plus the CSS it writes:

```ts
export const switchDials = dials(
  { Size: { width: [44, 32, 72, 1] } },
  ({ Size }) => `.switch { width: ${Size.width}px; }`,
);
```

That CSS goes in a stylesheet after the component's own, so a dial retunes the real component without editing it. A dial can feed a prop instead. Read it with `useTuned<typeof switchDials>()` inside the demo.

Set each dial's default to the component's real value. A dial that neither changes the CSS nor appears in the demo's source fails `npm test`.

## Known limits

- The prebuilt app is for Apple silicon and is signed only ad hoc. Build from source on an Intel Mac.
- Paper must be open to import, update, or notice a change. With Paper closed, no component reads **Paper changed**.
- Image assets and fonts from Paper load online. A still made offline keeps an empty cover until the tune changes. Delete `plates/` to make them all again.
- At most 12 tiles run live at once. Past that, for example when you zoom far out, tiles show their stills. Each live tile is a web process of about 40 MB, so the Wall uses about 1 GB with a project connected. Grid and List keep only the tile in use and two spares, and use about half that.
- Animation stops while the window is hidden, minimised, or on another Space, and resumes when you can see it.

## The earlier browser wall

`index.html` and `src/board/` hold the browser version that came before the app. The app does not use them. `npm run dev` serves that version at <http://localhost:5199>.

## License

MIT. See [LICENSE](LICENSE).
