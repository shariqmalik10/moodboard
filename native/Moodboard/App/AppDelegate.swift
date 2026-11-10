import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow?
  private var host = WebHost()
  private var server: SocketServer?
  private(set) var model: AppModel?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1440, height: 920),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Moodboard"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 940, height: 560)
    window.collectionBehavior = [.fullScreenPrimary]
    window.backgroundColor = Palette.wall
    if !window.setFrameUsingName("Moodboard") { window.center() }
    window.setFrameAutosaveName("Moodboard")
    self.window = window

    let root = RootView(frame: window.contentLayoutRect)
    window.contentView = root
    NSApp.mainMenu = MainMenu.build()
    window.makeKeyAndOrderFront(nil)
    // Claude Code opens the wall behind what the person is doing, and tools/video does the same for a take.
    let inBackground = ["MoodboardInBackground", "MoodboardRecording"].contains { UserDefaults.standard.bool(forKey: $0) }
    if !inBackground { NSApp.activate() }

    let model = AppModel(host: host, root: root, window: window)
    self.model = model
    Task { await model.start() }

    let server = SocketServer { [weak model] method, params in
      guard let model else { throw ToolError("The app is still starting.") }
      return try await model.tools.handle(method: method, params: params)
    }
    server.start()
    self.server = server
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { window?.makeKeyAndOrderFront(nil) }
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    server?.stop()
    model?.handoffs.stopAll()
    model?.projects.stopAll()
    model?.saveState()
  }
}

/// The window's layers, back to front. The backstage sits behind the opaque wall, where web views can
/// load and paint without being seen.
final class RootView: NSView {
  let backstage = NSView()
  var onCancel: (() -> Void)?
  var onResize: (() -> Void)?

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    onResize?()
  }

  override func cancelOperation(_ sender: Any?) { onCancel?() }

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    autoresizesSubviews = true
    backstage.frame = bounds
    backstage.wantsLayer = true
    backstage.autoresizesSubviews = false
    addSubview(backstage)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }
}

/// The app's parts, created once the web runtime has reported which components exist.
final class AppModel {
  let host: WebHost
  let root: RootView
  let window: NSWindow
  private(set) var runtime: Runtime
  private(set) var store: BoardStore?
  private(set) var plates: PlateStore?
  private(set) var pool: LivePool
  private(set) var canvas: CanvasView?
  private(set) var focus: FocusController?
  private(set) var chrome: ChromeController?
  private(set) var importer: Importer?
  private(set) var list: ListController?
  private(set) lazy var statuses = StatusStore(runtime: runtime)
  private var watch: PaperWatch?
  var paperWatch: PaperWatch? { watch }
  /// The row in hand stays even after it leaves a status, so that status isn't empty yet.
  var isTuningInList: Bool { list?.isActive == true && list?.selectedId != nil }
  private(set) lazy var tools = Tools(model: self)
  private(set) lazy var handoffs = Handoffs(app: self)
  private(set) lazy var projects = ProjectSync(app: self)
  private(set) lazy var connector = ProjectConnector(app: self)
  private(set) lazy var dials = Dials(app: self)
  private(set) lazy var welcome = WelcomeController(app: self)

  init(host: WebHost, root: RootView, window: NSWindow) {
    self.host = host
    self.root = root
    self.window = window
    runtime = Runtime(host: host, backstage: root.backstage)
    pool = LivePool(host: host, backstage: root.backstage)
    host.bridge.onMessage = { [weak self] web, message in self?.receive(web, message) }
    host.scheme.projectRecord = { [weak self] id in await self?.dials.record(id) }
  }

  func start() async {
    await runtime.start()
    do {
      let catalog = try await runtime.catalog()
      let store = BoardStore(catalog: catalog)
      self.store = store
      let plates = PlateStore(host: host, backstage: root.backstage) { [weak store] id in store?.items[id] }
      self.plates = plates
      let canvas = CanvasView(store: store, plates: plates, pool: pool, camera: loadCamera())
      canvas.frame = root.bounds
      canvas.autoresizingMask = [.width, .height]
      root.addSubview(canvas)
      self.canvas = canvas
      canvas.viewDidChangeEffectiveAppearance()
      window.makeFirstResponder(canvas)
      store.onChange = { [weak self] in self?.boardChanged() }
      importer = Importer(model: self)
      let focus = FocusController(model: self, root: root)
      self.focus = focus
      root.onCancel = { [weak focus] in focus?.close() }
      root.onResize = { [weak self] in
        self?.focus?.windowResized()
        self?.list?.relayout()
        self?.chrome?.windowResized()
      }
      canvas.onOpen = { [weak focus] tile in focus?.open(tile) }
      canvas.onSettle = { [weak self] in self?.saveState() }
      canvas.onFrame = { [weak focus] dt in focus?.step(dt) ?? false }
      canvas.onDropFiles = { [weak self] urls, point in self?.addMaterials(urls, at: point) }
      canvas.statusOf = { [statuses] id in statuses.status(id) }
      canvas.onPlate = { [weak self] _ in self?.list?.refresh() }
      statuses.onChange = { [weak self] _ in self?.statusesChanged() }
      let chrome = ChromeController(model: self, root: root)
      self.chrome = chrome
      list = ListController(model: self, root: root, above: canvas)
      boardChanged()
      await statuses.loadTunes(ids: Array(store.items.keys))
      watch = PaperWatch(model: self)
      projects.startAll()
      welcome.showIfFirstLaunch()
      for id in store.visibleIds where store.items[id]?.isComponent == true { plates.request(id) }
    } catch {
      showFailure(error.localizedDescription)
    }
  }

  private func boardChanged() {
    canvas?.boardChanged()
    list?.refresh()
    chrome?.boardChanged()
    // The last thing in the chosen project went away, so there's nothing left to choose.
    if let chrome, case .project(let project) = chrome.state.view.filter, !chrome.state.projects.contains(project) {
      show(filter: .all)
    }
  }

  private func statusesChanged() {
    canvas?.statusesChanged()
    list?.refresh()
    chrome?.boardChanged()
    focus?.syncInspector()
  }

  /// Narrows Grid and List. The Wall keeps showing everything.
  func refine(_ next: Refinement) {
    guard var view = chrome?.state.view else { return }
    view.refinement = next
    apply(view)
  }

  /// Takes the keyboard to the search field. The Wall has no search, so this moves to Grid.
  func startSearch() {
    if chrome?.state.view.mode == .wall { show(.grid) }
    chrome?.state.searchFocus += 1
  }

  /// Return in the search field: use the first thing it found.
  func useFirstResult() {
    if chrome?.state.view.mode == .list {
      list?.focusRows()
    } else if let tile = canvas?.firstCard {
      focus?.open(tile)
    }
  }

  /// Switches the view, the project, or both. An open tile flies home first.
  func show(_ mode: ViewMode? = nil, filter: ProjectFilter? = nil) {
    guard let canvas, let focus, var view = chrome?.state.view else { return }
    if let mode { view.mode = mode }
    if let filter { view.filter = filter }
    if focus.tile != nil {
      Task {
        await focus.closeAndWait()
        show(view.mode, filter: view.filter)
      }
      return
    }
    apply(view)
    if view.mode != .list { window.makeFirstResponder(canvas) }
  }

  /// Hands the canvas, the list and the bar the same view state.
  private func apply(_ next: ViewState) {
    guard let chrome, let canvas, let list else { return }
    var next = next
    // List shows only components, so it has no Materials project.
    if next.mode == .list, next.filter == .project("material") { next.filter = .all }
    chrome.state.view = next
    canvas.apply(next)
    list.apply(next)
    chrome.boardChanged()
  }

  private func showFailure(_ message: String) {
    let alert = NSAlert()
    alert.messageText = "Moodboard couldn't start"
    alert.informativeText = message
    alert.runModal()
  }

  private func receive(_ web: WKWebView?, _ message: PageMessage) {
    if case .runtimeReady = message {
      runtime.markReady()
      return
    }
    switch message {
    case .dials(let id, let state, let byPerson):
      focus?.tuned(id: id, state: state, byPerson: byPerson)
    case .escape:
      focus?.close()
    case .ready:
      pool.stage(of: web)?.markReady()
      canvas?.wake()
    case .failed(_, let reason):
      pool.stage(of: web)?.markFailed(reason)
    case .runtimeReady, .measured, .driving:
      break
    }
  }

  // MARK: Adding to the wall

  /// A dropped folder is a project to connect. Anything else is a picture or a film for the wall.
  func addMaterials(_ urls: [URL], at point: CGPoint?) {
    let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    folders.forEach(connector.connectAsked)
    Task {
      for url in urls where !folders.contains(url) {
        do {
          let (id, material) = try await MaterialStore.add(url)
          place(id, material: material, at: point)
        } catch {
          chrome?.say(error.localizedDescription)
        }
      }
    }
  }

  func place(_ id: String, material: Material? = nil, at point: CGPoint? = nil) {
    guard let store, let canvas else { return }
    // Something new arrives on the wall, where it can be seen coming together.
    show(.wall, filter: .all)
    let slot = canvas.slotNearCenter(point)
    canvas.welcome(id) { store.insert(id: id, material: material, column: slot.column, index: slot.index) }
    plates?.request(id, first: true)
    if let home = canvas.homeRect(for: id) { canvas.bringIntoView(home) }
  }

  private var savedCamera: Camera?

  private func loadCamera() -> Camera {
    guard let data = try? Data(contentsOf: Paths.state), let state = try? JSONSerialization.jsonObject(with: data) as? JSON else {
      return Camera(x: 60, y: 60, z: 1)
    }
    return Camera(x: state["x"] as? Double ?? 60, y: state["y"] as? Double ?? 60, z: state["z"] as? Double ?? 1)
  }

  func saveState() {
    guard let camera = canvas?.wallPosition, camera != savedCamera else { return }
    savedCamera = camera
    let state: JSON = ["x": camera.x, "y": camera.y, "z": camera.z]
    if let data = try? JSONSerialization.data(withJSONObject: state) { try? data.write(to: Paths.state, options: .atomic) }
  }
}
