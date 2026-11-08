// Cuts a window recording into a demo: keeps the segments you list, eases a camera between zooms,
// draws a cursor for the scripted pointer events, and floats code cards over the picture.
//   render edit.json [--stills 1.5,8,20.25]
// Times in the edit are seconds of the source movie, and positions are window points from the top left.
// With --stills it writes PNGs of those output times instead of the movie.

import AppKit
import AVFoundation
import CoreImage
import CoreText

struct Edit: Decodable {
  var source: String
  var out: String
  var fps: Int?
  var size: [Int]?
  var points: [Double]?
  var segments: [Segment]
  var camera: [Shot]?
  var pointer: [Pointer]?
  var cards: [Card]?
  /// Output seconds at the end that dissolve into the opening frame, so the movie loops cleanly.
  var loopFade: Double?
}

struct Segment: Decodable {
  var from: Double
  var to: Double
  var speed: Double?
  /// Output seconds this segment takes to dissolve in from the one before.
  var fade: Double?
}

struct Shot: Decodable {
  var at: Double
  var zoom: Double
  var x: Double?
  var y: Double?
  var response: Double?
  var snap: Bool?
}

struct Pointer: Decodable {
  enum Kind: String, Decodable { case show, move, click, drag, hide }
  var at: Double
  var kind: Kind
  var x: Double?
  var y: Double?
  var dx: Double?
  var dur: Double?
  var ease: Bool?
}

struct Card: Decodable {
  var from: Double
  var to: Double
  var title: String
  /// The card's left edge, and the gap under it, in output pixels. It's as wide as its longest line in any frame.
  var x: Double
  var bottom: Double
  var frames: [CardFrame]
}

struct CardFrame: Decodable {
  var at: Double
  var lines: [String]
  /// Line, first column, end column.
  var mark: [Int]?
  /// Line, column.
  var caret: [Int]?
}

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

func ease(_ u: Double) -> Double {
  let x = min(max(u, 0), 1)
  return x * x * x * (x * (x * 6 - 15) + 10)
}

func easeOut(_ u: Double) -> Double {
  let x = min(max(u, 0), 1)
  return 1 - pow(1 - x, 3)
}

// MARK: Time

/// Maps output time to source time and back.
struct Timeline {
  struct Piece {
    let from: Double
    let to: Double
    let speed: Double
    let fade: Double
    let start: Double
    var length: Double { (to - from) / speed }
  }

  let pieces: [Piece]
  let duration: Double

  init(_ segments: [Segment]) throws {
    var pieces: [Piece] = []
    var start = 0.0
    var last = -Double.infinity
    for segment in segments {
      guard segment.from >= last, segment.to > segment.from else { throw Failure("Segments have to run forward without overlapping.") }
      let piece = Piece(from: segment.from, to: segment.to, speed: segment.speed ?? 1, fade: segment.fade ?? 0, start: start)
      pieces.append(piece)
      start += piece.length
      last = segment.to
    }
    guard !pieces.isEmpty else { throw Failure("The edit has no segments.") }
    self.pieces = pieces
    duration = start
  }

  /// A source time that was cut out lands at the start of the next segment.
  func output(_ source: Double) -> Double {
    for piece in pieces {
      if source < piece.from { return piece.start }
      if source <= piece.to { return piece.start + (source - piece.from) / piece.speed }
    }
    return duration
  }

  func source(_ output: Double) -> (index: Int, time: Double) {
    let index = pieces.lastIndex { $0.start <= output } ?? 0
    let piece = pieces[index]
    return (index, min(piece.to, piece.from + (output - piece.start) * piece.speed))
  }
}

// MARK: Camera

struct Spring {
  var value: Double
  var velocity = 0.0

  /// Critically damped, so it settles without overshooting.
  mutating func step(to target: Double, response: Double, dt: Double) {
    let w = 2 * Double.pi / response
    let c1 = value - target
    let c2 = velocity + w * c1
    let decay = exp(-w * dt)
    value = target + (c1 + c2 * dt) * decay
    velocity = (c2 - w * (c1 + c2 * dt)) * decay
  }
}

struct Camera {
  struct Key {
    let time: Double
    let zoom: Double
    let x: Double
    let y: Double
    let response: Double
    let snap: Bool
  }

  let keys: [Key]
  let window: CGSize
  var zoom: Spring
  var x: Spring
  var y: Spring
  private var applied = -1

  init(_ shots: [Shot], timeline: Timeline, window: CGSize) {
    keys = shots.map {
      Key(time: timeline.output($0.at), zoom: max($0.zoom, 1), x: $0.x ?? window.width / 2, y: $0.y ?? window.height / 2, response: $0.response ?? 0.9, snap: $0.snap ?? false)
    }.sorted { $0.time < $1.time }
    self.window = window
    let first = keys.first
    zoom = Spring(value: first?.zoom ?? 1)
    x = Spring(value: first?.x ?? window.width / 2)
    y = Spring(value: first?.y ?? window.height / 2)
  }

  mutating func step(at time: Double, dt: Double) {
    guard let index = keys.lastIndex(where: { $0.time <= time }) else { return }
    let key = keys[index]
    if index != applied, key.snap {
      zoom = Spring(value: key.zoom)
      x = Spring(value: key.x)
      y = Spring(value: key.y)
    }
    applied = index
    zoom.step(to: key.zoom, response: key.response, dt: dt)
    x.step(to: key.x, response: key.response, dt: dt)
    y.step(to: key.y, response: key.response, dt: dt)
  }

  /// The part of the window in view, in points. It never leaves the window.
  var view: CGRect {
    let z = max(zoom.value, 1)
    let size = CGSize(width: window.width / z, height: window.height / z)
    let origin = CGPoint(x: min(max(x.value - size.width / 2, 0), window.width - size.width), y: min(max(y.value - size.height / 2, 0), window.height - size.height))
    return CGRect(origin: origin, size: size)
  }
}

// MARK: Pointer

struct PointerPath {
  enum Motion { case glide, drag, dragEased }

  struct Leg {
    let start: Double
    let end: Double
    let from: CGPoint
    let to: CGPoint
    let motion: Motion
  }

  private(set) var legs: [Leg] = []
  private(set) var visibility: [(time: Double, shown: Bool)] = []
  private(set) var presses: [(start: Double, end: Double)] = []
  private(set) var ripples: [(time: Double, at: CGPoint)] = []
  private var rest: CGPoint?

  init(_ events: [Pointer], timeline: Timeline) {
    var free = -Double.infinity
    for event in events.sorted(by: { $0.at < $1.at }) {
      let time = timeline.output(event.at)
      let point = CGPoint(x: event.x ?? rest?.x ?? 0, y: event.y ?? rest?.y ?? 0)
      switch event.kind {
      case .show:
        rest = point
        visibility.append((time, true))
        free = time
      case .hide:
        visibility.append((time, false))
      case .move, .click, .drag:
        let arrive = event.kind == .move ? time : time - 0.12
        let from = rest ?? CGPoint(x: point.x + 160, y: point.y + 120)
        let travel = min(max(0.32 + hypot(point.x - from.x, point.y - from.y) / 1400, 0.42), 0.85)
        let start = min(max(free, arrive - travel), arrive)
        if rest == nil || visibility.last?.shown == false { visibility.append((start, true)) }
        legs.append(Leg(start: start, end: max(arrive, start + 0.0001), from: from, to: point, motion: .glide))
        rest = point
        free = arrive
        if event.kind == .click {
          presses.append((time - 0.05, time + 0.09))
          ripples.append((time, point))
          free = time + 0.09
        }
        if event.kind == .drag {
          let end = timeline.output(event.at + (event.dur ?? 0.3))
          let to = CGPoint(x: point.x + (event.dx ?? 0), y: point.y)
          legs.append(Leg(start: time, end: max(end, time + 0.0001), from: point, to: to, motion: event.ease == true ? .dragEased : .drag))
          presses.append((time - 0.05, end))
          rest = to
          free = end
        }
      }
    }
  }

  func position(at time: Double) -> CGPoint? {
    guard let first = legs.first else { return rest }
    guard let leg = legs.last(where: { $0.start <= time }) else { return first.from }
    let u = (time - leg.start) / (leg.end - leg.start)
    if u >= 1 { return leg.to }
    let along = switch leg.motion {
    case .glide, .dragEased: ease(u)
    case .drag: u
    }
    return CGPoint(x: leg.from.x + (leg.to.x - leg.from.x) * along, y: leg.from.y + (leg.to.y - leg.from.y) * along)
  }

  func opacity(at time: Double) -> Double {
    guard let change = visibility.last(where: { $0.time <= time }) else { return 0 }
    let u = ease((time - change.time) / 0.22)
    return change.shown ? u : 1 - u
  }

  /// How far the button is down, from 0 to 1.
  func pressed(at time: Double) -> Double {
    var amount = 0.0
    for press in presses where press.start <= time {
      let down = ease((time - press.start) / 0.06)
      let up = time > press.end ? ease((time - press.end) / 0.14) : 0
      amount = max(amount, down * (1 - up))
    }
    return amount
  }
}

// MARK: Drawing

/// Draws into a premultiplied sRGB bitmap with the origin at the top left.
func drawImage(_ size: CGSize, _ body: (CGContext) -> Void) -> CGImage? {
  guard let context = CGContext(data: nil, width: Int(size.width.rounded(.up)), height: Int(size.height.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
  context.translateBy(x: 0, y: size.height)
  context.scaleBy(x: 1, y: -1)
  body(context)
  return context.makeImage()
}

func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
  CGColor(srgbRed: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, alpha: alpha)
}

@MainActor
struct CursorArt {
  let image: CIImage
  /// The image's size in points, and where the tip sits in it.
  let size: CGSize
  let hotSpot: CGPoint
  let density: Double

  init() {
    let cursor = NSCursor.arrow
    density = 6
    size = cursor.image.size
    hotSpot = cursor.hotSpot
    let pixels = CGSize(width: size.width * density, height: size.height * density)
    let picture = drawImage(pixels) { context in
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
      cursor.image.draw(in: CGRect(origin: .zero, size: pixels), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
    }
    image = picture.map { CIImage(cgImage: $0, options: [.colorSpace: NSNull()]) } ?? CIImage.empty()
  }
}

/// A file excerpt the way an editor shows it, with the changing part marked.
struct CardArt {
  /// The card is laid out at this size, then drawn this much bigger, so its code stays readable in a film shown at
  /// half size on a web page.
  static let scale = 1.3
  static let shadow = 44.0
  static let pad = 26.0
  static let titleHeight = 46.0
  static let lineHeight = 33.0
  static var code: NSFont { .monospacedSystemFont(ofSize: 20, weight: .regular) }
  static var label: NSFont { .systemFont(ofSize: 17, weight: .medium) }

  /// The layout width that fits the title and the longest line of every frame, with room for the caret.
  static func width(of card: Card) -> Double {
    let widest = card.frames.flatMap(\.lines).map { CTLineGetTypographicBounds(CTLineCreateWithAttributedString(highlighted($0, font: code)), nil, nil, nil) }.max() ?? 0
    let title = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: card.title, attributes: [.font: label])), nil, nil, nil)
    return (max(widest, title) + pad * 2 + 6).rounded(.up)
  }

  static func image(title: String, frame: CardFrame, width: Double) -> CIImage {
    let height = pad + titleHeight + Double(frame.lines.count) * lineHeight + pad - 8
    let size = CGSize(width: ((width + shadow * 2) * scale).rounded(.up), height: ((height + shadow * 2) * scale).rounded(.up))
    let picture = drawImage(size) { context in
      context.scaleBy(x: scale, y: scale)
      let card = CGRect(x: shadow, y: shadow, width: width, height: height)
      let shape = CGPath(roundedRect: card, cornerWidth: 18, cornerHeight: 18, transform: nil)
      context.saveGState()
      // A shadow is in device space, so it doesn't grow with the drawing.
      context.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 40 * scale, color: color(0x000000, 0.45))
      context.addPath(shape)
      context.setFillColor(color(0x1b1b1e, 0.97))
      context.fillPath()
      context.restoreGState()
      context.addPath(shape)
      context.setStrokeColor(color(0xffffff, 0.09))
      context.setLineWidth(1.5)
      context.strokePath()

      text(title, font: label, color: color(0x9b988f), x: card.minX + pad, baseline: card.minY + pad + 18, in: context)
      context.setFillColor(color(0xffffff, 0.07))
      context.fill(CGRect(x: card.minX, y: card.minY + pad + titleHeight - 14, width: width, height: 1))

      for (index, line) in frame.lines.enumerated() {
        let baseline = card.minY + pad + titleHeight + Double(index) * lineHeight + 14
        let typeset = CTLineCreateWithAttributedString(highlighted(line, font: code))
        func offset(_ column: Int) -> Double {
          let utf16 = line.utf16.count
          return CTLineGetOffsetForStringIndex(typeset, min(column, utf16), nil)
        }
        if let mark = frame.mark, mark.count == 3, mark[0] == index {
          let rect = CGRect(x: card.minX + pad + offset(mark[1]) - 3, y: baseline - 22, width: offset(mark[2]) - offset(mark[1]) + 6, height: 30)
          context.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
          context.setFillColor(color(0x84b58f, 0.32))
          context.fillPath()
        }
        draw(typeset, x: card.minX + pad, baseline: baseline, in: context)
        if let caret = frame.caret, caret.count == 2, caret[0] == index {
          context.setFillColor(color(0x84b58f))
          context.fill(CGRect(x: card.minX + pad + offset(caret[1]) - 1, y: baseline - 21, width: 2.5, height: 27))
        }
      }
    }
    return picture.map { CIImage(cgImage: $0, options: [.colorSpace: NSNull()]) } ?? CIImage.empty()
  }

  private static func text(_ string: String, font: NSFont, color: CGColor, x: Double, baseline: Double, in context: CGContext) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
    draw(line, x: x, baseline: baseline, in: context)
  }

  /// The context is flipped, so the text matrix is flipped back to keep glyphs upright.
  private static func draw(_ line: CTLine, x: Double, baseline: Double, in context: CGContext) {
    context.saveGState()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(line, context)
    context.restoreGState()
  }

  private static func highlighted(_ line: String, font: NSFont) -> NSAttributedString {
    let text = NSMutableAttributedString(string: line, attributes: [.font: font, .foregroundColor: color(0xc9c6bd)])
    let whole = NSRange(location: 0, length: (line as NSString).length)
    let rules: [(String, UInt32)] = [
      (#"\b(export|function|return|const|import|from|type)\b"#, 0x9b988f),
      (#"(?<=</?)[A-Za-z][A-Za-z0-9.]*"#, 0x8fb7d6),
      (#""[^"]*"|'[^']*'"#, 0xd6c08f),
    ]
    for (pattern, hex) in rules {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      for match in regex.matches(in: line, range: whole) { text.addAttribute(.foregroundColor, value: color(hex), range: match.range) }
    }
    return text
  }
}

func ripple(radius: Double, alpha: Double) -> CIImage {
  let size = CGSize(width: radius * 2 + 4, height: radius * 2 + 4)
  let picture = drawImage(size) { context in
    let circle = CGRect(x: 2, y: 2, width: radius * 2, height: radius * 2)
    context.setFillColor(color(0xffffff, 0.5 * alpha))
    context.fillEllipse(in: circle)
    context.setStrokeColor(color(0x1d1b17, 0.35 * alpha))
    context.setLineWidth(1.5)
    context.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
  }
  return picture.map { CIImage(cgImage: $0, options: [.colorSpace: NSNull()]) } ?? CIImage.empty()
}

// MARK: Frames

/// Reads the source in order and answers with the newest frame at or before a time.
final class Frames {
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private var current: (time: Double, image: CIImage)?
  private var upcoming: (time: Double, image: CIImage)?
  private var ended = false

  init(_ url: URL) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure("\(url.path) has no video.") }
    reader = try AVAssetReader(asset: asset)
    output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw Failure(reader.error?.localizedDescription ?? "The source couldn't be read.") }
    current = next()
  }

  private func next() -> (Double, CIImage)? {
    while let sample = output.copyNextSampleBuffer() {
      guard let pixels = sample.imageBuffer else { continue }
      return (sample.presentationTimeStamp.seconds, CIImage(cvPixelBuffer: pixels, options: [.colorSpace: NSNull()]))
    }
    ended = true
    return nil
  }

  func image(at time: Double) -> CIImage? {
    if upcoming == nil, !ended { upcoming = next() }
    while let coming = upcoming, coming.time <= time {
      current = coming
      upcoming = next()
    }
    return current?.image
  }
}

// MARK: Render

@main
@MainActor
struct Render {
  static func main() async {
    _ = NSApplication.shared
    do {
      try await run(Array(CommandLine.arguments.dropFirst()))
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("render: \(error)\n".utf8))
      exit(1)
    }
  }

  static func run(_ arguments: [String]) async throws {
    guard let path = arguments.first else { throw Failure("Pass the edit file.") }
    let editURL = URL(filePath: path)
    let edit = try JSONDecoder().decode(Edit.self, from: Data(contentsOf: editURL))
    let folder = editURL.deletingLastPathComponent()
    let stills = arguments.firstIndex(of: "--stills").flatMap { index in arguments.indices.contains(index + 1) ? arguments[index + 1].split(separator: ",").compactMap { Double($0) } : nil }

    let fps = edit.fps ?? 60
    let canvas = CGSize(width: edit.size?.first ?? 1920, height: edit.size?.last ?? 1200)
    let window = CGSize(width: edit.points?.first ?? 1440, height: edit.points?.last ?? 900)
    let timeline = try Timeline(edit.segments)
    var camera = Camera(edit.camera ?? [], timeline: timeline, window: window)
    let pointer = PointerPath(edit.pointer ?? [], timeline: timeline)
    let cursor = CursorArt()
    let frames = try await Frames(URL(filePath: edit.source, relativeTo: folder))
    let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
    var cardImages: [String: CIImage] = [:]
    var cardWidths: [Int: Double] = [:]

    let count = Int((timeline.duration * Double(fps)).rounded())
    print("output \(String(format: "%.2f", timeline.duration)) s, \(count) frames")
    for piece in timeline.pieces { print(String(format: "  %6.2f  source %6.2f to %6.2f at %.2gx", piece.start, piece.from, piece.to, piece.speed)) }

    let writer: Writer? = stills == nil ? try Writer(URL(filePath: edit.out, relativeTo: folder), size: canvas, fps: fps) : nil
    let backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: canvas))
    var opening: CIImage?
    var held: CIImage?
    var last: CIImage?
    var piece = 0
    var pending = stills ?? []

    for index in 0..<count {
      let time = Double(index) / Double(fps)
      let (at, source) = timeline.source(time)
      if at != piece {
        held = timeline.pieces[at].fade > 0 ? last : nil
        piece = at
      }
      camera.step(at: time, dt: 1 / Double(fps))
      let wanted = stills == nil || pending.contains { abs($0 - time) < 0.5 / Double(fps) }
      guard let frame = frames.image(at: source) else { throw Failure("The source ran out at \(source) s.") }
      if !wanted && held == nil && index > 0 { continue }

      let view = camera.view
      let k = canvas.width / view.width
      let scale = k * window.width / frame.extent.width
      // Window points from the top left to output pixels from the bottom left.
      func place(_ point: CGPoint) -> CGPoint { CGPoint(x: (point.x - view.minX) * k, y: canvas.height - (point.y - view.minY) * k) }
      let move = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: -view.minX * k, y: canvas.height - (window.height - view.minY) * k))
      var image = frame.transformed(by: move, highQualityDownsample: true).composited(over: backdrop)

      for click in pointer.ripples where time >= click.time && time < click.time + 0.5 {
        let u = (time - click.time) / 0.5
        let radius = (8 + 22 * easeOut(u)) * k
        let ring = ripple(radius: radius, alpha: pow(1 - u, 1.5))
        let center = place(click.at)
        image = ring.transformed(by: CGAffineTransform(translationX: center.x - ring.extent.width / 2, y: center.y - ring.extent.height / 2)).composited(over: image)
      }

      let shown = pointer.opacity(at: time)
      if shown > 0.001, let point = pointer.position(at: time) {
        let perPoint = 1.5 * k * (1 - 0.16 * pointer.pressed(at: time))
        let tip = place(point)
        let fit = perPoint / cursor.density
        let art = cursor.image
          .transformed(by: CGAffineTransform(scaleX: fit, y: fit))
          .transformed(by: CGAffineTransform(translationX: tip.x - cursor.hotSpot.x * perPoint, y: tip.y - (cursor.size.height - cursor.hotSpot.y) * perPoint))
        image = (shown < 1 ? art.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: shown)]) : art).composited(over: image)
      }

      for (cardIndex, card) in (edit.cards ?? []).enumerated() {
        let from = timeline.output(card.from)
        let to = timeline.output(card.to)
        guard time >= from, time < to + 0.3, let frame = card.frames.last(where: { timeline.output($0.at) <= time }) ?? card.frames.first else { continue }
        let key = "\(cardIndex)/\(card.frames.firstIndex { $0.at == frame.at } ?? 0)"
        let width = cardWidths[cardIndex] ?? CardArt.width(of: card)
        cardWidths[cardIndex] = width
        let art = cardImages[key] ?? CardArt.image(title: card.title, frame: frame, width: width)
        cardImages[key] = art
        let enter = easeOut((time - from) / 0.35)
        let leave = time > to ? ease((time - to) / 0.25) : 0
        let alpha = enter * (1 - leave)
        let rise = (1 - enter) * 18 + leave * 10
        let margin = CardArt.shadow * CardArt.scale
        let placed = art.transformed(by: CGAffineTransform(translationX: card.x - margin, y: card.bottom - margin - rise))
        image = placed.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)]).composited(over: image)
      }

      image = image.cropped(to: CGRect(origin: .zero, size: canvas))
      if let from = held {
        let u = (time - timeline.pieces[piece].start) / timeline.pieces[piece].fade
        if u < 1 { image = from.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": image, "inputTime": ease(u)]) } else { held = nil }
      }
      if let loop = edit.loopFade, let opening, time > timeline.duration - loop {
        image = image.applyingFilter("CIDissolveTransition", parameters: ["inputTargetImage": opening, "inputTime": ease((time - (timeline.duration - loop)) / loop)])
      }
      if index == 0 { opening = image }
      last = image

      if let writer {
        try writer.append(image, at: index, context: context)
      } else if wanted, let picture = context.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) {
        let url = URL(filePath: edit.out, relativeTo: folder).deletingPathExtension().appendingPathExtension(String(format: "%06.2f.png", time))
        let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])
        try png?.write(to: url)
        pending.removeAll { abs($0 - time) < 0.5 / Double(fps) }
        print("still \(url.path)")
      }
      if index % (fps * 5) == 0 { print(String(format: "  %5.1f s", time)) }
    }
    try await writer?.finish()
  }
}

final class Writer {
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let size: CGSize
  private let fps: Int

  init(_ url: URL, size: CGSize, fps: Int) throws {
    try? FileManager.default.removeItem(at: url)
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000, AVVideoExpectedSourceFrameRateKey: fps],
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ])
    input.expectsMediaDataInRealTime = false
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(size.width),
      kCVPixelBufferHeightKey as String: Int(size.height),
      kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ])
    writer.add(input)
    self.size = size
    self.fps = fps
    guard writer.startWriting() else { throw Failure(writer.error?.localizedDescription ?? "The movie couldn't be started.") }
    writer.startSession(atSourceTime: .zero)
  }

  func append(_ image: CIImage, at index: Int, context: CIContext) throws {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    guard let pool = adaptor.pixelBufferPool else { throw Failure(writer.error?.localizedDescription ?? "The movie stopped.") }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
    guard let buffer else { throw Failure("No buffer for frame \(index).") }
    context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else { throw Failure(writer.error?.localizedDescription ?? "Frame \(index) wasn't written.") }
  }

  func finish() async throws {
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw Failure(writer.error?.localizedDescription ?? "The movie didn't finish.") }
    print("wrote \(writer.outputURL.path)")
  }
}
