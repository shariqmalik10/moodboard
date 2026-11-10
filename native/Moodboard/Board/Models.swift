import AppKit

struct Size: Codable, Equatable {
  var w: Double
  var h: Double
}

struct Crop: Codable, Equatable {
  var x: Double
  var y: Double
  var w: Double
  var h: Double
}

/// Something added by hand: an image or video with its own shape. `bare` means a cut-out with no card.
struct Material: Codable, Equatable {
  var kind: Kind
  var src: String
  var title: String
  var w: Double
  var h: Double
  var bare: Bool?

  enum Kind: String, Codable {
    case image
    case video
  }
}

/// The wall as stored. Columns hold ids in reading order, so adding something changes one column and
/// the rest of the wall stays where it is. `hidden` tells a removed component from a new one.
struct Board: Codable, Equatable {
  var columns: [[String]]
  var materials: [String: Material]
  var hidden: [String]?
}

struct CatalogRow: Codable {
  var id: String
  var project: String
  var title: String
  var viewport: Size
  var crop: Crop
  var dark: Bool
  var ground: String
}

struct Catalog: Codable {
  var board: Board
  var demos: [CatalogRow]
}

/// Something on the wall.
struct Item {
  enum Body {
    case component(viewport: Size, crop: Crop)
    case material(Material)
  }

  let id: String
  let title: String
  let project: String
  let ground: NSColor
  let dark: Bool
  let body: Body

  init(row: CatalogRow) {
    id = row.id
    title = row.title
    project = row.project
    ground = NSColor(hex: row.ground) ?? .windowBackgroundColor
    dark = row.dark
    body = .component(viewport: row.viewport, crop: row.crop)
  }

  init(id: String, material: Material) {
    self.id = id
    title = material.title
    project = "material"
    ground = NSColor(srgbRed: 0.914, green: 0.922, blue: 0.902, alpha: 1)
    dark = false
    body = .material(material)
  }

  var aspect: Double {
    switch body {
    case .component(_, let crop): crop.h / crop.w
    case .material(let material): min(2.2, max(0.45, material.h / material.w))
    }
  }

  var height: Double { (Grain.cardWidth * aspect).rounded() }

  var isComponent: Bool {
    if case .component = body { return true }
    return false
  }
}

extension NSColor {
  convenience init?(hex: String) {
    var text = hex.trimmingCharacters(in: .whitespaces)
    guard text.hasPrefix("#") else { return nil }
    text.removeFirst()
    if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
    guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
    let wide = text.count == 8
    let channels = wide ? value >> 8 : value
    let alpha = wide ? Double(value & 0xff) / 255 : 1
    self.init(
      srgbRed: Double((channels >> 16) & 0xff) / 255,
      green: Double((channels >> 8) & 0xff) / 255,
      blue: Double(channels & 0xff) / 255,
      alpha: alpha
    )
  }
}

enum Paths {
  // A Debug build keeps its own wall, so running one never touches the data of the app you use.
  #if DEBUG
    private static let folderName = "Moodboard Debug"
  #else
    private static let folderName = "Moodboard"
  #endif

  static let support: URL = folder(
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: folderName, directoryHint: .isDirectory)
  )
  static let socket = support.appending(path: "mcp.sock")
  static let board = support.appending(path: "board.json")
  static let state = support.appending(path: "state.json")
  static let notes = support.appending(path: "notes.json")
  static let dials = folder(support.appending(path: "dials", directoryHint: .isDirectory))
  static let plates = folder(support.appending(path: "plates", directoryHint: .isDirectory))
  static let materials = folder(support.appending(path: "materials", directoryHint: .isDirectory))
  static let components = folder(support.appending(path: "components", directoryHint: .isDirectory))
  static let handoffs = folder(support.appending(path: "handoffs", directoryHint: .isDirectory))

  private static func folder(_ url: URL) -> URL {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A component's id as one safe file name.
  static func fileName(for id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))) ?? id
  }
}

func stableHash(_ data: Data) -> String {
  var hash: UInt64 = 0xcbf2_9ce4_8422_2325
  for byte in data {
    hash ^= UInt64(byte)
    hash = hash &* 0x100_0000_01b3
  }
  return String(hash, radix: 36)
}

typealias JSON = [String: Any]
