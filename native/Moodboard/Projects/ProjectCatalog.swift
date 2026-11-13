import AppKit

/// A component from a connected project, with what the wall needs to show it before the project's server is running.
struct ProjectComponent: Codable, Equatable {
  var id: String
  var title: String
  var file: String
  var exportName: String
  var hash: String
  var viewport: Size
  var ground: String
  var dark: Bool

  var row: CatalogRow {
    CatalogRow(id: id, project: project, title: title, viewport: viewport, crop: Crop(x: 0, y: 0, w: viewport.w, h: viewport.h), dark: dark, ground: ground)
  }

  /// Ids read `project/<slug>/<file>/<export>`.
  var project: String { id.split(separator: "/").dropFirst().first.map(String.init) ?? "" }
}

/// A component the scan found that isn't on the wall, and why, so its absence has an answer.
struct SkippedComponent: Codable, Equatable, Identifiable {
  var id: String
  var title: String
  var file: String
  var hash: String
  var reason: String
}

struct ConnectedProject: Codable, Equatable {
  var root: String
  var name: String
  var slug: String
  var components: [ProjectComponent] = []
  var skipped: [SkippedComponent] = []
}

/// How big a tile's page is, from how much room the component took in a wide one.
enum ProjectSizing {
  private static let padding = 48.0

  static func viewport(width: Double, height: Double) -> Size {
    var w = min(760, max(360, width + padding))
    // A row that fills any width it's given would be a sliver on the wall, so it gets a narrower page.
    if height + padding < 200 { w = min(w, 480) }
    return Size(w: w, h: min(max(height + padding, w * 0.5), w * 1.5))
  }

  static func isDark(hex: String) -> Bool {
    guard let color = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return false }
    return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent < 0.4
  }
}

/// Which projects are connected, kept on disk so their tiles show their baked plates while the servers start.
enum ProjectCatalog {
  /// The panel's folder for props the wall made up. They stay in the app, and every other dial edits the source.
  static let samplePrefix = "Sample props."

  private(set) static var projects: [ConnectedProject] = load()
  private static var rows: [String: ProjectComponent] = index(projects)
  private static var ports: [String: Int] = [:]

  private static var file: URL { Paths.support.appending(path: "projects.json") }

  private static func load() -> [ConnectedProject] {
    (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([ConnectedProject].self, from: $0) } ?? []
  }

  private static func index(_ projects: [ConnectedProject]) -> [String: ProjectComponent] {
    Dictionary(projects.flatMap(\.components).map { ($0.id, $0) }) { first, _ in first }
  }

  private static func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(projects) { try? data.write(to: file, options: .atomic) }
  }

  static func isProjectId(_ id: String) -> Bool { id.hasPrefix("project/") }
  static func contains(_ id: String) -> Bool { rows[id] != nil }
  static func row(_ id: String) -> ProjectComponent? { rows[id] }
  static func project(slug: String) -> ConnectedProject? { projects.first { $0.slug == slug } }
  static func project(of id: String) -> ConnectedProject? { rows[id].flatMap { project(slug: $0.project) } }
  static func name(of slug: String) -> String? { project(slug: slug)?.name }

  /// A slug made from the project's name that no other connected folder has, since ids are built from it.
  static func slug(named name: String, root: String) -> String {
    let words = name.lowercased().replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let wanted = words.isEmpty ? "project" : words
    let taken = Set(projects.filter { $0.root != root }.map(\.slug))
    guard taken.contains(wanted) else { return wanted }
    return (2...).lazy.map { "\(wanted)-\($0)" }.first { !taken.contains($0) } ?? wanted
  }

  static func add(_ project: ConnectedProject) {
    guard !projects.contains(where: { $0.root == project.root }) else { return }
    projects.append(project)
    save()
  }

  static func remove(slug: String) {
    projects.removeAll { $0.slug == slug }
    ports[slug] = nil
    rows = index(projects)
    save()
  }

  static func edit(slug: String, _ change: (inout ConnectedProject) -> Void) {
    guard let at = projects.firstIndex(where: { $0.slug == slug }) else { return }
    change(&projects[at])
    rows = index(projects)
    save()
  }

  static func setPort(_ port: Int?, slug: String) { ports[slug] = port }

  static func items() -> [String: Item] {
    rows.mapValues { Item(row: $0.row) }
  }

  /// Where a running component lives, once its project's server has said which port it took.
  static func url(for id: String, mode: StageMode) -> URL? {
    guard isProjectId(id), let slug = id.split(separator: "/").dropFirst().first.map(String.init), let port = ports[slug] else { return nil }
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = port
    components.path = "/stage.html"
    components.queryItems = [URLQueryItem(name: "demo", value: id), URLQueryItem(name: mode.rawValue, value: "1")]
    return components.url
  }
}
