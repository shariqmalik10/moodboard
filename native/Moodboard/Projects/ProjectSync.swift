import AppKit

/// One connected project as the panel shows it.
struct ProjectLine: Identifiable, Equatable {
  var id: String { slug }
  var slug: String
  var name: String
  var root: String
  var shown: Int
  var skipped: [SkippedComponent]
  var progress: String?
  var problem: String?
}

@Observable
final class ProjectsModel {
  var lines: [ProjectLine] = []
  var isChoosing = false
}

/// One connected project's server, from the moment it's asked to start.
private struct ProjectRun {
  enum Phase {
    /// Checking the folder, then waiting for the server to say its port. It's `slow` once that has taken long
    /// enough that macOS is probably waiting for the person to allow the folder.
    case starting(ProjectServer, slow: Bool)
    /// It's `scanned` once the server has said which components it found.
    case listening(ProjectServer, scanned: Bool)
    case stopped(problem: String)
  }

  var phase: Phase
  var restarts = 0
  /// New components on their way to the wall: found by the server, and not yet measured or skipped.
  var incoming: Set<String> = []
  /// How many have landed since `incoming` was last empty.
  var landed = 0
  /// Set at connect, so the wall turns to the new project once it has something to show.
  var revealing = false

  var server: ProjectServer? {
    switch phase {
    case .starting(let server, _), .listening(let server, _): server
    case .stopped: nil
    }
  }

  var problem: String? {
    if case .stopped(let problem) = phase { problem } else { nil }
  }
}

/// Keeps the wall and connected Next.js projects in step. A saved edit reaches a running tile through the
/// project's own hot reload, and this keeps the rest current: which tiles exist, their size, and their plates.
/// Going the other way, a moved dial becomes an edit to the source file, through `Dials`.
final class ProjectSync {
  let state = ProjectsModel()
  private unowned let app: AppModel
  private var runs: [String: ProjectRun] = [:]
  private static let patience = Duration.seconds(6)
  private var latestHash: [String: String] = [:]

  private lazy var measurer: ProjectMeasurer = {
    let measurer = ProjectMeasurer(host: app.host, backstage: app.root.backstage)
    measurer.onResult = { [unowned self] job, result in
      switch result {
      case .measured(let width, let height, let ground): measured(job, width: width, height: height, ground: ground)
      case .failed(let reason): skip(job, reason: reason)
      }
    }
    return measurer
  }()

  init(app: AppModel) {
    self.app = app
    refreshLines()
  }

  // MARK: Connecting

  func startAll() {
    for project in ProjectCatalog.projects { startServer(project) }
    refreshLines()
  }

  func stopAll() {
    runs.values.forEach { $0.server?.stop() }
    runs = [:]
  }

  /// Checks a connected folder before its server starts again, so a moved or emptied project gets a plain answer.
  /// The first read of a folder under Documents, Desktop or Downloads waits on macOS's prompt, so this never runs on the main thread.
  nonisolated static func problem(with root: URL) -> String? {
    if case .problem(let problem) = ProjectFinder.find(root) { return problem }
    return nil
  }

  struct Connection {
    var project: ConnectedProject
    var isNew: Bool
    /// Says what was connected when it isn't the folder given, or isn't Next.js.
    var note: String?
  }

  /// Connects the Next.js app at this folder, inside it, or holding it. Connecting one again changes nothing.
  @discardableResult
  func connect(_ url: URL) async throws -> Connection {
    let root: URL
    let note: String?
    switch await Task.detached(operation: { ProjectFinder.find(url) }).value {
    case .problem(let problem): throw ToolError(problem)
    case .several(let apps): throw SeveralApps(folder: url, apps: apps)
    case .project(let found, let said): (root, note) = (found, said)
    }
    let path = root.path
    if let known = ProjectCatalog.projects.first(where: { URL(filePath: $0.root).resolvingSymlinksInPath().path == path }) {
      // Connecting again after fixing what stopped it is how a person retries.
      if runs[known.slug]?.problem != nil {
        runs[known.slug]?.restarts = 0
        startServer(known)
        refreshLines()
      }
      return Connection(project: known, isNew: false, note: note)
    }
    if let problem = NodeCheck.problem(await NodeCheck.check()) { throw ToolError(problem) }
    let name = ProjectFinder.manifest(at: root)?.name ?? root.lastPathComponent
    let project = ConnectedProject(root: path, name: name, slug: ProjectCatalog.slug(named: name, root: path))
    ProjectCatalog.add(project)
    startServer(project)
    runs[project.slug]?.revealing = true
    refreshLines()
    app.chrome?.say("Starting \(name). Its components join the wall in a few seconds.")
    return Connection(project: project, isNew: true, note: note)
  }

  /// Whether a project has started and its components have been measured, or has stopped with a problem.
  func isSettled(_ slug: String) -> Bool {
    guard let run = runs[slug] else { return false }
    if run.problem != nil { return true }
    guard case .listening(_, scanned: true) = run.phase else { return false }
    return run.incoming.isEmpty && !measurer.isBusy(slug: slug)
  }

  /// Said while a project is still on its way, such as macOS waiting on the person to allow its folder.
  func waitingReason(_ slug: String) -> String? {
    if case .starting(_, slow: true)? = runs[slug]?.phase { return "macOS may be asking whether Moodboard can read this folder. Ask the person to choose Allow." }
    return state.lines.first { $0.slug == slug }?.progress
  }

  func disconnect(slug: String) {
    guard let project = ProjectCatalog.project(slug: slug) else { return }
    let ids = Set(project.components.map(\.id))
    Task {
      await closeIfOpen(ids)
      runs.removeValue(forKey: slug)?.server?.stop()
      measurer.removeQueued { $0.slug == slug }
      ProjectCatalog.remove(slug: slug)
      removeComponents(ids)
    }
  }

  /// The running server for a component's project, if it's up.
  func server(for id: String) -> ProjectServer? {
    ProjectCatalog.project(of: id).flatMap { runs[$0.slug]?.server }
  }

  private func startServer(_ project: ConnectedProject) {
    let root = URL(filePath: project.root, directoryHint: .isDirectory)
    let slug = project.slug
    let server = ProjectServer(root: root, slug: slug)
    server.onEvent = { [weak self, unowned server] event in self?.receive(event, from: server, slug: slug) }
    runs[slug, default: ProjectRun(phase: .starting(server, slow: false))].phase = .starting(server, slow: false)
    Task {
      let problem = await Task.detached(operation: { Self.problem(with: root) }).value
      guard runs[slug]?.server === server else { return }
      if let problem {
        runs[slug]?.phase = .stopped(problem: problem)
        refreshLines()
        return
      }
      server.start()
    }
    Task {
      try? await Task.sleep(for: Self.patience)
      guard case .starting(let current, slow: false)? = runs[slug]?.phase, current === server else { return }
      runs[slug]?.phase = .starting(server, slow: true)
      refreshLines()
    }
  }

  private func receive(_ event: ProjectServer.Event, from server: ProjectServer, slug: String) {
    guard runs[slug]?.server === server else { return }
    switch event {
    case .listening(let port, _):
      runs[slug]?.restarts = 0
      runs[slug]?.phase = .listening(server, scanned: false)
      ProjectCatalog.setPort(port, slug: slug)
      wakeStages(slug: slug)
    case .components(let items, let bySelf):
      arrived(items, slug: slug, bySelf: bySelf)
      runs[slug]?.phase = .listening(server, scanned: true)
    case .stopped(let reason):
      ProjectCatalog.setPort(nil, slug: slug)
      let restarts = runs[slug]?.restarts ?? 0
      if restarts < 1, let project = ProjectCatalog.project(slug: slug) {
        runs[slug]?.restarts = restarts + 1
        startServer(project)
      } else {
        runs[slug]?.phase = .stopped(problem: reason)
      }
    }
    refreshLines()
  }

  /// Stages and plates asked for this project before its server was up, so they ask again.
  private func wakeStages(slug: String) {
    for stage in app.pool.all {
      if let id = stage.itemId, id.hasPrefix("project/\(slug)/") { stage.reload() }
    }
    for component in ProjectCatalog.project(slug: slug)?.components ?? [] { app.plates?.request(component.id) }
    if let open = app.focus?.openItemId, open.hasPrefix("project/\(slug)/") { app.focus?.reloadPanel() }
  }

  // MARK: What's on the wall

  private func arrived(_ items: [FoundComponent], slug: String, bySelf: Bool) {
    guard let project = ProjectCatalog.project(slug: slug) else { return }
    let rows = Dictionary(project.components.map { ($0.id, $0) }) { first, _ in first }
    let skipped = Dictionary(project.skipped.map { ($0.id, $0) }) { first, _ in first }
    var edited: [String] = []
    for item in items {
      // A quick undo lands back on the hash the row still holds, and it's an edit all the same.
      let wasDifferent = latestHash[item.id].map { $0 != item.hash } ?? false
      latestHash[item.id] = item.hash
      if let row = rows[item.id] {
        if row.hash != item.hash || wasDifferent { edited.append(item.id) }
        if row.hash != item.hash || measurer.isQueued(item.id) { measurer.enqueue(.init(found: item, slug: slug), first: true) }
      } else if skipped[item.id]?.hash != item.hash {
        measurer.enqueue(.init(found: item, slug: slug), first: false)
        runs[slug]?.incoming.insert(item.id)
      }
    }

    let present = Set(items.map(\.id))
    runs[slug]?.incoming.formIntersection(present)
    finishAdding(slug)
    let gone = rows.keys.filter { !present.contains($0) }
    if !gone.isEmpty { drop(Set(gone), slug: slug) }
    measurer.removeQueued { $0.slug == slug && !present.contains($0.found.id) }
    if skipped.keys.contains(where: { !present.contains($0) }) {
      ProjectCatalog.edit(slug: slug) { $0.skipped.removeAll { !present.contains($0.id) } }
    }

    if !bySelf, let open = app.focus?.openItemId, edited.contains(open) { app.focus?.reloadPanel() }
    // An edit elsewhere may have taken back what a dial wrote, and the mark on the tile should say so.
    if !bySelf {
      for id in edited where app.statuses.status(id).written > 0 { Task { _ = await app.dials.record(id) } }
    }
    measurer.startSoon()
    refreshLines()
  }

  private func drop(_ ids: Set<String>, slug: String) {
    Task {
      await closeIfOpen(ids)
      ProjectCatalog.edit(slug: slug) { $0.components.removeAll { ids.contains($0.id) } }
      removeComponents(ids)
    }
  }

  private func closeIfOpen(_ ids: Set<String>) async {
    if let open = app.focus?.openItemId, ids.contains(open) { await app.focus?.closeAndWait() }
  }

  /// Clears what the app kept for components that left the wall.
  private func removeComponents(_ ids: Set<String>) {
    for id in ids {
      DialState.write(id, nil)
      app.statuses.forget(id)
      app.dials.forget(id)
      latestHash[id] = nil
    }
    app.store?.drop(ids)
    refreshLines()
  }

  private func skip(_ job: ProjectMeasurer.Job, reason: String) {
    let id = job.found.id
    // A tile already on the wall keeps its last good look while its file is mid-edit.
    if ProjectCatalog.contains(id) { return }
    ProjectCatalog.edit(slug: job.slug) { project in
      project.skipped.removeAll { $0.id == id }
      project.skipped.append(SkippedComponent(id: id, title: job.found.title, file: job.found.file, hash: job.found.hash, reason: reason))
    }
    land(id, slug: job.slug)
    refreshLines()
  }

  private func land(_ id: String, slug: String) {
    guard runs[slug]?.incoming.remove(id) != nil else { return }
    runs[slug]?.landed += 1
    finishAdding(slug)
  }

  /// Says how the wall stands once the last new component has landed.
  private func finishAdding(_ slug: String) {
    guard let run = runs[slug], run.incoming.isEmpty, run.landed > 0 else { return }
    runs[slug]?.landed = 0
    guard let project = ProjectCatalog.project(slug: slug) else { return }
    let hidden = project.skipped.isEmpty ? "" : " \(project.skipped.count) can't stand alone. The connect panel says why."
    app.chrome?.say("\(project.name) has \(project.components.count) on the wall.\(hidden)")
  }

  private func measured(_ job: ProjectMeasurer.Job, width: Double, height: Double, ground: String) {
    let id = job.found.id
    let row = ProjectComponent(id: id, title: job.found.title, file: job.found.file, exportName: job.found.exportName, hash: job.found.hash, viewport: ProjectSizing.viewport(width: width, height: height), ground: ground, dark: ProjectSizing.isDark(hex: ground))
    let existing = ProjectCatalog.row(id)
    ProjectCatalog.edit(slug: job.slug) { project in
      project.skipped.removeAll { $0.id == id }
      if let at = project.components.firstIndex(where: { $0.id == id }) {
        project.components[at] = row
      } else {
        project.components.append(row)
      }
    }
    if existing == nil {
      arrive(row, slug: job.slug)
      land(id, slug: job.slug)
    } else {
      if existing?.viewport != row.viewport || existing?.ground != row.ground { app.store?.refresh() }
      app.plates?.invalidate(id)
    }
    refreshLines()
  }

  /// One more on the wall. While a whole project comes in, tiles gather at the ends of the columns. Later, one new
  /// component arrives where the person is looking.
  private func arrive(_ row: ProjectComponent, slug: String) {
    guard let store = app.store, let canvas = app.canvas else { return }
    if store.isHidden(row.id) { return }
    if runs[slug]?.incoming.isEmpty == false {
      store.add(row.id)
      if runs[slug]?.revealing == true {
        runs[slug]?.revealing = false
        app.show(.wall, filter: .project(slug))
      }
      app.plates?.request(row.id)
    } else {
      let slot = canvas.slotNearCenter()
      canvas.welcome(row.id) { store.insert(id: row.id, column: slot.column, index: slot.index) }
      app.plates?.request(row.id, first: true)
      app.chrome?.say("\(row.title) joined from \(ProjectCatalog.name(of: slug) ?? slug).")
    }
  }

  private func refreshLines() {
    state.lines = ProjectCatalog.projects.map { project in
      let run = runs[project.slug]
      let adding = run.flatMap { $0.incoming.isEmpty ? nil : "Adding \($0.landed) of \($0.landed + $0.incoming.count)…" }
      var waking: String?
      if case .starting(_, let slow)? = run?.phase { waking = slow ? "Still starting. If macOS asks about this folder, choose Allow." : "Starting…" }
      return ProjectLine(slug: project.slug, name: project.name, root: project.root, shown: project.components.count, skipped: project.skipped, progress: adding ?? waking, problem: run?.problem)
    }
  }
}
