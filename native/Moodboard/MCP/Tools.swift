import AppKit

/// The MCP tools, by the names Claude Code calls them. `MCPBridge` describes each one, and `Tools` answers it.
enum ToolName: String, CaseIterable {
  case status
  case listComponents = "list_components"
  case getComponent = "get_component"
  case importFromPaper = "import_from_paper"
  case openComponent = "open_component"
  case setDials = "set_dials"
  case setNote = "set_note"
  case connectProject = "connect_project"
  case listProjects = "list_projects"
  case disconnectProject = "disconnect_project"
  case markBuilt = "mark_built"
}

/// What Claude Code can ask of the running wall. Each method here is one MCP tool, named in `MCPBridge`.
final class Tools {
  unowned let model: AppModel
  #if DEBUG
    var recording: (activity: NSObjectProtocol, frame: NSRect, behavior: NSWindow.CollectionBehavior)?
  #endif

  init(model: AppModel) {
    self.model = model
  }

  func handle(method: String, params: JSON) async throws -> Any {
    #if DEBUG
      if method.hasPrefix("debug.") { return try await debug(method, params) }
    #endif
    guard let tool = ToolName(rawValue: method) else { throw ToolError("There's no tool called \(method).") }
    try await waitUntilStarted()
    switch tool {
    case .status: return await status()
    case .listComponents: return try await listComponents()
    case .getComponent: return try await brief(try componentId(params))
    case .importFromPaper: return try await importFromPaper(params)
    case .openComponent: return try await openComponent(try componentId(params))
    case .setDials: return try await setDials(try componentId(params), params["values"] as? JSON ?? [:])
    case .setNote: return try setNote(try componentId(params), params["note"] as? String ?? "")
    case .markBuilt: return try markBuilt(try componentId(params), params)
    case .connectProject: return try await connectProject(params)
    case .listProjects: return listProjects()
    case .disconnectProject: return try disconnectProject(params)
    }
  }

  private func waitUntilStarted() async throws {
    for _ in 0..<150 {
      if model.chrome != nil { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ToolError("The wall is still starting. Try again in a moment.")
  }

  /// The id asked for, or whatever the person has open, which is what "this component" means to them.
  private func componentId(_ params: JSON) throws -> String {
    if let id = params["id"] as? String, !id.isEmpty {
      guard model.store?.items[id]?.isComponent == true else { throw ToolError("There's no component called \(id). list_components gives the ids.") }
      return id
    }
    guard let id = model.focus?.openItemId else { throw ToolError("Nothing is open on the wall. Pass an id, or ask the person to open a component.") }
    return id
  }

  func brief(_ id: String) async throws -> JSON {
    let note = model.statuses.note(id)
    let data = try await model.runtime.call("return await window.__runtime.brief(id, saved, note)", ["id": id, "saved": DialState.saved(id), "note": note])
    var brief = try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
    if !note.isEmpty { brief["note"] = note }
    brief["place"] = place(of: id)
    return brief
  }

  /// Where a component stands in the loop, in the words the person sees.
  private func place(of id: String) -> JSON {
    let status = model.statuses.status(id)
    var place: JSON = ["tuned": status.tuned, "needsBuilding": status.needsBuilding]
    if let file = ProjectCatalog.row(id)?.file {
      place["file"] = file
      place["writtenToSource"] = status.written
    }
    if let paper = status.paper { place["paper"] = paper.rawValue }
    if let built = model.statuses.built(id) {
      place["builtAt"] = built.at.formatted(.iso8601)
      place["changedSinceBuilt"] = status.build == .changedSince
      if let repository = built.repository { place["builtInto"] = repository }
    }
    let lost = model.statuses.lostTune(id)
    if !lost.isEmpty { place["tuneNoLongerApplies"] = lost }
    return place
  }

  private func status() async -> JSON {
    var state: JSON = ["components": model.store?.items.values.filter(\.isComponent).count ?? 0]
    if let id = model.focus?.openItemId, let item = model.store?.items[id] { state["open"] = ["id": id, "title": item.title] }
    guard let importer = model.importer else { return state }
    do {
      let (file, page, frames) = try await importer.paper.artboards()
      let selected = try await importer.paper.selection()
      state["paper"] = ["connected": true, "file": file, "page": page, "frames": frames.map(\.name), "selected": selected.map(\.name)] as JSON
    } catch {
      state["paper"] = ["connected": false, "problem": error.localizedDescription] as JSON
    }
    return state
  }

  private func listComponents() async throws -> [JSON] {
    guard let store = model.store else { return [] }
    // PaperWatch pauses while this app is behind others, which is often when Claude Code asks.
    await model.paperWatch?.check()
    let onWall = Set(store.visibleIds)
    return store.items.values.filter(\.isComponent).sorted(by: { $0.id < $1.id }).map { item in
      var row: JSON = ["id": item.id, "title": item.title, "project": item.project, "onWall": onWall.contains(item.id)]
      row.merge(place(of: item.id)) { _, new in new }
      let note = model.statuses.note(item.id)
      if !note.isEmpty { row["note"] = note }
      return row
    }
  }

  private func importFromPaper(_ params: JSON) async throws -> [JSON] {
    guard let importer = model.importer else { return [] }
    let nodes: [PaperClient.Node]
    if let fileId = params["fileId"] as? String, let nodeId = params["nodeId"] as? String {
      nodes = [try await importer.paper.nodeInfo(fileId: fileId, nodeId: nodeId)]
    } else if let frame = (params["frame"] as? String)?.lowercased(), !frame.isEmpty {
      let frames = try await importer.paper.artboards().nodes
      let exact = frames.filter { $0.name.lowercased() == frame }
      nodes = exact.isEmpty ? frames.filter { $0.name.lowercased().contains(frame) } : exact
      guard !nodes.isEmpty else { throw ToolError("No frame on this Paper page is called \(frame). It has: \(frames.map(\.name).joined(separator: ", "))") }
    } else {
      nodes = try await importer.paper.selection()
      guard !nodes.isEmpty else { throw ToolError("Nothing is selected in Paper. Select a frame there, or pass its name as frame.") }
    }
    var imported: [JSON] = []
    for node in nodes {
      let record = try await importer.importNode(node)
      var row: JSON = ["id": record.id, "title": record.title]
      let lost = model.statuses.lostTune(record.id)
      if !lost.isEmpty { row["tuneNoLongerApplies"] = lost }
      imported.append(row)
    }
    return imported
  }

  private func openComponent(_ id: String) async throws -> JSON {
    guard let canvas = model.canvas, let focus = model.focus, let list = model.list else { throw ToolError("The wall is still starting.") }
    if focus.openItemId == id { return ["open": id] }
    NSApp.activate()
    model.window.makeKeyAndOrderFront(nil)
    if let item = model.store?.items[id], model.chrome?.state.filter.includes(item) == false { model.show(filter: .all) }
    if let item = model.store?.items[id], model.chrome?.state.refinement.matches(item, model.statuses.status(id)) == false { model.refine(Refinement()) }
    if list.isActive {
      list.select(id)
      return ["open": id]
    }
    guard let home = canvas.homeRect(for: id) else { throw ToolError("\(id) isn't on the wall.") }
    await focus.closeAndWait()
    canvas.bringIntoView(home)
    for _ in 0..<40 {
      if let tile = canvas.tile(forItem: id), !canvas.isFlying { focus.open(tile); return ["open": id] }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw ToolError("The wall couldn't reach \(id). Is the window showing?")
  }

  private func setNote(_ id: String, _ note: String) throws -> JSON {
    model.statuses.setNote(id, note)
    model.statuses.save()
    model.focus?.syncInspector()
    return ["id": id, "note": model.statuses.note(id)]
  }

  private func markBuilt(_ id: String, _ params: JSON) throws -> JSON {
    model.statuses.markBuilt(id, repository: params["repository"] as? String, summary: params["summary"] as? String, session: nil)
    return place(of: id)
  }

  /// Connects, then waits for the first tiles, so one call can say how it went and what to do next.
  private func connectProject(_ params: JSON) async throws -> JSON {
    guard let path = params["path"] as? String, !path.isEmpty else { throw ToolError("Pass path, the project's folder.") }
    let connection: ProjectSync.Connection
    do {
      connection = try await model.projects.connect(URL(filePath: NSString(string: path).expandingTildeInPath, directoryHint: .isDirectory))
    } catch let several as ProjectSync.SeveralApps {
      throw ToolError("\(several.localizedDescription) Ask the person which one, then pass its folder as path: \(several.apps.map(\.path).joined(separator: ", ")).")
    }
    let slug = connection.project.slug
    for _ in 0..<Self.connectPatience where !model.projects.isSettled(slug) { try await Task.sleep(for: .milliseconds(250)) }
    let settled = model.projects.isSettled(slug)
    guard let line = model.projects.state.lines.first(where: { $0.slug == slug }) else { throw ToolError("The project was disconnected while it started.") }
    var result: JSON = ["name": line.name, "project": slug, "root": line.root, "alreadyConnected": !connection.isNew, "onWall": line.shown]
    if let note = connection.note { result["note"] = note }
    if !line.skipped.isEmpty { result["notShown"] = line.skipped.map { ["title": $0.title, "file": $0.file, "reason": $0.reason] } }
    if let problem = line.problem {
      result["problem"] = problem
      result["next"] = "It's connected but not running. Fix the problem, then call connect_project again to retry."
    } else if !settled {
      result["next"] = "\(model.projects.waitingReason(slug) ?? "It's still starting.") Call list_projects in a moment to see how it's going."
    } else if line.shown == 0, line.skipped.isEmpty {
      result["next"] = "Moodboard found no components in it. It shows .tsx files that export a React component, and leaves out pages, layouts, tests, stories and server-only files."
    } else if line.shown == 0 {
      result["next"] = "None of its components could stand alone on the wall. notShown says why for each."
    } else {
      result["next"] = "\(line.shown) \(line.shown == 1 ? "component is" : "components are") on the wall in the Moodboard window. Saved edits show there at once."
    }
    return result
  }

  /// How many quarter seconds connect_project waits for a project to start and be measured.
  private static let connectPatience = 180

  private func listProjects() -> [JSON] {
    model.projects.state.lines.map { line in
      var row: JSON = ["name": line.name, "project": line.slug, "root": line.root, "onWall": line.shown, "notShown": line.skipped.map { ["id": $0.id, "file": $0.file, "reason": $0.reason] }]
      if let progress = line.progress { row["progress"] = progress }
      if let problem = line.problem { row["problem"] = problem }
      return row
    }
  }

  private func disconnectProject(_ params: JSON) throws -> JSON {
    let asked = params["project"] as? String ?? ""
    guard let project = ProjectCatalog.projects.first(where: { $0.slug == asked || $0.name == asked || $0.root == asked }) else { throw ToolError("No connected project is called \(asked). list_projects gives them.") }
    model.projects.disconnect(slug: project.slug)
    return ["disconnected": project.name]
  }

  private func setDials(_ id: String, _ values: JSON) async throws -> Any {
    guard !values.isEmpty else { throw ToolError("Pass values, such as {\"Type.17 px\": 20}.") }
    return try await model.dials.setChecked(id, values: values)
  }

}
