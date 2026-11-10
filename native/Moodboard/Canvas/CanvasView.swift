import AppKit
import QuartzCore

struct Camera: Equatable {
  var x: Double
  var y: Double
  var z: Double
}

/// Moves as one piece, so scrolling costs a single layer change however many tiles are on the wall.
private final class WorldView: NSView {
  override var isFlipped: Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The endless wall: the camera, the input that moves it, and which tiles exist and run at any moment.
final class CanvasView: NSView {
  private let store: BoardStore
  private let plates: PlateStore
  private let pool: LivePool
  private let world = WorldView()

  private(set) var camera: Camera
  private var target: Camera
  private var fling: CGVector = .zero
  private var flight: (x: Spring, y: Spring, z: Spring)?
  private var isWheel = false
  private var mounted: [Instance.Key: TileView] = [:]
  private var spare: [TileView] = []
  private var link: CADisplayLink?
  private var lastTick: CFTimeInterval = 0
  private var lastStepped = (x: 0.0, y: 0.0)
  private var drag: (start: NSPoint, last: NSPoint, lastTime: TimeInterval, moved: Bool, pressed: Instance.Key?)?
  private var hovered: Instance.Key?
  private var busyTiles = false
  private var scriptedWheel: (dy: Double, dx: Double, left: Int)?

  var stats = FrameStats()
  private var keyboardKey: Instance.Key?
  private var arrangement: any Arrangement
  private var view = ViewState()
  var mode: ViewMode { view.mode }
  var density = GridLayout.Density(rawValue: UserDefaults.standard.integer(forKey: "gridDensity") + 1) ?? .medium {
    didSet { UserDefaults.standard.set(density.rawValue - 1, forKey: "gridDensity") }
  }
  /// Where each component stands in the loop, for the views that show it.
  var statusOf: (String) -> ComponentStatus = { _ in ComponentStatus() }
  private var wallCamera: Camera
  private var headingLabels: [NSTextField] = []
  private let emptyLabel = NSTextField(labelWithString: "")
  private var isArriving = false
  private var hoverCamera: Camera?
  /// The wall has come to rest.
  var onSettle: (() -> Void)?
  var onOpen: ((TileView) -> Void)?
  var onFrame: ((Double) -> Bool)?
  var onDropFiles: (([URL], CGPoint?) -> Void)?
  var onPlate: ((String) -> Void)?
  var isLocked = false
  private var newborn: String?

  private static let minZoom = 0.4
  private static let maxZoom = 1.6
  private static let dragSlop = 4.0
  private static let warmAbove = 0.55
  private static let releaseBelow = 0.25

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  init(store: BoardStore, plates: PlateStore, pool: LivePool, camera: Camera) {
    self.store = store
    self.plates = plates
    self.pool = pool
    self.camera = camera
    target = camera
    wallCamera = camera
    arrangement = store.layout
    super.init(frame: .zero)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    world.wantsLayer = true
    world.layerContentsRedrawPolicy = .never
    world.autoresizesSubviews = false
    addSubview(world)
    emptyLabel.font = .systemFont(ofSize: 13)
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.isHidden = true
    addSubview(emptyLabel)
    registerForDraggedTypes([.fileURL])
    plates.onPlate = { [weak self] id, plate in
      self?.mounted.values.filter { $0.item?.id == id }.forEach {
        $0.use(plate)
        $0.form($0.coverage)
      }
      self?.onPlate?(id)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

  // MARK: Dropping and pasting

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    guard !urls.isEmpty else { return false }
    onDropFiles?(urls, convert(sender.draggingLocation, from: nil))
    return true
  }

  @objc func paste(_ sender: Any?) {
    let board = NSPasteboard.general
    if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
      onDropFiles?(urls, nil)
      return
    }
    guard let image = NSImage(pasteboard: board), let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { return }
    let file = FileManager.default.temporaryDirectory.appending(path: "Pasted \(UUID().uuidString.prefix(6)).png")
    if (try? png.write(to: file)) != nil { onDropFiles?([file], nil) }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, link == nil else { return }
    let link = displayLink(target: self, selector: #selector(tick(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    link.add(to: .main, forMode: .common)
    self.link = link
    wake()
  }

  override func layout() {
    super.layout()
    world.frame = bounds
    if mode == .grid {
      arrangement = makeArrangement()
      placeHeadings()
      placeTiles(force: true)
    }
    busyTiles = true
    wake()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = Palette.wall.cgColor
    }
    statusesChanged()
  }

  func wake() {
    link?.isPaused = false
  }

  func boardChanged() {
    arrangement = makeArrangement()
    placeHeadings()
    let current = Set(arrangement.cards(in: viewRect(margin: 300)).map(\.key))
    for (key, tile) in mounted where !current.contains(key) && !tile.isRaised {
      unmount(key, tile)
    }
    placeTiles(force: true)
    wake()
  }

  // MARK: Views and filters

  private func makeArrangement() -> any Arrangement {
    let height = { [store] (id: String) in store.items[id]?.height ?? 0 }
    switch mode {
    case .wall: return Layout(columns: store.columns(for: view.filter), heightOf: height)
    case .grid:
      let sections = store.sections(for: view.filter) { [refinement = view.refinement, statusOf] item in refinement.matches(item, statusOf(item.id)) }
      return GridLayout(sections: sections, width: bounds.width, density: density, heightOf: height)
    case .list: return Layout(columns: [], heightOf: height)
    }
  }

  /// Changes what's on the canvas. Another view or project assembles again on a clock, the nearest tiles first.
  /// Another search or status narrows Grid: cards keep what they have, and the view goes back to the top.
  func apply(_ next: ViewState) {
    let before = view
    guard next != before else { return }
    view = next
    guard next.mode == before.mode, next.filter == before.filter else { return rearrange(from: before.mode) }
    guard mode == .grid else { return }
    setCamera(Camera(x: 0, y: 0, z: 1))
    boardChanged()
  }

  private func rearrange(from previous: ViewMode) {
    if previous == .wall { wallCamera = camera }
    let modeChanged = previous != mode
    clearKeyboardFocus()
    for (key, tile) in mounted { unmount(key, tile) }
    arrangement = makeArrangement()
    placeHeadings()
    if modeChanged || mode == .grid { setCamera(mode == .wall ? wallCamera : Camera(x: 0, y: 0, z: 1)) }
    world.bounds = CGRect(x: -camera.x / camera.z, y: -camera.y / camera.z, width: bounds.width / camera.z, height: bounds.height / camera.z)
    hoverCamera = nil
    isArriving = true
    placeTiles(force: true)
    isArriving = false
    busyTiles = true
    wake()
  }

  /// A card's place in the loop moved, or a card joined or left what's being shown.
  func statusesChanged() {
    guard mode == .grid else { return }
    boardChanged()
  }

  func changeDensity(by step: Int) {
    guard mode == .grid, let next = GridLayout.Density(rawValue: density.rawValue + step) else { return }
    density = next
    let top = arrangement.scrollLimits(viewHeight: bounds.height)?.lowerBound ?? 0
    let share = top < 0 ? camera.y / top : 0
    boardChanged()
    let nextTop = arrangement.scrollLimits(viewHeight: bounds.height)?.lowerBound ?? 0
    setCamera(Camera(x: 0, y: nextTop * share, z: 1))
  }

  /// The first card showing, for the Return key in the search field.
  var firstCard: TileView? {
    arrangement.cards(in: viewRect(margin: 0)).first.flatMap { mounted[$0.key] }
  }

  /// Where the wall stands, even while another view is showing.
  var wallPosition: Camera { mode == .wall ? camera : wallCamera }

  private func placeHeadings() {
    headingLabels.forEach { $0.removeFromSuperview() }
    headingLabels = arrangement.headings.map { heading in
      let text = NSMutableAttributedString(string: heading.title, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor])
      text.append(NSAttributedString(string: "  \(heading.count)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]))
      let label = NSTextField(labelWithAttributedString: text)
      label.frame = CGRect(x: heading.x + 2, y: heading.y, width: 400, height: 22)
      world.addSubview(label)
      return label
    }
    let isEmpty = mode == .grid && arrangement.headings.isEmpty
    emptyLabel.isHidden = !isEmpty
    if isEmpty {
      emptyLabel.stringValue = view.refinement.isActive ? "Nothing here matches. Try another search or status." : "Nothing here yet."
      emptyLabel.sizeToFit()
      emptyLabel.frame.origin = CGPoint(x: (bounds.width - emptyLabel.frame.width) / 2, y: max(GridLayout.top + 40, (bounds.height - emptyLabel.frame.height) / 2))
    }
  }

  // MARK: Coordinates

  private func worldRect(of rect: CGRect) -> CGRect {
    CGRect(x: (rect.minX - camera.x) / camera.z, y: (rect.minY - camera.y) / camera.z, width: rect.width / camera.z, height: rect.height / camera.z)
  }

  private func viewRect(margin: Double) -> CGRect {
    worldRect(of: bounds.insetBy(dx: -margin, dy: -margin))
  }

  func screenRect(of world: CGRect) -> CGRect {
    CGRect(x: world.minX * camera.z + camera.x, y: world.minY * camera.z + camera.y, width: world.width * camera.z, height: world.height * camera.z)
  }

  private func tile(at point: NSPoint) -> TileView? {
    let spot = CGPoint(x: (point.x - camera.x) / camera.z, y: (point.y - camera.y) / camera.z)
    return mounted.values.first { !$0.isRaised && $0.pointerRect.contains(spot) }
  }

  // MARK: The frame

  @objc private func tick(_ link: CADisplayLink) {
    let began = CACurrentMediaTime()
    let dt = lastTick == 0 ? 1.0 / 120 : min(1.0 / 20, link.timestamp - lastTick)
    let interval = link.timestamp - lastTick
    lastTick = link.timestamp

    if let scripted = scriptedWheel { replay(scripted) }
    let before = camera
    step(dt)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if before != camera || busyTiles { apply() }
    var tilesMoving = updateLive(dt)
    if let onFrame, onFrame(dt) { tilesMoving = true }
    CATransaction.commit()

    let moved = before != camera
    let distance = ((camera.x - before.x) * (camera.x - before.x) + (camera.y - before.y) * (camera.y - before.y)).squareRoot()
    if stats.isRecording { stats.record(interval: interval, cost: CACurrentMediaTime() - began, step: distance) }

    busyTiles = tilesMoving
    if !moved, !tilesMoving, target == camera, flight == nil, fling == .zero, !stats.isRecording {
      link.isPaused = true
      lastTick = 0
      onSettle?()
    }
  }

  private func step(_ dt: Double) {
    if var going = flight {
      going.x.step(dt)
      going.y.step(dt)
      going.z.step(dt)
      target = Camera(x: going.x.value, y: going.y.value, z: going.z.value)
      camera = target
      flight = going.x.isSettled && going.y.isSettled && going.z.isSettled ? nil : going
      return
    }
    if fling != .zero {
      target.x += fling.dx * dt
      target.y += fling.dy * dt
      let decay = pow(0.998, dt * 1000)
      fling = CGVector(dx: fling.dx * decay, dy: fling.dy * decay)
      if abs(fling.dx) < 4, abs(fling.dy) < 4 { fling = .zero }
    }
    if let limits = arrangement.scrollLimits(viewHeight: bounds.height) {
      target.x = 0
      // Past an end the view gives a little and comes back. The further past, the harder it pulls.
      let nearest = min(limits.upperBound, max(limits.lowerBound, target.y))
      let over = nearest - target.y
      target.y = abs(over) < 0.25 ? nearest : target.y + over * (1 - exp(-dt * (1 + abs(over) / 40) / 0.07))
    }
    // A trackpad's own events already carry the system's momentum, so they get only enough smoothing
    // to bridge the gaps between events and frames. A mouse wheel jumps in big steps and gets more.
    let tau = isWheel ? 0.07 : 0.011
    let share = 1 - exp(-dt / tau)
    camera.x += (target.x - camera.x) * share
    camera.y += (target.y - camera.y) * share
    camera.z += (target.z - camera.z) * share
    if abs(target.x - camera.x) < 0.02, abs(target.y - camera.y) < 0.02, abs(target.z - camera.z) < 0.0002 { camera = target }
  }

  /// Writes the camera to the one world layer and refreshes the tiles' forming.
  private func apply() {
    let size = bounds.size
    world.bounds = CGRect(x: -camera.x / camera.z, y: -camera.y / camera.z, width: size.width / camera.z, height: size.height / camera.z)
    placeTiles(force: false)
    // The tile under a still pointer changes when the view moves, and no mouse event says so.
    if arrangement.runsOnHover, camera != hoverCamera, drag == nil, let window {
      hoverCamera = camera
      updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    let view = bounds
    for tile in mounted.values where !tile.isRaised {
      tile.form(Coverage(tile: screenRect(of: tile.home), view: view))
    }
  }

  private func placeTiles(force: Bool) {
    let wanted = arrangement.cards(in: viewRect(margin: 40))
    let keys = Set(wanted.map(\.key))
    for (key, tile) in mounted where !keys.contains(key) && !tile.isRaised {
      unmount(key, tile)
    }
    for instance in wanted {
      if let tile = mounted[instance.key] {
        if force {
          if tile.home != instance.rect {
            if instance.cell == nil { tile.slide(from: tile.home.minY, to: instance.rect.minY) }
            tile.place(home: instance.rect, scale: instance.scale)
          }
          if let item = store.items[instance.id] { tile.setCell(instance.cell, title: item.title, mark: mark(for: item)) }
        }
        continue
      }
      guard let item = store.items[instance.id] else { continue }
      if plates.plate(for: instance.id) == nil { plates.request(instance.id, first: true) }
      let tile = takeTile(for: instance.id)
      tile.home = instance.rect
      tile.homeScale = instance.scale
      tile.frame = instance.rect
      tile.configure(key: instance.key, item: item, plate: plates.plate(for: instance.id))
      tile.setCell(instance.cell, title: item.title, mark: mark(for: item))
      tile.isHidden = false
      if force, newborn == instance.id { tile.beginBirth() }
      if isArriving {
        let rect = screenRect(of: instance.rect)
        tile.beginBirth(response: 0.45 + 0.4 * min(1, hypot(rect.midX - bounds.midX, rect.midY - bounds.midY) / 900))
      }
      mounted[instance.key] = tile
    }
  }

  private func mark(for item: Item) -> NSAttributedString? {
    guard item.isComponent else { return nil }
    return ComponentStatus.attributed(statusOf(item.id), in: effectiveAppearance)
  }

  private func takeTile(for id: String) -> TileView {
    if let at = spare.firstIndex(where: { $0.item?.id == id }) { return spare.remove(at: at) }
    if let any = spare.popLast() { return any }
    let tile = TileView(frame: .zero)
    tile.onAccessibilityPress = { [weak self] tile in self?.onOpen?(tile) }
    world.addSubview(tile)
    return tile
  }

  private func unmount(_ key: Instance.Key, _ tile: TileView) {
    if let stage = tile.detach() { pool.release(stage) }
    mounted[key] = nil
    if hovered == key { hovered = nil }
    tile.isHidden = true
    tile.setHovered(false)
    tile.setPressed(false)
    spare.append(tile)
  }

  /// Hands the few running stages to the tiles that rank highest, and returns whether any tile
  /// still has a timed change in progress.
  private func updateLive(_ dt: Double) -> Bool {
    var moving = false
    let tiles = mounted.values
    var needing: [TileView] = []
    let onHover = arrangement.runsOnHover
    for tile in tiles {
      // An open tile has the person's attention, so the wall behind it holds still.
      if tile.advance(dt, quiet: isLocked && !tile.isRaised) { moving = true }
      guard let item = tile.item, item.isComponent, !tile.isRaised else { continue }
      if tile.stage != nil {
        let keeps = onHover ? tile.key == hovered : tile.coverage.p >= Self.releaseBelow
        if !keeps, let released = tile.detach() { pool.release(released) }
      } else if onHover ? tile.key == hovered : tile.coverage.p > Self.warmAbove {
        needing.append(tile)
      }
    }
    guard let next = needing.max(by: { $0.coverage.p < $1.coverage.p }) else { return moving }
    // A tile fully in view outranks one still arriving, so what you're looking at runs first.
    if !provideStage(for: next), next.coverage.p >= TileView.liveAt, let weakest = weakestStage(below: next.coverage.p) {
      if let released = weakest.detach() { pool.release(released) }
      _ = provideStage(for: next)
    }
    return true
  }

  private func provideStage(for tile: TileView) -> Bool {
    guard let id = tile.item?.id, let stage = pool.acquire(id, for: tile) else { return false }
    tile.attach(stage)
    return true
  }

  private func weakestStage(below p: Double) -> TileView? {
    mounted.values.filter { $0.stage != nil && !$0.isRaised && $0.coverage.p < p }.min { $0.coverage.p < $1.coverage.p }
  }

  // MARK: The focus view

  func tile(forItem id: String) -> TileView? {
    let view = bounds
    return mounted.values.filter { $0.item?.id == id && !$0.isRaised }.max {
      Coverage(tile: screenRect(of: $0.home), view: view).p < Coverage(tile: screenRect(of: $1.home), view: view).p
    }
  }

  /// A tile being opened gets a running stage at once, even if another has to give one up.
  func ensureStage(for tile: TileView) {
    guard tile.stage == nil, tile.item?.isComponent == true else { return }
    if provideStage(for: tile) { return }
    if let weakest = weakestStage(below: 2), let released = weakest.detach() { pool.release(released) }
    _ = provideStage(for: tile)
  }

  func bringIntoView(_ home: CGRect) {
    let rect = screenRect(of: home)
    guard Coverage(tile: rect, view: bounds).p < 1 else { return }
    var next = target
    next.x += bounds.midX - rect.midX
    next.y += bounds.midY - rect.midY
    if let limits = arrangement.scrollLimits(viewHeight: bounds.height) {
      next.x = 0
      next.y = min(limits.upperBound, max(limits.lowerBound, next.y))
    }
    fly(to: next)
  }

  /// Adds a card where it can be seen forming. The insert's own board change mounts the card, so the canvas has
  /// to know it's new before then.
  func welcome(_ id: String, arriving insert: () -> Void) {
    newborn = id
    defer { newborn = nil }
    insert()
  }

  /// The repeat of a card nearest the middle of the window.
  func homeRect(for id: String) -> CGRect? {
    let distance = { [self] (home: CGRect) -> Double in
      let rect = screenRect(of: home)
      return hypot(rect.midX - bounds.midX, rect.midY - bounds.midY)
    }
    return arrangement.cards(in: viewRect(margin: arrangement.span)).filter { $0.id == id }.map(\.rect).min { distance($0) < distance($1) }
  }

  var isFlying: Bool { flight != nil }

  func worldHost() -> NSView { world }

  /// Column and position for something new, close to the middle of what's on screen.
  func slotNearCenter(_ point: CGPoint? = nil) -> (column: Int, index: Int) {
    let spot = point ?? CGPoint(x: bounds.midX, y: bounds.midY)
    let wall = wallPosition
    return store.layout.slot(atX: (spot.x - wall.x) / wall.z, y: (spot.y - wall.y) / wall.z)
  }

  // MARK: Input

  override func scrollWheel(with event: NSEvent) {
    guard !isLocked else { return }
    clearKeyboardFocus()
    if arrangement.isEndless, event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
      let point = convert(event.locationInWindow, from: nil)
      zoom(at: point, factor: exp(event.scrollingDeltaY * 0.006))
      return
    }
    flight = nil
    fling = .zero
    isWheel = !event.hasPreciseScrollingDeltas
    let scale = isWheel ? 14.0 : 1.0
    target.x += event.scrollingDeltaX * scale
    target.y += event.scrollingDeltaY * scale
    wake()
  }

  override func magnify(with event: NSEvent) {
    guard !isLocked else { return }
    zoom(at: convert(event.locationInWindow, from: nil), factor: 1 + event.magnification)
  }

  func zoom(at point: CGPoint, factor: Double) {
    guard arrangement.isEndless else { return }
    flight = nil
    let z = min(Self.maxZoom, max(Self.minZoom, target.z * factor))
    let k = z / target.z
    target = Camera(x: point.x - (point.x - target.x) * k, y: point.y - (point.y - target.y) * k, z: z)
    isWheel = false
    wake()
  }

  func zoomFromCenter(factor: Double) {
    zoom(at: CGPoint(x: bounds.midX, y: bounds.midY), factor: factor)
  }

  /// Glides somewhere with a spring that starts from wherever the camera is now.
  func fly(to next: Camera, response: Double = 0.55) {
    fling = .zero
    var x = Spring(camera.x, response: response)
    var y = Spring(camera.y, response: response)
    var z = Spring(camera.z, response: response)
    x.target = next.x
    y.target = next.y
    z.target = next.z
    if let going = flight {
      x.velocity = going.x.velocity
      y.velocity = going.y.velocity
      z.velocity = going.z.velocity
    }
    flight = (x, y, z)
    wake()
  }

  func goHome() {
    fly(to: arrangement.isEndless ? Camera(x: 60, y: 60, z: 1) : Camera(x: 0, y: 0, z: 1))
  }

  /// Tab walks the tiles on screen in reading order, and scrolls to one that isn't fully in view.
  private func moveKeyboardFocus(by step: Int) {
    let view = bounds
    let tiles = mounted.values
      .filter { !$0.isRaised && Coverage(tile: screenRect(of: $0.home), view: view).p > 0.25 }
      .sorted { mode == .grid ? ($0.pointerRect.minY, $0.pointerRect.minX) < ($1.pointerRect.minY, $1.pointerRect.minX) : ($0.home.minX, $0.home.minY) < ($1.home.minX, $1.home.minY) }
    guard !tiles.isEmpty else { return }
    let current = tiles.firstIndex { $0.key == keyboardKey }
    let next = current.map { ($0 + step + tiles.count) % tiles.count } ?? (step > 0 ? 0 : tiles.count - 1)
    keyboardTile?.isKeyboardFocused = false
    let tile = tiles[next]
    keyboardKey = tile.key
    tile.isKeyboardFocused = true
    bringIntoView(tile.home)
  }

  private var keyboardTile: TileView? { keyboardKey.flatMap { mounted[$0] } }

  private func clearKeyboardFocus() {
    keyboardTile?.isKeyboardFocused = false
    keyboardKey = nil
  }

  private func openKeyboardTile() {
    if let tile = keyboardTile { onOpen?(tile) }
  }

  func panBy(dx: Double, dy: Double) {
    flight = nil
    isWheel = true
    target.x += dx
    target.y += dy
    wake()
  }

  override func mouseDown(with event: NSEvent) {
    clearKeyboardFocus()
    guard !isLocked else { return }
    window?.makeFirstResponder(self)
    flight = nil
    fling = .zero
    target = camera
    let point = convert(event.locationInWindow, from: nil)
    let pressed = tile(at: point)
    pressed?.setPressed(true)
    busyTiles = true
    drag = (point, point, event.timestamp, false, pressed?.key)
    wake()
  }

  override func mouseDragged(with event: NSEvent) {
    guard var going = drag else { return }
    let point = convert(event.locationInWindow, from: nil)
    if !going.moved, hypot(point.x - going.start.x, point.y - going.start.y) > Self.dragSlop {
      going.moved = true
      if let key = going.pressed { mounted[key]?.setPressed(false) }
      NSCursor.closedHand.push()
    }
    if going.moved {
      let dt = max(event.timestamp - going.lastTime, 0.001)
      let (dx, dy) = (point.x - going.last.x, point.y - going.last.y)
      isWheel = false
      target.x += dx
      target.y += dy
      fling = CGVector(dx: fling.dx * 0.6 + dx / dt * 0.4, dy: fling.dy * 0.6 + dy / dt * 0.4)
    }
    going.last = point
    going.lastTime = event.timestamp
    drag = going
    wake()
  }

  override func mouseUp(with event: NSEvent) {
    guard let going = drag else { return }
    drag = nil
    if let key = going.pressed { mounted[key]?.setPressed(false) }
    busyTiles = true
    if going.moved {
      NSCursor.pop()
      if event.timestamp - going.lastTime > 0.08 { fling = .zero }
      wake()
      return
    }
    fling = .zero
    wake()
    if let key = going.pressed, let tile = mounted[key] { onOpen?(tile) }
  }

  override func mouseMoved(with event: NSEvent) {
    guard !isLocked else { return }
    updateHover(at: convert(event.locationInWindow, from: nil))
  }

  private func updateHover(at point: CGPoint) {
    let next = tile(at: point)?.key
    guard next != hovered else { return }
    if let hovered { mounted[hovered]?.setHovered(false) }
    if let next { mounted[next]?.setHovered(true) }
    hovered = next
    busyTiles = true
    wake()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
  }

  override func keyDown(with event: NSEvent) {
    switch event.charactersIgnoringModifiers {
    case "+", "=": mode == .grid ? changeDensity(by: 1) : zoomFromCenter(factor: 1.2)
    case "-": mode == .grid ? changeDensity(by: -1) : zoomFromCenter(factor: 1 / 1.2)
    case "0": goHome()
    case " ": openKeyboardTile()
    default:
      switch event.specialKey {
      case .tab?: moveKeyboardFocus(by: 1)
      case .backTab?: moveKeyboardFocus(by: -1)
      case .carriageReturn?, .enter?: openKeyboardTile()
      case .upArrow?: panBy(dx: 0, dy: 160)
      case .downArrow?: panBy(dx: 0, dy: -160)
      case .leftArrow?: panBy(dx: 160, dy: 0)
      case .rightArrow?: panBy(dx: -160, dy: 0)
      default: super.keyDown(with: event)
      }
    }
  }

  // MARK: Driving it from a script

  /// Plays a scroll through the real wheel handler, one event per frame, so measuring exercises the
  /// same path as a person's trackpad.
  func playScroll(dy: Double, dx: Double, frames: Int) {
    scriptedWheel = (dy, dx, frames)
    wake()
  }

  private func replay(_ scripted: (dy: Double, dx: Double, left: Int)) {
    guard scripted.left > 0 else {
      scriptedWheel = nil
      return
    }
    if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(scripted.dy), wheel2: Int32(scripted.dx), wheel3: 0) {
      event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
      if let wheel = NSEvent(cgEvent: event) { scrollWheel(with: wheel) }
    }
    scriptedWheel = (scripted.dy, scripted.dx, scripted.left - 1)
  }

  func setCamera(_ next: Camera) {
    flight = nil
    fling = .zero
    camera = next
    target = next
    busyTiles = true
    wake()
  }

  func debugState() -> JSON {
    var tiles: [JSON] = []
    let height = window?.frame.height ?? 0
    for (key, tile) in mounted {
      let rect = tile.convert(tile.bounds, to: nil)
      tiles.append([
        "frame": ["x": rect.minX, "y": height - rect.maxY, "w": rect.width, "h": rect.height] as JSON,
        "id": key.id, "p": tile.coverage.p, "stage": tile.stage != nil,
        "ready": tile.stage?.phase == .ready, "phase": tile.stage.map { String(describing: $0.phase) } ?? "", "plateFailure": tile.item.flatMap { plates.failure(for: $0.id) } ?? "", "running": tile.stage?.isRunning ?? false, "plate": tile.plate != nil,
        "pieces": tile.plate?.pieces.count ?? 0,
      ])
    }
    return [
      "camera": ["x": camera.x, "y": camera.y, "z": camera.z], "mounted": mounted.count, "spare": spare.count, "liveStages": pool.count,
      "attached": pool.liveCount, "running": pool.runningCount, "platesBaked": plates.bakedCount, "platesPending": plates.pending, "tiles": tiles,
      "paused": link?.isPaused ?? true,
      "keyboard": keyboardTile?.item?.id ?? NSNull(),
      "mode": mode.rawValue, "hovered": hovered?.id ?? NSNull(), "headings": arrangement.headings.map(\.title), "span": arrangement.span,
      "homes": mounted.values.map { ["id": $0.item?.id ?? "", "x": $0.home.minX, "y": $0.home.minY, "w": $0.home.width, "h": $0.home.height] as JSON },
    ]
  }
}

extension ComponentStatus {
  /// The words under a card in Grid: its one mark, then whether it has a note.
  static func attributed(_ status: ComponentStatus, in appearance: NSAppearance) -> NSAttributedString? {
    let font = NSFont.systemFont(ofSize: 11, weight: .medium)
    // A text layer doesn't draw in the view's appearance, so it needs the colour already worked out.
    let fixed = { (color: NSColor) -> NSColor in
      var resolved = color
      appearance.performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: color.cgColor) ?? color }
      return resolved
    }
    let text = NSMutableAttributedString()
    if status.hasNote {
      text.append(NSAttributedString(string: status.mark == nil ? "Note" : "Note  ", attributes: [.font: font, .foregroundColor: fixed(.secondaryLabelColor)]))
    }
    if let mark = status.mark {
      text.append(NSAttributedString(string: mark.label, attributes: [.font: font, .foregroundColor: fixed(mark.tone.color)]))
    }
    return text.length == 0 ? nil : text
  }
}

extension ComponentStatus.Tone {
  var color: NSColor {
    switch self {
    case .attention: .systemOrange
    case .accent: .controlAccentColor
    case .done: .systemGreen
    }
  }
}

enum Palette {
  static let wall = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.075, green: 0.082, blue: 0.09, alpha: 1)
      : NSColor(srgbRed: 0.957, green: 0.961, blue: 0.945, alpha: 1)
  }
}
