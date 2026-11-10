import AppKit
import WebKit

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

/// Keeps the wall and connected Next.js projects in step. A saved edit reaches a running tile through the
/// project's own hot reload, and this keeps the rest current: which tiles exist, their size, and their plates.
/// Going the other way, a moved dial becomes an edit to the source file.
final class ProjectSync {
  private struct Job {
    var found: FoundComponent
    var slug: String
    var attempts = 0
  }

  private final class Measurer {
    let web: StageWebView
    var job: Job?
    var deadline: Task<Void, Never>?

    init(web: StageWebView) {
      self.web = web
    }
  }

  let state = ProjectsModel()
  private unowned let app: AppModel
  private var servers: [String: ProjectServer] = [:]
  private var restarts: [String: Int] = [:]
  private var progress: [String: (done: Int, total: Int)] = [:]
  private var problems: [String: String] = [:]
  /// A start this slow is usually macOS waiting for the person to allow the folder.
  private var slowToStart = Set<String>()
  private static let patience = Duration.seconds(6)
  /// Filled at connect, so the wall turns to the new project once it has something to show.
  private var revealing = Set<String>()
  /// Projects whose server has said which components it found, since it started.
  private var scanned = Set<String>()

  private var queue: [Job] = []
  private var measurers: [Measurer] = []
  private var starting: Task<Void, Never>?
  private static let concurrency = 3
  private static let settle = Duration.milliseconds(350)

  private var latestHash: [String: String] = [:]

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
    servers.values.forEach { $0.stop() }
    servers = [:]
  }

  /// Opens where the last project was, since the next one is usually beside it.
  func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Connect"
    panel.message = "Choose a Next.js app, a folder inside one, or a monorepo. Its components join the wall, and moving a dial edits their source files."
    if let last = ProjectCatalog.projects.last { panel.directoryURL = URL(filePath: last.root, directoryHint: .isDirectory).deletingLastPathComponent() }
    panel.beginSheetModal(for: app.window) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      MainActor.assumeIsolated { self?.connectAsked(url) }
    }
  }

  /// Connects a folder the person picked or dropped, and answers in a sheet when it can't.
  func connectAsked(_ url: URL) {
    Task {
      do {
        let connection = try await connect(url)
        if !connection.isNew {
          app.show(.wall, filter: .project(connection.project.slug))
          app.chrome?.say("\(connection.project.name) is already connected.")
        } else if let note = connection.note {
          app.chrome?.say(note)
        }
      } catch let several as SeveralApps {
        pickApp(several)
      } catch {
        explain(error.localizedDescription)
      }
    }
  }

  private func pickApp(_ several: SeveralApps) {
    let alert = NSAlert()
    alert.messageText = "Which app should join the wall?"
    alert.informativeText = "\(several.folder.lastPathComponent) holds \(several.apps.count) Next.js apps. Connect one now, and the others the same way later."
    let shown = Array(several.apps.prefix(3))
    for app in shown { alert.addButton(withTitle: several.label(app)) }
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: app.window) { [weak self] response in
      let at = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
      guard at >= 0, at < shown.count else { return }
      MainActor.assumeIsolated { self?.connectAsked(shown[at]) }
    }
  }

  private func explain(_ problem: String) {
    let alert = NSAlert()
    alert.messageText = "This folder can't join the wall"
    alert.informativeText = problem
    alert.addButton(withTitle: "Choose Another…")
    alert.addButton(withTitle: "OK")
    alert.beginSheetModal(for: app.window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      MainActor.assumeIsolated { self?.choose() }
    }
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

  /// A folder holding several apps, so the person has to say which.
  struct SeveralApps: LocalizedError {
    var folder: URL
    var apps: [URL]

    func label(_ app: URL) -> String { String(app.path.dropFirst(folder.standardizedFileURL.resolvingSymlinksInPath().path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    var errorDescription: String? { "\(folder.lastPathComponent) holds several Next.js apps: \(apps.map(label).joined(separator: ", ")). Connect one of them by its folder." }
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
      if problems[known.slug] != nil {
        restarts[known.slug] = 0
        startServer(known)
        refreshLines()
      }
      return Connection(project: known, isNew: false, note: note)
    }
    if let problem = NodeCheck.problem(await NodeCheck.check()) { throw ToolError(problem) }
    let manifest = ProjectFinder.manifest(at: root)
    let name = manifest?.name ?? root.lastPathComponent
    let wanted = name.lowercased().replacing(/[^a-z0-9]+/, with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let project = ConnectedProject(root: path, name: name, slug: ProjectCatalog.freeSlug(wanted.isEmpty ? "project" : wanted, root: path))
    ProjectCatalog.add(project)
    revealing.insert(project.slug)
    startServer(project)
    refreshLines()
    app.chrome?.say("Starting \(name). Its components join the wall in a few seconds.")
    return Connection(project: project, isNew: true, note: note)
  }

  /// Whether a project has started and its components have been measured, or has stopped with a problem.
  func isSettled(_ slug: String) -> Bool {
    if problems[slug] != nil { return true }
    return scanned.contains(slug) && progress[slug] == nil && !queue.contains { $0.slug == slug } && !measurers.contains { $0.job?.slug == slug }
  }

  /// Said while a project is still on its way, such as macOS waiting on the person to allow its folder.
  func waitingReason(_ slug: String) -> String? {
    if slowToStart.contains(slug) { return "macOS may be asking whether Moodboard can read this folder. Ask the person to choose Allow." }
    return state.lines.first { $0.slug == slug }?.progress
  }

  func disconnect(slug: String) {
    guard let project = ProjectCatalog.project(slug: slug) else { return }
    Task {
      if let open = app.focus?.openItemId, ProjectCatalog.project(of: open)?.slug == slug { await app.focus?.closeAndWait() }
      servers[slug]?.stop()
      servers[slug] = nil
      queue.removeAll { $0.slug == slug }
      progress[slug] = nil
      problems[slug] = nil
      scanned.remove(slug)
      let ids = project.components.map(\.id)
      ProjectCatalog.remove(slug: slug)
      for id in ids {
        DialState.write(id, nil)
        app.statuses.forget(id)
        forget(id)
      }
      app.store?.drop(Set(ids))
      refreshLines()
    }
  }

  private func forget(_ id: String) {
    latestHash[id] = nil
    app.dials.forget(id)
  }

  private func startServer(_ project: ConnectedProject) {
    let root = URL(filePath: project.root, directoryHint: .isDirectory)
    let slug = project.slug
    let server = ProjectServer(root: root, slug: slug)
    server.onEvent = { [weak self] event in self?.receive(event, slug: slug) }
    servers[slug] = server
    problems[slug] = nil
    slowToStart.remove(slug)
    Task {
      let problem = await Task.detached(operation: { Self.problem(with: root) }).value
      guard servers[slug] === server else { return }
      if let problem {
        servers[slug] = nil
        problems[slug] = problem
        refreshLines()
        return
      }
      server.start()
    }
    Task {
      try? await Task.sleep(for: Self.patience)
      guard servers[slug] === server, server.port == nil else { return }
      slowToStart.insert(slug)
      refreshLines()
    }
  }

  private func receive(_ event: ProjectServer.Event, slug: String) {
    switch event {
    case .listening(let port, _):
      restarts[slug] = 0
      slowToStart.remove(slug)
      ProjectCatalog.setPort(port, slug: slug)
      wakeStages(slug: slug)
    case .components(let items, let bySelf):
      arrived(items, slug: slug, bySelf: bySelf)
      scanned.insert(slug)
    case .stopped(let reason):
      scanned.remove(slug)
      ProjectCatalog.setPort(nil, slug: slug)
      servers[slug] = nil
      slowToStart.remove(slug)
      let tries = restarts[slug] ?? 0
      if tries < 1, let project = ProjectCatalog.project(slug: slug) {
        restarts[slug] = tries + 1
        startServer(project)
      } else {
        problems[slug] = reason
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
    var added = 0
    var edited: [String] = []
    for item in items {
      // A quick undo lands back on the hash the row still holds, and it's an edit all the same.
      let wasDifferent = latestHash[item.id].map { $0 != item.hash } ?? false
      latestHash[item.id] = item.hash
      if let row = rows[item.id] {
        if row.hash != item.hash || wasDifferent { edited.append(item.id) }
        if row.hash != item.hash || queue.contains(where: { $0.found.id == item.id }) { enqueue(Job(found: item, slug: slug), first: true) }
      } else if skipped[item.id]?.hash != item.hash {
        enqueue(Job(found: item, slug: slug), first: false)
        added += 1
      }
    }
    if added > 0 {
      let before = progress[slug]
      progress[slug] = (done: before?.done ?? 0, total: (before?.total ?? 0) + added)
    }

    let present = Set(items.map(\.id))
    let gone = rows.keys.filter { !present.contains($0) }
    if !gone.isEmpty { drop(Set(gone), slug: slug) }
    queue.removeAll { $0.slug == slug && !present.contains($0.found.id) }
    if skipped.keys.contains(where: { !present.contains($0) }) {
      ProjectCatalog.edit(slug: slug) { $0.skipped.removeAll { !present.contains($0.id) } }
    }

    if !bySelf, let open = app.focus?.openItemId, edited.contains(open) { app.focus?.reloadPanel() }
    // An edit elsewhere may have taken back what a dial wrote, and the mark on the tile should say so.
    if !bySelf {
      for id in edited where app.statuses.status(id).written > 0 { Task { _ = await app.dials.record(id) } }
    }
    startSoon()
    refreshLines()
  }

  private func drop(_ ids: Set<String>, slug: String) {
    Task {
      if let open = app.focus?.openItemId, ids.contains(open) { await app.focus?.closeAndWait() }
      ProjectCatalog.edit(slug: slug) { $0.components.removeAll { ids.contains($0.id) } }
      for id in ids {
        DialState.write(id, nil)
        app.statuses.forget(id)
        forget(id)
      }
      app.store?.drop(ids)
      refreshLines()
    }
  }

  private func enqueue(_ job: Job, first: Bool) {
    queue.removeAll { $0.found.id == job.found.id }
    if first { queue.insert(job, at: 0) } else { queue.append(job) }
  }

  /// Waits for a run of saves to end, so a dragged dial measures once.
  private func startSoon() {
    starting?.cancel()
    starting = Task {
      try? await Task.sleep(for: Self.settle)
      guard !Task.isCancelled else { return }
      pump()
    }
  }

  private func pump() {
    while measurers.filter({ $0.job != nil }).count < Self.concurrency, let at = queue.firstIndex(where: { ProjectCatalog.url(for: $0.found.id, mode: .measure) != nil }) {
      let job = queue.remove(at: at)
      guard let url = ProjectCatalog.url(for: job.found.id, mode: .measure) else { continue }
      let measurer = measurers.first { $0.job == nil } ?? makeMeasurer()
      measurer.job = job
      measurer.web.load(URLRequest(url: url))
      measurer.deadline = Task { [weak self, weak measurer] in
        try? await Task.sleep(for: .seconds(25))
        guard !Task.isCancelled, let self, let measurer else { return }
        self.failed(measurer, reason: "It took too long to load.")
      }
    }
    if queue.isEmpty, !measurers.contains(where: { $0.job != nil }) {
      // Each web view holds a whole process, so they don't stay around.
      measurers.forEach { $0.web.removeFromSuperview() }
      measurers = []
    }
  }

  private func makeMeasurer() -> Measurer {
    let measurer = Measurer(web: app.host.makeWebView(frame: CGRect(x: 0, y: 0, width: 760, height: 600)))
    app.root.backstage.addSubview(measurer.web)
    measurers.append(measurer)
    return measurer
  }

  func owns(_ web: WKWebView?) -> Bool { measurers.contains { $0.web === web } }

  func handle(_ web: WKWebView?, message: PageMessage) {
    guard let measurer = measurers.first(where: { $0.web === web }), let job = measurer.job else { return }
    switch message {
    case .measured(let id, let width, let height, let ground, let blank) where id == job.found.id:
      measured(measurer, job, width: width, height: height, ground: ground, blank: blank)
    case .failed(let id, let reason) where id == job.found.id:
      failed(measurer, reason: reason)
    default:
      break
    }
  }

  private func finish(_ measurer: Measurer) {
    measurer.deadline?.cancel()
    measurer.job = nil
    measurer.web.loadHTMLString("", baseURL: nil)
  }

  private func failed(_ measurer: Measurer, reason: String) {
    guard var job = measurer.job else { return }
    finish(measurer)
    // Vite swaps its bundled packages when it meets a new one, and a page caught in the swap fails once.
    if job.attempts < 2, reason.contains("dynamically imported") || reason.contains("Importing a module script") {
      job.attempts += 1
      enqueue(job, first: false)
    } else {
      skip(job, reason: reason)
    }
    pump()
  }

  private func skip(_ job: Job, reason: String) {
    let id = job.found.id
    // A tile already on the wall keeps its last good look while its file is mid-edit.
    if ProjectCatalog.contains(id) { return }
    tick(job.slug)
    ProjectCatalog.edit(slug: job.slug) { project in
      project.skipped.removeAll { $0.id == id }
      project.skipped.append(SkippedComponent(id: id, title: job.found.title, file: job.found.file, hash: job.found.hash, reason: reason))
    }
    refreshLines()
  }

  private func tick(_ slug: String) {
    guard let current = progress[slug] else { return }
    let done = current.done + 1
    progress[slug] = done >= current.total ? nil : (done: done, total: current.total)
    if done >= current.total, let project = ProjectCatalog.project(slug: slug) {
      let hidden = project.skipped.isEmpty ? "" : " \(project.skipped.count) can't stand alone. The connect panel says why."
      app.chrome?.say("\(project.name) has \(project.components.count) on the wall.\(hidden)")
    }
  }

  private func measured(_ measurer: Measurer, _ job: Job, width: Double, height: Double, ground: String, blank: Bool) {
    finish(measurer)
    defer { pump() }
    if blank {
      skip(job, reason: "It draws nothing without real data, or it's only an icon.")
      return
    }
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
      tick(job.slug)
    } else {
      if existing?.viewport != row.viewport || existing?.ground != row.ground { app.store?.refresh() }
      app.plates?.invalidate(id)
    }
    refreshLines()
  }

  /// One more on the wall. While a whole project comes in, tiles gather at the ends of the columns. Later, one new
  /// component arrives where the person is looking.
  private func arrive(_ row: ProjectComponent, slug: String) {
    guard let store = app.store else { return }
    if store.isHidden(row.id) { return }
    if progress[slug] != nil {
      store.add(row.id)
      if revealing.remove(slug) != nil { app.show(.wall, filter: .project(slug)) }
      app.plates?.request(row.id)
    } else {
      let slot = app.canvas?.slotNearCenter()
      store.insert(id: row.id, column: slot?.column ?? 0, index: slot?.index ?? 0)
      app.plates?.request(row.id, first: true)
      app.canvas?.welcome(row.id)
      app.chrome?.say("\(row.title) joined from \(ProjectCatalog.name(of: slug) ?? slug).")
    }
  }

  private func refreshLines() {
    state.lines = ProjectCatalog.projects.map { project in
      let progress = progress[project.slug].map { "Adding \($0.done) of \($0.total)…" }
      let waking = servers[project.slug] != nil && servers[project.slug]?.port == nil ? (slowToStart.contains(project.slug) ? "Still starting. If macOS asks about this folder, choose Allow." : "Starting…") : nil
      return ProjectLine(slug: project.slug, name: project.name, root: project.root, shown: project.components.count, skipped: project.skipped, progress: progress ?? waking, problem: problems[project.slug])
    }
  }

  /// The running server for a component's project, if it's up.
  func server(for id: String) -> ProjectServer? {
    ProjectCatalog.project(of: id).flatMap { servers[$0.slug] }
  }
}
