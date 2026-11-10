import AppKit
import SwiftUI
import WebKit

/// Opens a tile: it leaves the wall and flies to the middle of the window, with the wall dimmed behind
/// it and the dials beside it. Springs drive the whole move, so it can reverse at any moment.
final class FocusController {
  private unowned let model: AppModel
  private let host = PassthroughView()
  private let scrim = ScrimView()
  private lazy var controls = NSHostingView(rootView: StageControls(model: inspector.model))
  private var optionMonitor: Any?
  let inspector: InspectorView

  private(set) var tile: TileView?
  private var isClosing = false
  private var x = Spring(0, response: 0.46, damping: 0.92)
  private var y = Spring(0, response: 0.46, damping: 0.92)
  private var scale = Spring(1, response: 0.46, damping: 0.92)
  private var progress = Spring(0, response: 0.38)
  private var finalScale = 1.0
  private var calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  private var dialsChanged = false
  private var pendingWrite: Task<Void, Never>?

  private static let inspectorWidth = 360.0
  private static let controlsSpace = 52.0

  init(model: AppModel, root: NSView) {
    self.model = model
    inspector = InspectorView(webHost: model.host)
    for view in [scrim, host] as [NSView] {
      view.frame = root.bounds
      view.autoresizingMask = [.width, .height]
      view.isHidden = true
      root.addSubview(view)
    }
    inspector.isHidden = true
    root.addSubview(inspector)
    controls.isHidden = true
    controls.safeAreaRegions = []
    host.addSubview(controls)
    scrim.onPress = { [weak self] point in
      guard let self, !self.reopenIfHit(point) else { return }
      self.close()
    }
    inspector.model.onClose = { [weak self] in self?.close() }
    inspector.model.onRemove = { [weak self] in self?.removeOpenItem() }
    inspector.model.onUpdateFromPaper = { [weak self] in self?.updateFromPaper() }
    connectLoop()
    model.handoffs.connect(inspector.model)
    layoutInspector()
  }

  var openItemId: String? { pinnedId ?? (isClosing ? nil : tile?.item?.id) }

  /// Keeps the dials showing for a component the list view has in hand, with no flight and no scrim.
  private var pinnedId: String?

  func pin(_ item: Item) {
    pinnedId = item.id
    progress = Spring(1, response: progress.response)
    inspector.alphaValue = 1
    inspector.isHidden = false
    inspector.model.isPinned = true
    layoutInspector()
    inspector.show(item: item)
    model.handoffs.show(id: item.id, in: inspector.model)
    inspector.model.note = model.statuses.note(item.id)
    syncInspector()
  }

  func unpin() {
    guard pinnedId != nil else { return }
    pinnedId = nil
    progress = Spring(0, response: progress.response)
    inspector.isHidden = true
    inspector.model.isPinned = false
    inspector.hide()
  }

  func consumeDialsChanged() -> Bool {
    defer { dialsChanged = false }
    return dialsChanged
  }

  private func layoutInspector() {
    guard let bounds = inspector.superview?.bounds else { return }
    let offset = (1 - progress.value) * (calm ? 0 : 28)
    inspector.frame = CGRect(x: bounds.width - Self.inspectorWidth + offset, y: 0, width: Self.inspectorWidth, height: bounds.height)
  }

  /// Where the open tile stands: as big as fits beside the panel, up to 1.6 times its real size.
  private func detailRect(for item: Item) -> CGRect {
    let bounds = host.bounds
    let pad = 40.0
    let areaW = bounds.width - pad * 2 - Self.inspectorWidth
    let areaH = bounds.height - pad * 2 - Self.controlsSpace
    let natural: Double
    switch item.body {
    case .component(_, let crop): natural = crop.w * 1.6
    case .material(let material): natural = max(material.w, Grain.cardWidth)
    }
    let w = min(areaW, areaH / item.aspect, natural)
    let h = w * item.aspect
    return CGRect(x: pad + (areaW - w) / 2, y: pad + (areaH - h) / 2, width: w, height: h)
  }

  func open(_ next: TileView) {
    guard let canvas = model.canvas, let item = next.item else { return }
    if tile === next, isClosing {
      isClosing = false
      next.acceptsPointer = true
      next.stage?.web.isInteractive = true
      setTargets(detailRect(for: item))
      return
    }
    guard tile == nil else { return }
    tile = next
    isClosing = false
    canvas.isLocked = true
    canvas.ensureStage(for: next)

    let start = canvas.screenRect(of: next.home)
    let target = detailRect(for: item)
    finalScale = target.width / Grain.cardWidth
    next.raise(scale: finalScale)
    next.acceptsPointer = true
    next.stage?.handOver()
    host.addSubview(next)
    placeControls(under: target, for: item)

    x = Spring(start.minX, response: x.response, damping: x.damping)
    y = Spring(start.minY, response: y.response, damping: y.damping)
    scale = Spring(canvas.camera.z * next.homeScale, response: scale.response, damping: scale.damping)
    setTargets(target)
    next.setFlight(x: x.value, y: y.value, scale: scale.value, finalScale: finalScale)

    host.isHidden = false
    scrim.isHidden = false
    inspector.isHidden = false
    inspector.show(item: item)
    model.handoffs.show(id: item.id, in: inspector.model)
    inspector.model.note = model.statuses.note(item.id)
    syncInspector()
    canvas.wake()
    if case .material = item.body { model.window.makeFirstResponder(host) } else { next.stage.map { _ = model.window.makeFirstResponder($0.web) } }
  }

  private func setTargets(_ rect: CGRect) {
    x.target = rect.minX
    y.target = rect.minY
    scale.target = rect.width / Grain.cardWidth
    progress.target = 1
    if calm {
      x.value = x.target
      y.value = y.target
      scale.value = scale.target
      x.velocity = 0
      y.velocity = 0
      scale.velocity = 0
    }
    model.canvas?.wake()
  }

  func close() {
    guard let tile, !isClosing, let canvas = model.canvas else { return }
    releaseBefore()
    isClosing = true
    tile.acceptsPointer = false
    tile.stage?.web.isInteractive = false
    let home = canvas.screenRect(of: tile.home)
    x.target = home.minX
    y.target = home.minY
    scale.target = canvas.camera.z * tile.homeScale
    progress.target = 0
    if calm {
      x.value = x.target
      y.value = y.target
      scale.value = scale.target
    }
    model.window.makeFirstResponder(canvas)
    canvas.wake()
  }

  /// Called every frame by the canvas. Returns whether anything is still moving.
  func step(_ dt: Double) -> Bool {
    guard let tile else { return false }
    x.step(dt)
    y.step(dt)
    scale.step(dt)
    progress.step(dt)
    tile.setFlight(x: x.value, y: y.value, scale: scale.value, finalScale: finalScale)
    scrim.alphaValue = progress.value
    inspector.alphaValue = progress.value
    controls.alphaValue = progress.value
    layoutInspector()
    let settled = x.isSettled && y.isSettled && scale.isSettled && progress.isSettled
    if settled, isClosing { finishClosing(tile) }
    return !settled
  }

  private func finishClosing(_ tile: TileView) {
    guard let canvas = model.canvas else { return }
    canvas.worldHost().addSubview(tile)
    tile.land()
    tile.stage?.backToLoop()
    self.tile = nil
    isClosing = false
    host.isHidden = true
    scrim.isHidden = true
    controls.isHidden = true
    inspector.isHidden = true
    inspector.hide()
    canvas.isLocked = false
    if dialsChanged, let id = tile.item?.id { model.plates?.invalidate(id) }
    dialsChanged = false
    canvas.wake()
  }

  private func placeControls(under rect: CGRect, for item: Item) {
    controls.isHidden = !item.isComponent
    let size = controls.fittingSize
    controls.frame = CGRect(x: rect.midX - size.width / 2, y: rect.maxY + 12, width: size.width, height: size.height)
  }

  /// Keeps an open tile fitted to the window as the window changes size.
  func windowResized() {
    layoutInspector()
    guard let tile, !isClosing, let item = tile.item else { return }
    let target = detailRect(for: item)
    finalScale = target.width / Grain.cardWidth
    tile.raise(scale: finalScale)
    setTargets(target)
    placeControls(under: target, for: item)
  }

  private func updateFromPaper() {
    guard let id = openItemId else { return }
    inspector.model.isUpdating = true
    Task {
      defer { inspector.model.isUpdating = false }
      do {
        try await model.importer?.update(id)
        if let item = model.store?.items[id] { inspector.show(item: item) }
      } catch {
        model.chrome?.say(error.localizedDescription)
      }
    }
  }

  // MARK: The loop from Paper to code

  private func connectLoop() {
    let state = inspector.model
    state.onStartOver = { [weak self] in self?.handsOnStage?.startOver() }
    state.onWatch = { [weak self] in self?.handsOnStage?.watch() }
    state.onHoldBefore = { [weak self] held in self?.holdBefore(held) }
    state.onNoteEdited = { [weak self] text in
      if let self, let id = openItemId { model.statuses.setNote(id, text) }
    }
    state.onRevert = { [weak self] change in
      if let self, let id = openItemId { setDial(id: id, values: [change.dial: change.from]) }
    }
    state.onRevertAll = { [weak self] in
      guard let self, let id = openItemId else { return }
      setDial(id: id, values: Dictionary(uniqueKeysWithValues: model.statuses.changes(id).map { ($0.dial, $0.from) }))
    }
    state.onCopyChanges = { [weak self] in
      guard let self, let id = openItemId else { return }
      copy(model.statuses.changes(id).map(\.line).joined(separator: "\n"))
    }
    state.onCopyBrief = { [weak self] in
      guard let self, let id = openItemId else { return }
      Task {
        do {
          copy(try await model.tools.brief(id)["markdown"] as? String ?? "")
          model.chrome?.say("Copied the brief.")
        } catch {
          model.chrome?.say(error.localizedDescription)
        }
      }
    }
    state.onToggleBuilt = { [weak self] in
      guard let self, let id = openItemId else { return }
      if model.statuses.built(id) == nil {
        model.statuses.markBuilt(id, repository: nil, summary: nil, session: nil)
      } else {
        model.statuses.clearBuilt(id)
      }
    }
    state.onDismissLost = { [weak self] in
      if let self, let id = openItemId { model.statuses.recordLostTune(id, []) }
    }
    optionMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
      self?.optionChanged(event)
      return event
    }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  /// The component being used right now, wherever it stands.
  private var handsOnStage: LiveStage? { tile?.stage ?? (pinnedId == nil ? nil : model.list?.stage) }

  private func holdBefore(_ held: Bool) {
    guard let id = openItemId, inspector.model.showsBefore != held else { return }
    inspector.model.showsBefore = held
    handsOnStage?.tune(saved: held ? [:] : DialState.saved(id))
  }

  /// Ends a comparison before the component it belongs to goes away.
  func releaseBefore() {
    holdBefore(false)
  }

  private func optionChanged(_ event: NSEvent) {
    guard openItemId != nil, inspector.model.sourceFile == nil, !inspector.model.changes.isEmpty else { return }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // Option moves the caret by words in a text field, and that shouldn't flash the component.
    if flags == .option, model.window.firstResponder is NSText { return }
    holdBefore(flags == .option)
  }

  /// Shows the current facts for whatever is open.
  func syncInspector() {
    guard let id = openItemId else { return }
    let statuses = model.statuses
    let state = inspector.model
    let status = statuses.status(id)
    state.status = status
    state.changes = statuses.changes(id)
    state.lostTune = statuses.lostTune(id)
    state.paper = status.paper
    state.resumableSession = statuses.built(id)?.session
    state.run = model.handoffs.run(for: id)
    if let built = statuses.built(id) {
      let when = Date.now.timeIntervalSince(built.at) < 60 ? "just now" : built.at.formatted(.relative(presentation: .named))
      let place = built.repository.map { " into \(URL(filePath: $0).lastPathComponent)" } ?? ""
      state.builtLine = "Built\(place) \(when)." + (status.build == .built ? "" : " Changed since.")
    } else {
      state.builtLine = nil
    }
    // A note that Claude Code cleared or wrote shows up here. What's being typed already matches.
    if state.note.trimmingCharacters(in: .whitespacesAndNewlines) != statuses.note(id).trimmingCharacters(in: .whitespacesAndNewlines) { state.note = statuses.note(id) }
    if let item = tile?.item { placeControls(under: detailRect(for: item), for: item) } else { model.list?.relayout() }
  }

  private func removeOpenItem() {
    if let id = pinnedId {
      take(id)
      return
    }
    guard let id = tile?.item?.id else { return }
    pendingRemoval = id
    close()
  }

  private var pendingRemoval: String? {
    didSet { checkRemoval() }
  }

  private func checkRemoval() {
    guard let id = pendingRemoval else { return }
    pendingRemoval = nil
    Task {
      while tile != nil { try? await Task.sleep(for: .milliseconds(30)) }
      take(id)
    }
  }

  private func take(_ id: String) {
    model.statuses.forget(id)
    model.store?.remove(id: id)
    if ComponentLibrary.contains(id) {
      ComponentLibrary.delete(id)
      model.store?.refresh()
    }
  }

  func debugFlight() -> JSON {
    let pill = controls.frame
    var crop: JSON?
    if case .component(_, let box)? = tile?.item?.body { crop = ["x": box.x, "y": box.y, "w": box.w, "h": box.h] }
    return ["crop": crop ?? NSNull(), "open": tile != nil, "closing": isClosing, "x": x.value, "y": y.value, "scale": scale.value, "progress": progress.value, "velocityX": x.velocity, "controls": ["x": pill.minX, "y": pill.minY, "w": pill.width, "h": pill.height] as JSON]
  }

  // MARK: Messages from the page

  func tuned(id: String, state: Any?, byPerson: Bool) {
    dialsChanged = true
    if ProjectCatalog.contains(id) {
      model.projects.tuned(id, state: state, byPerson: byPerson)
      return
    }
    model.statuses.tuneChanged(id)
    let data = state.flatMap { $0 is NSNull ? nil : try? JSONSerialization.data(withJSONObject: $0) }
    DialState.write(id, data)
    let saved = (state as? JSON)?["values"] as? JSON ?? [:]
    model.pool.stages(showing: id).forEach { $0.tune(saved: saved) }
  }

  /// A click on the tile while it flies home brings it back, from wherever it has reached.
  func reopenIfHit(_ point: CGPoint) -> Bool {
    guard let tile, isClosing else { return false }
    let width = Grain.cardWidth * scale.value
    let height = (tile.item?.height ?? 0) * scale.value
    guard CGRect(x: x.value, y: y.value, width: width, height: height).contains(point) else { return false }
    open(tile)
    return true
  }

  /// Loads the panel again, for a file that changed under it.
  func reloadPanel() {
    guard let id = openItemId, let item = model.store?.items[id] else { return }
    inspector.show(item: item)
  }

  func setDial(id: String, values: JSON) {
    if ProjectCatalog.contains(id) {
      model.projects.setDials(id, values: values)
      return
    }
    DialState.merge(id, values: values)
    model.statuses.tuneChanged(id)
    let saved = DialState.saved(id)
    model.pool.stages(showing: id).forEach { $0.tune(saved: saved) }
    if openItemId == id { inspector.setDials(values) } else { model.plates?.invalidate(id) }
  }
}

/// Lets clicks through where nothing is standing, so the scrim below can catch them.
private final class PassthroughView: NSView {
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let found = super.hitTest(point)
    return found === self ? nil : found
  }
}

private final class ScrimView: NSView {
  var onPress: ((CGPoint) -> Void)?

  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Close")
    alphaValue = 0
    updateColor()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

  private func updateColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = Palette.wall.withAlphaComponent(0.88).cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColor()
  }

  override func mouseDown(with event: NSEvent) { onPress?(convert(event.locationInWindow, from: nil)) }
  override func scrollWheel(with event: NSEvent) {}
  override func magnify(with event: NSEvent) {}
}
