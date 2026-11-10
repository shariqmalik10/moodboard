import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// One thing a component paints, in tile points. A tile assembles itself from these as you scroll to it.
struct Piece: Codable {
  enum Kind: String, Codable {
    case box
    case text
    case media
  }

  var kind: Kind
  var x: Double
  var y: Double
  var w: Double
  var h: Double
  var radius: Double
  var fill: [Double]?
  var stroke: [Double]?
  var strokeWidth: Double?
}

/// A component at rest: its picture, and the parts that picture is made of. It only ever shows while a
/// tile is forming. Once the tile is in view, the running component replaces it.
struct Plate {
  let image: CGImage
  let pieces: [Piece]
}

private func cgColor(_ channels: [Double]?, alpha: Double = 1) -> CGColor? {
  guard let channels, channels.count == 4 else { return nil }
  return CGColor(srgbRed: channels[0], green: channels[1], blue: channels[2], alpha: channels[3] * alpha)
}

extension Piece {
  func color(alpha: Double = 1) -> CGColor? { cgColor(fill, alpha: alpha) }
  var strokeColor: CGColor? { cgColor(stroke) }
}

/// Bakes plates off to the side, a few at a time, and keeps them on disk for the next launch.
final class PlateStore {
  private let build: String
  private var plates: [String: Plate] = [:]
  private var keys: [String: String] = [:]
  private var failed: [String: String] = [:]
  private let bakers: BackstageWorkers<String>
  private var items: (String) -> Item?

  var onPlate: ((String, Plate) -> Void)?

  init(host: WebHost, backstage: NSView, items: @escaping (String) -> Item?) {
    self.items = items
    bakers = BackstageWorkers(host: host, backstage: backstage)
    build = SchemeHandler.buildKey()
    bakers.start = { [unowned self] id, web in
      guard let item = self.items(id), case .component(let viewport, _) = item.body else { return .drop }
      web.frame = CGRect(x: 0, y: 0, width: viewport.w, height: viewport.h)
      web.load(URLRequest(url: LiveStage.url(for: id, mode: .still)))
      return .loaded
    }
    bakers.receive = { [unowned self] baker, id, message in
      switch message {
      case .ready: Task { await self.complete(baker, id) }
      case .failed(_, let reason): self.fail(baker, id, reason)
      default: break
      }
    }
    clearOldBuilds()
  }

  private var folder: URL {
    let url = Paths.plates.appending(path: build, directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func clearOldBuilds() {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: Paths.plates.path)) ?? []
    for name in names where name != build {
      try? FileManager.default.removeItem(at: Paths.plates.appending(path: name))
    }
  }

  private func key(for id: String) -> String {
    let tune = DialState.saved(id)
    let data = (try? JSONSerialization.data(withJSONObject: tune, options: [.sortedKeys])) ?? Data()
    let record = ComponentLibrary.recordData(id) ?? ProjectCatalog.row(id).map { Data($0.hash.utf8) } ?? Data()
    return Paths.fileName(for: id) + "-" + stableHash(data + record)
  }

  func plate(for id: String) -> Plate? { plates[id] }
  func failure(for id: String) -> String? { failed[id] }
  var pending: Int { bakers.pending }
  var bakedCount: Int { plates.count }

  /// Asks for a plate. `first` puts it ahead of everything waiting, for a tile the person can see.
  func request(_ id: String, first: Bool = false) {
    if let item = items(id), case .material(let material) = item.body {
      guard plates[id] == nil else { return }
      Task { await loadMaterial(id, material: material) }
      return
    }
    let wanted = key(for: id)
    if keys[id] == wanted, plates[id] != nil { return }
    if bakers.queue.contains(id) {
      if first {
        bakers.removeQueued { $0 == id }
        bakers.enqueue(id, first: true)
      }
      return
    }
    guard !bakers.running.contains(id) else { return }
    if loadFromDisk(id, key: wanted) { return }
    bakers.enqueue(id, first: first)
    bakers.pump()
  }

  /// Bakes a plate and waits for it, or gives up after a few seconds and lets the wall carry on.
  func bake(_ id: String) async {
    failed[id] = nil
    request(id, first: true)
    for _ in 0..<80 {
      if plates[id] != nil || failed[id] != nil { return }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  /// The component's look changed, so the next plate has to come from the new tune.
  func invalidate(_ id: String) {
    keys[id] = nil
    request(id, first: true)
  }

  private func loadMaterial(_ id: String, material: Material) async {
    guard let image = await MaterialStore.picture(of: material) else {
      failed[id] = "\(material.title) couldn't be read."
      return
    }
    plates[id] = Plate(image: image, pieces: MaterialStore.grid(for: material))
    if let plate = plates[id] { onPlate?(id, plate) }
  }

  private func loadFromDisk(_ id: String, key: String) -> Bool {
    let base = folder.appending(path: key)
    guard
      let data = try? Data(contentsOf: base.appendingPathExtension("json")),
      let pieces = try? JSONDecoder().decode([Piece].self, from: data),
      let source = CGImageSourceCreateWithURL(base.appendingPathExtension("png") as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { return false }
    finish(id, key: key, plate: Plate(image: image, pieces: pieces))
    return true
  }

  private func finish(_ id: String, key: String, plate: Plate) {
    plates[id] = plate
    keys[id] = key
    failed[id] = nil
    onPlate?(id, plate)
  }

  private func fail(_ baker: BackstageWorkers<String>.Worker, _ id: String, _ reason: String) {
    failed[id] = reason
    bakers.release(baker)
    bakers.pump()
  }

  private func complete(_ baker: BackstageWorkers<String>.Worker, _ id: String) async {
    guard let item = items(id) else { return fail(baker, id, "It left the wall.") }
    let wanted = key(for: id)
    do {
      let plate = try await capture(item, from: baker.web)
      finish(id, key: wanted, plate: plate)
      store(plate, as: wanted)
    } catch {
      failed[id] = error.localizedDescription
    }
    bakers.release(baker)
    // Tuned or re-imported while the picture was being taken, so that picture is already out of date.
    if key(for: id) != wanted { request(id, first: true) }
    bakers.pump()
  }

  private func store(_ plate: Plate, as key: String) {
    let base = folder.appending(path: key)
    if let data = try? JSONEncoder().encode(plate.pieces) { try? data.write(to: base.appendingPathExtension("json"), options: .atomic) }
    guard let destination = CGImageDestinationCreateWithURL(base.appendingPathExtension("png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, plate.image, nil)
    CGImageDestinationFinalize(destination)
  }
}

/// Takes a baked component's picture, and the parts it's made of, at the size its tile shows them.
private func capture(_ item: Item, from web: StageWebView) async throws -> Plate {
  guard case .component(_, let crop) = item.body else { throw CocoaError(.featureUnsupported) }
  let scale = Grain.cardWidth / crop.w
  try await Task.sleep(for: .milliseconds(160))

  let data = try await web.callJSON(
    "return window.__structure(crop)",
    ["crop": ["x": crop.x, "y": crop.y, "w": crop.w, "h": crop.h]]
  )
  let pieces = try JSONDecoder().decode([Piece].self, from: data).map { piece -> Piece in
    var out = piece
    out.x *= scale
    out.y *= scale
    out.w *= scale
    out.h *= scale
    out.radius *= scale
    out.strokeWidth = piece.strokeWidth.map { max($0 * scale, 0.5) }
    return out
  }

  let configuration = WKSnapshotConfiguration()
  configuration.rect = CGRect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)
  configuration.snapshotWidth = NSNumber(value: Grain.cardWidth)
  let image = try await web.takeSnapshot(configuration: configuration)
  guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw CocoaError(.fileReadCorruptFile) }
  return Plate(image: picture, pieces: pieces)
}
