import AppKit

/// Web views off to the side that each load one page for a job, a few at a time. Plates and project measuring both use them.
/// Each web view holds a whole process, so they all go once none is loading anything.
final class BackstageWorkers<Job> {
  final class Worker {
    let web: StageWebView
    fileprivate(set) var job: Job?
    fileprivate var deadline: Task<Void, Never>?

    fileprivate init(web: StageWebView) {
      self.web = web
    }
  }

  /// What a job needs before its page can load.
  enum Start {
    case loaded
    /// Not yet, such as a project whose server isn't up. The job keeps its place.
    case later
    /// Never, such as a component that left the wall.
    case drop
  }

  private let host: WebHost
  private let backstage: NSView
  private let timeout: Duration?
  private var workers: [Worker] = []
  private(set) var queue: [Job] = []
  private static var concurrency: Int { 3 }

  /// Loads the job's page into the web view.
  var start: (Job, StageWebView) -> Start = { _, _ in .drop }
  /// A message from the page a worker is loading.
  var receive: (Worker, Job, PageMessage) -> Void = { _, _, _ in }
  /// The page didn't answer before the timeout.
  var timedOut: (Worker, Job) -> Void = { _, _ in }

  init(host: WebHost, backstage: NSView, timeout: Duration? = nil) {
    self.host = host
    self.backstage = backstage
    self.timeout = timeout
  }

  var running: [Job] { workers.compactMap(\.job) }
  var pending: Int { queue.count + running.count }

  /// `first` puts the job ahead of everything waiting.
  func enqueue(_ job: Job, first: Bool = false) {
    if first { queue.insert(job, at: 0) } else { queue.append(job) }
  }

  func removeQueued(where shouldRemove: (Job) -> Bool) {
    queue.removeAll(where: shouldRemove)
  }

  /// Starts what it can, and closes every web view once none is loading anything.
  func pump() {
    var waiting: [Job] = []
    while running.count < Self.concurrency, !queue.isEmpty {
      let job = queue.removeFirst()
      let worker = workers.first { $0.job == nil } ?? makeWorker()
      switch start(job, worker.web) {
      case .loaded: begin(job, on: worker)
      case .later: waiting.append(job)
      case .drop: break
      }
    }
    queue.insert(contentsOf: waiting, at: 0)
    if running.isEmpty {
      workers.forEach { $0.web.removeFromSuperview() }
      workers = []
    }
  }

  /// Frees a worker for the next job. The owner pumps once it has queued anything this job leads to.
  func release(_ worker: Worker) {
    worker.deadline?.cancel()
    worker.deadline = nil
    worker.job = nil
    worker.web.loadHTMLString("", baseURL: nil)
  }

  private func begin(_ job: Job, on worker: Worker) {
    worker.job = job
    guard let timeout else { return }
    worker.deadline = Task { [weak self, weak worker] in
      try? await Task.sleep(for: timeout)
      guard !Task.isCancelled, let self, let worker, let job = worker.job else { return }
      self.timedOut(worker, job)
    }
  }

  private func makeWorker() -> Worker {
    let worker = Worker(web: host.makeWebView())
    worker.web.onMessage = { [weak self, weak worker] message in
      guard let self, let worker, let job = worker.job else { return }
      self.receive(worker, job, message)
    }
    backstage.addSubview(worker.web)
    workers.append(worker)
    return worker
  }
}
