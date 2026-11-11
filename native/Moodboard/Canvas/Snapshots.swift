import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// A picture of a component as it draws now, from its saved source and the person's tune, for Claude Code to look at.
/// It's taken backstage at the component's own size, so it never moves the wall or takes focus.
final class Snapshots {
  private let workers: BackstageWorkers<UUID>
  private var jobs: [UUID: Job] = [:]

  private struct Job {
    let id: String
    let viewport: Size
    let crop: Crop
    let reply: CheckedContinuation<Data, Error>
  }

  init(host: WebHost, backstage: NSView) {
    workers = BackstageWorkers(host: host, backstage: backstage, timeout: .seconds(20))
    workers.start = { [unowned self] ticket, web in
      guard let job = jobs[ticket] else { return .drop }
      web.frame = CGRect(x: 0, y: 0, width: job.viewport.w, height: job.viewport.h)
      web.load(URLRequest(url: LiveStage.url(for: job.id, mode: .still)))
      return .loaded
    }
    workers.receive = { [unowned self] worker, ticket, message in
      switch message {
      case .ready: Task { await self.capture(worker, ticket) }
      case .failed(_, let reason): finish(worker, ticket, .failure(ToolError("It didn't draw. \(reason)")))
      default: break
      }
    }
    workers.timedOut = { [unowned self] worker, ticket in
      finish(worker, ticket, .failure(ToolError("It didn't finish drawing within 20 seconds.")))
    }
  }

  /// A PNG of the component, at the window's pixel density.
  func picture(of item: Item) async throws -> Data {
    guard case .component(let viewport, let crop) = item.body else { throw ToolError("\(item.title) is a picture, not a component.") }
    let ticket = UUID()
    return try await withCheckedThrowingContinuation { reply in
      jobs[ticket] = Job(id: item.id, viewport: viewport, crop: crop, reply: reply)
      workers.enqueue(ticket, first: true)
      workers.pump()
    }
  }

  private func capture(_ worker: BackstageWorkers<UUID>.Worker, _ ticket: UUID) async {
    guard let job = jobs[ticket] else { return }
    do {
      // The same pause the wall's stills take, for fonts and images that settle after `ready`.
      try await Task.sleep(for: .milliseconds(160))
      let configuration = WKSnapshotConfiguration()
      configuration.rect = CGRect(x: job.crop.x, y: job.crop.y, width: job.crop.w, height: job.crop.h)
      let image = try await worker.web.takeSnapshot(configuration: configuration)
      guard let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ToolError("The picture came back empty.") }
      finish(worker, ticket, .success(try png(picture)))
    } catch {
      finish(worker, ticket, .failure(error))
    }
  }

  private func finish(_ worker: BackstageWorkers<UUID>.Worker, _ ticket: UUID, _ result: Result<Data, Error>) {
    guard let job = jobs.removeValue(forKey: ticket) else { return }
    workers.release(worker)
    workers.pump()
    job.reply.resume(with: result)
  }

  private func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ToolError("The picture couldn't be encoded.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ToolError("The picture couldn't be encoded.") }
    return data as Data
  }
}
