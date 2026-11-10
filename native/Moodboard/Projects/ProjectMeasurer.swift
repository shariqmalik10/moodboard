import AppKit

/// Loads each new or changed project component off to the side, a few at a time, to learn its size and ground.
final class ProjectMeasurer {
  struct Job {
    var found: FoundComponent
    var slug: String
    var attempts = 0
  }

  enum Result {
    case measured(width: Double, height: Double, ground: String)
    case failed(String)
  }

  /// Called for each job once it's done, measured or not.
  var onResult: (Job, Result) -> Void = { _, _ in }

  private let workers: BackstageWorkers<Job>
  private var starting: Task<Void, Never>?
  private static let settle = Duration.milliseconds(350)

  init(host: WebHost, backstage: NSView) {
    workers = BackstageWorkers(host: host, backstage: backstage, timeout: .seconds(25))
    workers.start = { job, web in
      guard let url = ProjectCatalog.url(for: job.found.id, mode: .measure) else { return .later }
      web.frame = CGRect(x: 0, y: 0, width: 760, height: 600)
      web.load(URLRequest(url: url))
      return .loaded
    }
    workers.receive = { [unowned self] worker, job, message in
      switch message {
      case .measured(let id, let width, let height, let ground, let blank) where id == job.found.id:
        finish(worker, job, blank ? .failed("It draws nothing without real data, or it's only an icon.") : .measured(width: width, height: height, ground: ground))
      case .failed(let id, let reason) where id == job.found.id:
        finish(worker, job, .failed(reason))
      default:
        break
      }
    }
    workers.timedOut = { [unowned self] worker, job in finish(worker, job, .failed("It took too long to load.")) }
  }

  /// `first` puts the job ahead of the rest, for an edit to a component already on the wall.
  func enqueue(_ job: Job, first: Bool) {
    workers.removeQueued { $0.found.id == job.found.id }
    workers.enqueue(job, first: first)
  }

  func isQueued(_ id: String) -> Bool { workers.queue.contains { $0.found.id == id } }

  func removeQueued(where shouldRemove: (Job) -> Bool) { workers.removeQueued(where: shouldRemove) }

  /// Whether any of this project's components are waiting or loading.
  func isBusy(slug: String) -> Bool { (workers.queue + workers.running).contains { $0.slug == slug } }

  /// Waits for a run of saves to end, so a dragged dial measures once.
  func startSoon() {
    starting?.cancel()
    starting = Task {
      try? await Task.sleep(for: Self.settle)
      guard !Task.isCancelled else { return }
      workers.pump()
    }
  }

  private func finish(_ worker: BackstageWorkers<Job>.Worker, _ job: Job, _ result: Result) {
    workers.release(worker)
    if case .failed(let reason) = result, job.attempts < 2, Self.isViteReshuffle(reason) {
      var again = job
      again.attempts += 1
      enqueue(again, first: false)
    } else {
      onResult(job, result)
    }
    workers.pump()
  }

  /// Vite swaps its bundled packages when it meets a new one, and a page caught in the swap fails once.
  private static func isViteReshuffle(_ reason: String) -> Bool {
    reason.contains("dynamically imported") || reason.contains("Importing a module script")
  }
}
