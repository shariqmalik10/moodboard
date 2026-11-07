import AppKit

/// Notices when a frame in Paper no longer matches what's on the wall. It only reads, and it looks only
/// while this app is in front, since nobody can act on the answer otherwise.
final class PaperWatch {
  private unowned let model: AppModel
  private var ticking: Task<Void, Never>?
  private var isChecking = false
  private var observers: [NSObjectProtocol] = []

  private static let interval = Duration.seconds(20)

  init(model: AppModel) {
    self.model = model
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.startTicking() }
    })
    observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.ticking?.cancel() }
    })
    if NSApp.isActive { startTicking() }
  }

  private func startTicking() {
    ticking?.cancel()
    ticking = Task { [weak self] in
      while !Task.isCancelled {
        await self?.check()
        try? await Task.sleep(for: Self.interval)
      }
    }
  }

  func check() async {
    guard !isChecking, let paper = model.importer?.paper else { return }
    isChecking = true
    defer { isChecking = false }
    var tokensByFile: [String: [ComponentRecord.Token]] = [:]
    for record in ComponentLibrary.all().values {
      do {
        let jsx = try await paper.jsx(fileId: record.source.fileId, nodeId: record.source.nodeId)
        if tokensByFile[record.source.fileId] == nil { tokensByFile[record.source.fileId] = try await paper.tokens(fileId: record.source.fileId) }
        let isSame = jsx == record.jsx && tokensByFile[record.source.fileId] == record.tokens
        model.statuses.setPaper(record.id, isSame ? .current : .changed)
      } catch PaperClient.Failure.notRunning {
        // Paper is closed, so nothing can be said about any design.
        for each in ComponentLibrary.all().keys { model.statuses.setPaper(each, nil) }
        return
      } catch PaperClient.Failure.tool(let message) where message.hasPrefix("Node not found") {
        model.statuses.setPaper(record.id, .missing)
      } catch {
        model.statuses.setPaper(record.id, nil)
      }
    }
  }
}
