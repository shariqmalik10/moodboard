import Foundation

/// The ways the components can be laid out. The app starts on the wall.
enum ViewMode: String, CaseIterable, Identifiable {
  case wall
  case grid
  case list

  var id: String { rawValue }

  var title: String {
    switch self {
    case .wall: "Wall"
    case .grid: "Grid"
    case .list: "List"
    }
  }

  var symbol: String {
    switch self {
    case .wall: "rectangle.3.offgrid"
    case .grid: "square.grid.3x3"
    case .list: "sidebar.left"
    }
  }
}

/// Which things are showing: everything, or one project's.
enum ProjectFilter: Hashable {
  case all
  case project(String)

  func includes(_ item: Item) -> Bool {
    switch self {
    case .all: true
    case .project(let name): item.project == name
    }
  }

  var title: String {
    switch self {
    case .all: "All"
    case .project(let name): Projects.name(name)
    }
  }
}

enum Projects {
  private static let order = ["paper", "material"]

  static func name(_ project: String) -> String {
    switch project {
    case "paper": "Paper"
    case "material": "Pictures"
    default: ProjectCatalog.name(of: project) ?? project
    }
  }

  /// The known projects in their usual order, then any others by name.
  static func sorted(_ projects: Set<String>) -> [String] {
    order.filter(projects.contains) + projects.subtracting(order).sorted()
  }
}

/// What the canvas needs from a way of arranging tiles.
protocol Arrangement {
  func cards(in rect: CGRect) -> [Instance]
  /// How far to look to be sure of finding every card.
  var span: Double { get }
  /// The range the camera may scroll through, or nil for a wall with no ends.
  func scrollLimits(viewHeight: Double) -> ClosedRange<Double>?
  var headings: [GridLayout.Heading] { get }
  /// True when only the tile under the pointer runs, and the rest stand still.
  var runsOnHover: Bool { get }
}

extension Arrangement {
  var isEndless: Bool { scrollLimits(viewHeight: 0) == nil }
}

extension Layout: Arrangement {
  func scrollLimits(viewHeight: Double) -> ClosedRange<Double>? { nil }
  var headings: [GridLayout.Heading] { [] }
  var runsOnHover: Bool { false }

  /// Lays one project's cards out as a wall of their own, each going to the shortest column.
  static func columns(for ids: [String], maxColumns: Int, heightOf: (String) -> Double) -> [[String]] {
    guard !ids.isEmpty, maxColumns > 0 else { return [] }
    // Too few to fill a wall, so each column holds them all from a different start. No tile stands over itself.
    if ids.count <= 6 {
      return ids.indices.map { Array(ids[$0...] + ids[..<$0]) }
    }
    let count = min(maxColumns, max(3, ids.count / 3))
    var columns = Array(repeating: [String](), count: count)
    var heights = Array(repeating: 0.0, count: count)
    for id in ids {
      let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
      columns[shortest].append(id)
      heights[shortest] += heightOf(id) + Grain.gap
    }
    return columns
  }
}

/// An ordered overview: rows of equal cells that fill the window, grouped by project, with a top and a bottom.
struct GridLayout: Arrangement {
  struct Section {
    let title: String
    let ids: [String]
  }

  struct Heading: Equatable {
    let title: String
    let count: Int
    let x: Double
    let y: Double
  }

  enum Density: Int, CaseIterable {
    case small
    case medium
    case large

    var cellWidth: Double {
      switch self {
      case .small: 200
      case .medium: 268
      case .large: 360
      }
    }
  }

  private static let gap = 20.0
  private static let captionSpace = 32.0
  private static let wellShape = 0.72
  private static let wellInset = 14.0
  static let top = 104.0
  private static let bottom = 48.0
  private static let headingSpace = 36.0
  private static let sectionGap = 20.0
  private static let margin = 32.0

  let headings: [Heading]
  private let all: [Instance]
  private let height: Double

  init(sections: [Section], width: Double, density: Density = .medium, heightOf: (String) -> Double) {
    let room = max(width - Self.margin * 2, density.cellWidth)
    let columns = max(1, Int((room + Self.gap) / (density.cellWidth + Self.gap)))
    let cellWidth = (room - Double(columns - 1) * Self.gap) / Double(columns)
    let wellHeight = (cellWidth * Self.wellShape).rounded()
    let pitchX = cellWidth + Self.gap
    let pitchY = wellHeight + Self.captionSpace + Self.gap

    var y = Self.top
    var headings: [Heading] = []
    var cards: [Instance] = []
    for section in sections where !section.ids.isEmpty {
      headings.append(Heading(title: section.title, count: section.ids.count, x: Self.margin, y: y))
      y += Self.headingSpace
      for (at, id) in section.ids.enumerated() {
        let cell = CGRect(x: Self.margin + Double(at % columns) * pitchX, y: y + Double(at / columns) * pitchY, width: cellWidth, height: wellHeight)
        let natural = max(heightOf(id), 1)
        let scale = min(1, (cellWidth - Self.wellInset * 2) / Grain.cardWidth, (wellHeight - Self.wellInset * 2) / natural)
        let (w, h) = (Grain.cardWidth * scale, natural * scale)
        cards.append(Instance(
          key: .init(id: id, column: 0, repeatIndex: 0),
          x: cell.midX - w / 2,
          y: cell.midY - h / 2,
          h: h,
          scale: scale,
          cell: cell
        ))
      }
      y += Double((section.ids.count + columns - 1) / columns) * pitchY + Self.sectionGap
    }
    self.headings = headings
    all = cards
    height = y + Self.bottom
  }

  func cards(in rect: CGRect) -> [Instance] {
    all.filter { ($0.cell ?? $0.rect).intersects(rect) }
  }

  var span: Double { height }
  var runsOnHover: Bool { true }

  func scrollLimits(viewHeight: Double) -> ClosedRange<Double>? {
    min(0, viewHeight - height)...0
  }
}
