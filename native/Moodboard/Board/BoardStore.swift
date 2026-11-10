import AppKit

/// Owns the wall's state. Every change to it, from the window or from Claude Code, goes through here.
final class BoardStore {
  private(set) var board: Board
  private(set) var items: [String: Item] = [:]
  private(set) var layout = Layout(columns: [], heightOf: { _ in 0 })
  private var catalog: [CatalogRow]
  var onChange: (() -> Void)?

  init(catalog: Catalog) {
    self.catalog = catalog.demos
    if let data = try? Data(contentsOf: Paths.board), let saved = try? JSONDecoder().decode(Board.self, from: data) {
      board = saved
    } else {
      board = catalog.board
    }
    rebuild()
    save()
  }

  var visibleIds: [String] { board.columns.flatMap { $0 }.filter { items[$0] != nil } }

  var hiddenItems: [Item] { (board.hidden ?? []).compactMap { items[$0] } }

  /// The projects with something on the wall.
  func projects(componentsOnly: Bool = false) -> [String] {
    Projects.sorted(Set(visibleIds.compactMap { items[$0] }.filter { !componentsOnly || $0.isComponent }.map(\.project)))
  }

  /// The wall's columns for this filter. Everything keeps its place, and one project gets a wall of its own.
  func columns(for filter: ProjectFilter) -> [[String]] {
    guard filter != .all else { return board.columns.map { $0.filter { items[$0] != nil } } }
    let ids = visibleIds.filter { items[$0].map(filter.includes) == true }
    return Layout.columns(for: ids, maxColumns: board.columns.count) { items[$0]?.height ?? 0 }
  }

  /// The visible things grouped by project, for the views that show projects one after another.
  func sections(for filter: ProjectFilter, componentsOnly: Bool = false, where keeps: (Item) -> Bool = { _ in true }) -> [GridLayout.Section] {
    let ids = visibleIds.filter { id in
      guard let item = items[id] else { return false }
      return filter.includes(item) && (!componentsOnly || item.isComponent) && keeps(item)
    }
    return projects(componentsOnly: componentsOnly).compactMap { project in
      let inProject = ids.filter { items[$0]?.project == project }.sorted { (items[$0]?.title ?? "") < (items[$1]?.title ?? "") }
      return inProject.isEmpty ? nil : GridLayout.Section(title: Projects.name(project), ids: inProject)
    }
  }

  private func rebuild() {
    var next: [String: Item] = [:]
    for row in catalog { next[row.id] = Item(row: row) }
    for (id, material) in board.materials { next[id] = Item(id: id, material: material) }
    for (id, item) in ComponentLibrary.items() { next[id] = item }
    for (id, item) in ProjectCatalog.items() { next[id] = item }
    items = next

    let hidden = Set(board.hidden ?? [])
    let placed = Set(board.columns.flatMap { $0 })
    for row in catalog where !placed.contains(row.id) && !hidden.contains(row.id) {
      if let shortest = board.columns.indices.min(by: { board.columns[$0].count < board.columns[$1].count }) {
        board.columns[shortest].append(row.id)
      }
    }
    let known = board.columns.map { $0.filter { next[$0] != nil } }
    layout = Layout(columns: known) { next[$0]?.height ?? 0 }
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(board) { try? data.write(to: Paths.board, options: .atomic) }
  }

  private func commit() {
    rebuild()
    save()
    onChange?()
  }

  func insert(id: String, material: Material? = nil, column: Int, index: Int) {
    guard !board.columns.contains(where: { $0.contains(id) }), !board.columns.isEmpty else { return }
    let at = board.columns.indices.contains(column) ? column : 0
    board.columns[at].insert(id, at: min(index, board.columns[at].count))
    if let material { board.materials[id] = material }
    board.hidden?.removeAll { $0 == id }
    commit()
  }

  func remove(id: String) {
    let material = board.materials[id]
    board.columns = board.columns.map { $0.filter { $0 != id } }
    if let material {
      board.materials[id] = nil
      try? FileManager.default.removeItem(at: Paths.materials.appending(path: material.src))
    } else if !ComponentLibrary.contains(id) {
      board.hidden = (board.hidden ?? []) + [id]
    }
    commit()
  }

  func isHidden(_ id: String) -> Bool { board.hidden?.contains(id) == true }

  /// Adds to whichever column is shortest, away from what the person is looking at.
  func add(_ id: String) {
    guard !board.columns.contains(where: { $0.contains(id) }), !board.columns.isEmpty else { return }
    rebuild()
    let heights = board.columns.map { column in column.reduce(0) { $0 + (items[$1]?.height ?? 0) } }
    guard let shortest = heights.indices.min(by: { heights[$0] < heights[$1] }) else { return }
    board.columns[shortest].append(id)
    commit()
  }

  /// Takes things that no longer exist off the wall, so nothing remembers them as hidden either.
  func drop(_ ids: Set<String>) {
    board.columns = board.columns.map { $0.filter { !ids.contains($0) } }
    board.hidden?.removeAll { ids.contains($0) }
    commit()
  }

  /// A component that changed on disk, such as a fresh import from Paper.
  func refresh() {
    commit()
  }
}

/// Each component's tuned dials, in DialKit's own saved form. Native is the source of truth, so a tune
/// survives a restart and Claude Code can read it.
enum DialState {
  private static func url(_ id: String) -> URL {
    Paths.dials.appending(path: Paths.fileName(for: id) + ".json")
  }

  static func read(_ id: String) -> Data? {
    try? Data(contentsOf: url(id))
  }

  static func write(_ id: String, _ data: Data?) {
    if let data {
      try? data.write(to: url(id), options: .atomic)
    } else {
      try? FileManager.default.removeItem(at: url(id))
    }
  }

  static func saved(_ id: String) -> JSON {
    guard let data = read(id), let state = try? JSONSerialization.jsonObject(with: data) as? JSON else { return [:] }
    return state["values"] as? JSON ?? [:]
  }

  static func merge(_ id: String, values: JSON) {
    var state = read(id).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? JSON } ?? ["version": 1]
    var saved = state["values"] as? JSON ?? [:]
    saved.merge(values) { _, new in new }
    state["values"] = saved
    state["version"] = 1
    if state["baseValues"] != nil { state["baseValues"] = saved }
    write(id, try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]))
  }
}
