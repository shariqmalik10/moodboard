import AppKit

/// Finds a newer release on GitHub, downloads it in the background, and swaps it in when Moodboard quits.
final class Updater {
  struct Version: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
      let pieces = text.trimmingPrefix("v").split(separator: ".")
      let parts = pieces.compactMap { Int($0) }
      guard !parts.isEmpty, parts.count == pieces.count else { return nil }
      self.parts = parts
    }

    /// 0.2 and 0.2.0 are the same version.
    private func padded(to count: Int) -> [Int] { parts + Array(repeating: 0, count: count - parts.count) }
    static func < (a: Version, b: Version) -> Bool {
      let count = max(a.parts.count, b.parts.count)
      return a.padded(to: count).lexicographicallyPrecedes(b.padded(to: count))
    }
    static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static let running = Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
  }

  struct Release: Equatable {
    let version: Version
    let zip: URL
    let page: URL
    let notes: String

    /// Reads GitHub's release JSON. A release without a Moodboard.zip has nothing to install.
    init?(json: Data) {
      struct Payload: Decodable {
        struct Asset: Decodable {
          let name: String
          let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]
      }
      guard let payload = try? JSONDecoder().decode(Payload.self, from: json),
        let version = Version(payload.tag_name),
        let zip = payload.assets.first(where: { $0.name == "Moodboard.zip" })?.browser_download_url
      else { return nil }
      self.version = version
      self.zip = zip
      self.page = payload.html_url
      self.notes = payload.body ?? ""
    }

    /// Asks GitHub for a release: `latest`, or `tags/v0.2.0` for one version.
    static func fetch(_ path: String) async throws -> Release {
      var request = URLRequest(url: Updater.feed.appending(path: path))
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("GitHub didn't answer. Try again later.") }
      guard let release = Release(json: data) else { throw Failure("That release has no Moodboard.zip.") }
      return release
    }
  }

  private enum Phase {
    case idle, checking, installing
    case ready(Release, app: URL)
  }

  struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
  }

  // MoodboardUpdateFeed points a build at another feed, so an update can be tried before it is published.
  private static let feed = URL(string: UserDefaults.standard.string(forKey: "MoodboardUpdateFeed") ?? "https://api.github.com/repos/shariqmalik10/moodboard/releases")!

  /// Waits for Moodboard to quit, then puts the new app where the old one was. The old one comes back if the move fails.
  private static let swap = """
    pid=$1 new=$2 dest=$3 reopen=$4
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    old="$dest.old"
    rm -rf "$old"
    mv "$dest" "$old" || exit 1
    if ! mv "$new" "$dest"; then mv "$old" "$dest"; exit 1; fi
    rm -rf "$old"
    [ "$reopen" = 1 ] && open "$dest"
    exit 0
    """

  private let window: NSWindow
  private var phase = Phase.idle

  init(window: NSWindow) {
    self.window = window
  }

  /// A quiet check says nothing unless there is an update. Check for Updates… answers either way.
  func check(quietly: Bool) {
    #if DEBUG
      if !quietly { tell("Debug builds don't update themselves.", detail: "Build from source again to pick up new changes.") }
      return
    #else
      switch phase {
      case .checking, .installing: return
      case .ready(let release, _):
        if !quietly { offer(release) }
        return
      case .idle: break
      }
      phase = .checking
      Task {
        do {
          let release = try await Release.fetch("latest")
          guard let running = Version.running, running < release.version else {
            phase = .idle
            if !quietly { tell("Moodboard is up to date.", detail: "You have version \(Version.running?.description ?? "unknown"), the latest release.") }
            return
          }
          let folder = Bundle.main.bundleURL.deletingLastPathComponent()
          guard FileManager.default.isWritableFile(atPath: folder.path) else {
            phase = .idle
            return sendToPage(release, because: "Moodboard can't replace itself in \(folder.path). Download the new version from its release page.")
          }
          let app = try await download(release)
          phase = .ready(release, app: app)
          offer(release)
        } catch {
          phase = .idle
          if !quietly { tell("Moodboard couldn't check for updates.", detail: error.localizedDescription) }
        }
      }
    #endif
  }

  /// Starts the swap if a download is waiting. Called on quit, and by Relaunch Now with `reopen`.
  func installIfReady(reopen: Bool = false) {
    guard case .ready(_, let app) = phase else { return }
    phase = .installing
    let swap = Process()
    swap.executableURL = URL(filePath: "/bin/sh")
    swap.arguments = ["-c", Self.swap, "sh", String(ProcessInfo.processInfo.processIdentifier), app.path, Bundle.main.bundleURL.path, reopen ? "1" : "0"]
    try? swap.run()
  }

  /// Unzips the release next to nothing the person uses, and checks it is Moodboard at the promised version.
  private func download(_ release: Release) async throws -> URL {
    let (zip, response) = try await URLSession.shared.download(from: release.zip)
    defer { try? FileManager.default.removeItem(at: zip) }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("The download of Moodboard \(release.version) failed.") }
    let folder = FileManager.default.temporaryDirectory.appending(path: "Moodboard Update \(release.version)", directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let unzip = await Shell.run("ditto -x -k \"$1\" \"$2\"", [zip.path, folder.path])
    let app = folder.appending(path: "Moodboard.app", directoryHint: .isDirectory)
    guard unzip.status == 0, let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
      (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(Version.init) == release.version
    else { throw Failure("The download isn't Moodboard \(release.version).") }
    return app
  }

  private func offer(_ release: Release) {
    let alert = NSAlert()
    alert.messageText = "Moodboard \(release.version) is ready"
    alert.informativeText = "Relaunch to start using it. If you choose Later, it installs the next time you quit Moodboard."
    alert.addButton(withTitle: "Relaunch Now")
    alert.addButton(withTitle: "Later")
    present(alert) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.installIfReady(reopen: true)
      NSApp.terminate(nil)
    }
  }

  private func sendToPage(_ release: Release, because reason: String) {
    let alert = NSAlert()
    alert.messageText = "Moodboard \(release.version) is out"
    alert.informativeText = reason
    alert.addButton(withTitle: "Open Release Page")
    alert.addButton(withTitle: "Later")
    present(alert) { response in
      if response == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }
  }

  private func tell(_ message: String, detail: String) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = detail
    present(alert) { _ in }
  }

  /// A sheet on the wall, so a check at launch never takes focus from another app.
  private func present(_ alert: NSAlert, then handle: @escaping (NSApplication.ModalResponse) -> Void) {
    if window.isVisible {
      alert.beginSheetModal(for: window, completionHandler: handle)
    } else {
      handle(alert.runModal())
    }
  }
}
