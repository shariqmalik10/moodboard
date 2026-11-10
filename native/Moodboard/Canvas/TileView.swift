import AVFoundation
import AppKit
import QuartzCore

/// One card on the wall. What it shows comes from where it stands: `form` is called with its coverage
/// of the window, and every layer is set from that alone, so the same position always looks the same.
final class TileView: NSView {
  private struct PieceLayers {
    let piece: Piece
    let shape: CALayer
    let picture: CALayer?
    let centerX: Double
    let centerY: Double
  }

  private(set) var key: Instance.Key?
  private(set) var item: Item?
  private(set) var plate: Plate?
  private(set) var coverage = Coverage(tile: .zero, view: .zero)
  var stage: LiveStage?
  /// Where the tile belongs on the wall. Its frame leaves this while it stands in the focus view.
  var home: CGRect = .zero
  /// How far the tile is scaled down from its wall size while it stands at home.
  var homeScale = 1.0
  private(set) var isRaised = false

  private let face = NSView()
  private let liveHost = NSView()
  private let content = CALayer()
  private let ground = CALayer()
  private let piecesRoot = CALayer()
  private let picture = CALayer()
  private let ring = CALayer()
  private let hairline = CALayer()
  private let caption = CATextLayer()
  private let markLayer = CATextLayer()
  private let well = CALayer()
  private var pieces: [PieceLayers] = []
  private var shownP = -1.0
  private var isBare = false
  private var handoff = Spring(0, response: 0.28)
  private var press = Spring(0, response: 0.22)
  private var lift = Spring(0, response: 0.3)
  private var shift = Spring(0, response: 0.42)
  private var birth = Spring(1, response: 1.1)
  private var player: AVQueuePlayer?
  private var looper: AVPlayerLooper?
  private var playerLayer: AVPlayerLayer?
  private var calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  static let radius = 8.0
  /// The running component takes over this close to fully in view.
  static let liveAt = 0.985

  override var isFlipped: Bool { true }
  /// The cell around the card in the views that have cells. The whole cell answers the pointer.
  private(set) var cell: CGRect?
  private var isHoveredInCell = false
  var pointerRect: CGRect { cell ?? home }

  /// True while the tile stands open. A tile flying home lets clicks through to the scrim, which can call it back.
  var acceptsPointer = false

  /// Goes to the running component rather than the plate over it, which is only a picture of it.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard isRaised, acceptsPointer else { return nil }
    let here = convert(point, from: superview)
    guard bounds.contains(here) else { return nil }
    return liveHost.hitTest(here) ?? self
  }

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    autoresizesSubviews = false
    for view in [liveHost, face] {
      view.wantsLayer = true
      view.layerContentsRedrawPolicy = .never
      view.layer?.cornerRadius = Self.radius
      view.layer?.cornerCurve = .continuous
      view.layer?.masksToBounds = true
      addSubview(view)
    }
    guard let root = layer, let faceLayer = face.layer else { return }
    root.shadowColor = NSColor.black.cgColor
    root.shadowOffset = CGSize(width: 0, height: 8)
    root.shadowRadius = 18
    root.shadowOpacity = 0
    root.masksToBounds = false
    content.actions = Self.noActions
    content.anchorPoint = .zero
    faceLayer.addSublayer(content)
    for sublayer in [ground, piecesRoot, picture] {
      sublayer.actions = Self.noActions
      content.addSublayer(sublayer)
    }
    picture.contentsGravity = .resize
    piecesRoot.masksToBounds = false
    hairline.actions = Self.noActions
    hairline.cornerCurve = .continuous
    hairline.borderWidth = 0.5
    hairline.opacity = 0
    root.addSublayer(hairline)
    updateHairlineColor()
    caption.actions = Self.noActions
    caption.isHidden = true
    caption.alignmentMode = .left
    caption.truncationMode = .end
    caption.font = NSFont.systemFont(ofSize: 12, weight: .medium)
    caption.fontSize = 12
    root.addSublayer(caption)
    markLayer.actions = Self.noActions
    markLayer.isHidden = true
    markLayer.alignmentMode = .right
    root.addSublayer(markLayer)
    well.actions = Self.noActions
    well.isHidden = true
    well.cornerRadius = 12
    well.cornerCurve = .continuous
    well.borderWidth = 0.5
    root.insertSublayer(well, at: 0)
    ring.actions = Self.noActions
    ring.cornerRadius = Self.radius + 3
    ring.cornerCurve = .continuous
    ring.borderWidth = 2.5
    ring.isHidden = true
    root.addSublayer(ring)
  }

  /// A light tile on the light wall needs an edge the soft shadow alone doesn't give it.
  private func updateHairlineColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      hairline.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
      caption.foregroundColor = NSColor.labelColor.withAlphaComponent(0.82).cgColor
      updateWellColor()
    }
  }

  private func updateWellColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      well.backgroundColor = NSColor.labelColor.withAlphaComponent(isHoveredInCell ? 0.085 : 0.045).cgColor
      well.borderColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
    }
  }

  /// Stands the tile in a cell, with its title and its place in the loop underneath.
  func setCell(_ next: CGRect?, title: String, mark: NSAttributedString?) {
    cell = next
    let inCell = next != nil && !isRaised
    well.isHidden = !inCell
    caption.isHidden = !inCell
    markLayer.isHidden = !inCell || mark == nil
    guard let next else { return }
    let inset = next.offsetBy(dx: -home.minX, dy: -home.minY)
    well.frame = inset
    let scale = window?.backingScaleFactor ?? 2
    caption.contentsScale = scale
    markLayer.contentsScale = scale
    let markWidth = mark.map { ceil($0.size().width) + 2 } ?? 0
    markLayer.string = mark
    markLayer.frame = CGRect(x: inset.maxX - markWidth, y: inset.maxY + 9, width: markWidth, height: 16)
    caption.string = title
    caption.frame = CGRect(x: inset.minX + 2, y: inset.maxY + 8, width: max(0, inset.width - markWidth - 10), height: 18)
    ring.frame = inset.insetBy(dx: -3, dy: -3)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateHairlineColor()
  }

  /// Shows that the keyboard is on this tile.
  var isKeyboardFocused = false {
    didSet {
      ring.isHidden = !isKeyboardFocused
      effectiveAppearance.performAsCurrentDrawingAppearance { ring.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor }
      let around = cell?.offsetBy(dx: -home.minX, dy: -home.minY) ?? bounds
      ring.frame = around.insetBy(dx: -3, dy: -3)
    }
  }

  /// Opens the tile for VoiceOver and other assistive tools.
  var onAccessibilityPress: ((TileView) -> Void)?

  override func accessibilityPerformPress() -> Bool {
    onAccessibilityPress?(self)
    return true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

  private static let noActions: [String: any CAAction] = [
    "position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "transform": NSNull(), "contents": NSNull(), "backgroundColor": NSNull(),
    "contentsRect": NSNull(), "cornerRadius": NSNull(), "borderWidth": NSNull(), "borderColor": NSNull(), "sublayers": NSNull(), "hidden": NSNull(),
  ]

  func configure(key: Instance.Key, item: Item, plate: Plate?) {
    self.key = key
    let changed = self.item?.id != item.id
    self.item = item
    toolTip = item.title
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(item.title)
    if changed || (plate != nil && self.plate == nil) { use(plate) }
    ground.backgroundColor = item.ground.cgColor
    handoff = Spring(0, response: 0.28)
    press = Spring(0, response: 0.22)
    lift = Spring(0, response: 0.3)
    shift = Spring(0, response: 0.42)
    birth = Spring(1, response: 1.1)
    face.isHidden = false
    face.alphaValue = 1
    shownP = -1
    isBare = { if case .material(let material) = item.body { return material.bare == true } else { return false } }()
    layoutParts(scale: homeScale)
    setUpVideo(for: item)
  }

  /// Sets the picture and its parts. Each text and media piece is a window onto the same picture, so a
  /// tile's dozens of layers share one texture.
  func use(_ plate: Plate?) {
    self.plate = plate
    pieces.forEach { $0.shape.removeFromSuperlayer(); $0.picture?.removeFromSuperlayer() }
    pieces = []
    picture.contents = plate?.image
    picture.opacity = 0
    guard let plate, let item else { return }
    let size = CGSize(width: Grain.cardWidth, height: item.height)
    for piece in plate.pieces {
      let rect = CGRect(x: piece.x, y: piece.y, width: piece.w, height: piece.h)
      let shape = CALayer()
      shape.actions = Self.noActions
      shape.frame = rect
      shape.cornerRadius = min(piece.radius, min(piece.w, piece.h) / 2)
      shape.cornerCurve = .continuous
      switch piece.kind {
      case .box:
        shape.backgroundColor = piece.color()
        shape.borderColor = piece.strokeColor
        shape.borderWidth = piece.strokeWidth ?? 0
      case .text:
        shape.backgroundColor = piece.color(alpha: 0.2)
        shape.frame = rect.insetBy(dx: 0, dy: rect.height * 0.2)
      case .media:
        shape.backgroundColor = item.dark ? CGColor(gray: 1, alpha: 0.1) : CGColor(gray: 0, alpha: 0.07)
      }
      piecesRoot.addSublayer(shape)

      var window: CALayer?
      if piece.kind != .box {
        let crop = CALayer()
        crop.actions = Self.noActions
        crop.frame = rect
        crop.contents = plate.image
        crop.contentsGravity = .resize
        crop.contentsRect = CGRect(x: piece.x / size.width, y: piece.y / size.height, width: piece.w / size.width, height: piece.h / size.height)
        piecesRoot.addSublayer(crop)
        window = crop
      }
      pieces.append(PieceLayers(piece: piece, shape: shape, picture: window, centerX: rect.midX / size.width, centerY: rect.midY / size.height))
    }
    shownP = -1
  }

  private var cardSize: CGSize { CGSize(width: Grain.cardWidth, height: item?.height ?? bounds.height) }

  private func layoutParts(scale: Double) {
    let card = CGRect(origin: .zero, size: cardSize)
    let rect = CGRect(x: 0, y: 0, width: card.width * scale, height: card.height * scale)
    let radius = isBare ? 0 : Self.radius * scale
    face.frame = rect
    liveHost.frame = rect
    face.layer?.cornerRadius = radius
    liveHost.layer?.cornerRadius = radius
    face.layer?.masksToBounds = !isBare
    content.bounds = card
    content.position = .zero
    content.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
    ground.frame = card
    ground.isHidden = isBare
    picture.frame = card
    piecesRoot.frame = card
    playerLayer?.frame = card
    layer?.shadowPath = isBare ? nil : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    hairline.frame = rect
    hairline.cornerRadius = radius
    hairline.isHidden = isBare
  }

  // MARK: Forming

  func form(_ next: Coverage) {
    coverage = next
    let p = isRaised ? 1 : min(next.p, birth.value)
    guard abs(p - shownP) > 0.0004 || shownP < 0 else { return }
    shownP = p
    let travel = calm ? 0 : 12.0

    if !isRaised { layer?.shadowOpacity = isBare ? 0 : Float(0.09 * easeOut((p - 0.7) / 0.3)) }
    ground.opacity = Float(easeOut(p / 0.14))
    hairline.opacity = ground.opacity
    picture.opacity = Float(clamp01((p - 0.88) / 0.1))

    for each in pieces {
      let q = pieceProgress(p: p, centerX: each.centerX, centerY: each.centerY, coverage: next)
      let rest = 1 - easeOut(q)
      let offset = CATransform3DMakeTranslation(-next.dx * travel * rest, -next.dy * travel * rest, 0)
      switch each.piece.kind {
      case .box:
        each.shape.opacity = Float(easeOut(q / 0.55))
        each.shape.transform = offset
      case .text, .media:
        let reveal = easeOut((q - 0.45) / 0.45)
        each.shape.opacity = Float(easeOut(q / 0.3) * (1 - reveal))
        each.shape.transform = offset
        each.picture?.opacity = Float(reveal)
        each.picture?.transform = offset
      }
    }
  }

  /// Everything here runs on time rather than on position: the live handover, and the press and hover
  /// responses. Returns true while any of it still has somewhere to go.
  func advance(_ dt: Double, quiet: Bool = false) -> Bool {
    let isFull = (coverage.p >= Self.liveAt && birth.value >= Self.liveAt) || isRaised
    let ready = stage?.phase == .ready
    handoff.target = isFull && ready ? 1 : 0
    handoff.step(dt)
    press.step(dt)
    lift.step(dt)
    shift.step(dt)
    if !birth.isSettled {
      birth.step(dt)
      form(coverage)
    }
    face.alphaValue = 1 - handoff.value
    face.isHidden = handoff.value >= 0.999
    stage?.setRunning(isFull && ready && !calm && handoff.target == 1 && !quiet)
    updateVideo(isFull)
    if !isRaised, let root = layer {
      let scale = 1 + 0.012 * lift.value - 0.018 * press.value
      var transform = CATransform3DMakeTranslation(root.bounds.midX, root.bounds.midY + shift.value, 0)
      transform = CATransform3DScale(transform, scale, scale, 1)
      transform = CATransform3DTranslate(transform, -root.bounds.midX, -root.bounds.midY, 0)
      root.transform = transform
    }
    return !(handoff.isSettled && press.isSettled && lift.isSettled && shift.isSettled && birth.isSettled)
  }

  /// Forms on a timer rather than as you scroll, for something just added to the wall.
  func beginBirth(response: Double = 1.1) {
    guard !calm else { return }
    birth = Spring(0, response: response)
    birth.target = 1
    shownP = -1
  }

  /// The column moved under this tile, so it glides to its new place instead of jumping there.
  func slide(from oldY: Double, to newY: Double) {
    guard !calm else { return }
    shift.value += oldY - newY
    shift.target = 0
  }

  func setHovered(_ hovered: Bool) {
    lift.target = hovered && !calm && cell == nil ? 1 : 0
    isHoveredInCell = hovered
    if cell != nil { updateWellColor() }
  }

  /// Moves the tile to a new place in a layout whose cell size changed.
  func place(home next: CGRect, scale: Double) {
    home = next
    guard !isRaised else {
      homeScale = scale
      return
    }
    frame = next
    guard scale != homeScale else { return }
    homeScale = scale
    layoutParts(scale: scale)
    if let stage, let item, case .component(let viewport, let crop) = item.body {
      stage.present(viewport: viewport, crop: crop, scale: scale * Grain.cardWidth / crop.w)
    }
    shownP = -1
  }

  func setPressed(_ pressed: Bool) {
    press.target = pressed ? 1 : 0
  }

  // MARK: Live

  func attach(_ stage: LiveStage) {
    self.stage = stage
    guard let item, case .component(let viewport, let crop) = item.body else { return }
    stage.present(viewport: viewport, crop: crop, scale: homeScale * Grain.cardWidth / crop.w)
    liveHost.addSubview(stage.web)
  }

  func detach() -> LiveStage? {
    defer { stage = nil }
    handoff = Spring(0, response: 0.28)
    face.alphaValue = 1
    face.isHidden = false
    return stage
  }

  // MARK: The focus view

  /// Grows the tile's real size to its final scale first, then flies it there with a transform. Text
  /// is sharp the whole way, and nothing in the page has to reflow.
  func raise(scale: Double) {
    isRaised = true
    caption.isHidden = true
    markLayer.isHidden = true
    well.isHidden = true
    shift = Spring(0, response: 0.42)
    lift.target = 0
    press.target = 0
    layer?.transform = CATransform3DIdentity
    frame.size = CGSize(width: cardSize.width * scale, height: cardSize.height * scale)
    layoutParts(scale: scale)
    if let stage, let item, case .component(let viewport, let crop) = item.body {
      stage.present(viewport: viewport, crop: crop, scale: scale * Grain.cardWidth / crop.w)
      stage.web.isInteractive = true
    }
    layer?.shadowOpacity = isBare ? 0 : 0.28
    layer?.shadowRadius = 40
    layer?.shadowOffset = CGSize(width: 0, height: 18)
    shownP = -1
    form(coverage)
  }

  /// Moves the view itself, not only its layer, because AppKit finds what's under the pointer from the frame.
  func setFlight(x: Double, y: Double, scale: Double, finalScale: Double) {
    frame.origin = CGPoint(x: x, y: y)
    let k = scale / finalScale
    layer?.transform = CATransform3DMakeScale(k, k, 1)
  }

  func land() {
    isRaised = false
    acceptsPointer = false
    layer?.transform = CATransform3DIdentity
    frame = home
    layoutParts(scale: homeScale)
    caption.isHidden = cell == nil
    markLayer.isHidden = cell == nil || markLayer.string == nil
    well.isHidden = cell == nil
    if let stage, let item, case .component(let viewport, let crop) = item.body {
      stage.present(viewport: viewport, crop: crop, scale: homeScale * Grain.cardWidth / crop.w)
      stage.web.isInteractive = false
    }
    layer?.shadowRadius = 18
    layer?.shadowOffset = CGSize(width: 0, height: 8)
    shownP = -1
    form(coverage)
  }

  // MARK: Film

  private func setUpVideo(for item: Item) {
    playerLayer?.removeFromSuperlayer()
    playerLayer = nil
    player = nil
    looper = nil
    guard case .material(let material) = item.body, material.kind == .video else { return }
    let url = Paths.materials.appending(path: material.src)
    let queue = AVQueuePlayer()
    queue.isMuted = true
    looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
    let film = AVPlayerLayer(player: queue)
    film.actions = Self.noActions
    film.videoGravity = .resizeAspectFill
    film.frame = CGRect(origin: .zero, size: cardSize)
    film.opacity = 0
    content.addSublayer(film)
    player = queue
    playerLayer = film
  }

  private func updateVideo(_ isFull: Bool) {
    guard let player, let playerLayer else { return }
    playerLayer.opacity = isFull ? 1 : 0
    if isFull, player.rate == 0, !calm { player.play() }
    if !isFull, player.rate != 0 { player.pause() }
  }
}
