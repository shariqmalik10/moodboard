import Foundation

/// Works out which folder to connect from whatever folder was given: the project itself, a folder inside it,
/// or a monorepo that holds it. Anything it can't connect comes back as a sentence that says what to do.
nonisolated enum ProjectFinder {
  enum Answer: Equatable {
    case project(URL, note: String?)
    /// A folder holding several Next.js apps, so the person has to say which.
    case several([URL])
    case problem(String)
  }

  /// Folders a search for apps never enters.
  private static let skipped: Set<String> = ["node_modules", ".git", ".next", "dist", "build", "out", ".turbo", ".vercel", "coverage"]
  private static let searchDepth = 4
  private static let searchLimit = 2000

  static func find(_ given: URL) -> Answer {
    let files = FileManager.default
    var folder = given.standardizedFileURL.resolvingSymlinksInPath()
    var isFolder: ObjCBool = false
    guard files.fileExists(atPath: folder.path, isDirectory: &isFolder) else { return .problem("There's no folder at \(given.path).") }
    if !isFolder.boolValue { folder = folder.deletingLastPathComponent() }
    do {
      _ = try files.contentsOfDirectory(atPath: folder.path)
    } catch CocoaError.fileReadNoPermission {
      return .problem(refused)
    } catch {}

    let nearest = ancestors(of: folder).first { files.fileExists(atPath: $0.appending(path: "package.json").path) }
    // A folder inside an app, such as its src/components, connects the app.
    if let app = ancestors(of: folder).first(where: { manifest(at: $0)?.usesNext == true }) { return installed(app, note: nil) }
    let apps = appsBelow(folder)
    if apps.count == 1, let app = apps.first {
      let inside = app.path.dropFirst(folder.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      return installed(app, note: "\(folder.lastPathComponent) isn't a Next.js app itself, so Moodboard connected \(inside), the one inside it.")
    }
    if apps.count > 1 { return .several(apps) }
    guard let nearest, let found = manifest(at: nearest) else {
      return .problem("\(folder.lastPathComponent) has no package.json, so it isn't a JavaScript project. Choose the folder of a Next.js app.")
    }
    guard found.usesReact else { return .problem("\(nearest.lastPathComponent) doesn't use React, so it has no components to show. Moodboard connects Next.js apps.") }
    return installed(nearest, note: "\(nearest.lastPathComponent) uses React without Next.js. Moodboard shows its .tsx components the same way, but it's made for Next.js apps.")
  }

  static let refused = "Moodboard can't read this folder. If macOS asks, choose Allow, or turn Moodboard on in System Settings, under Privacy & Security, Files and Folders."

  /// Every folder from this one up to the root.
  static func ancestors(of folder: URL) -> [URL] {
    // Built from the path's parts, because a URL's parent past the root is `/..`, not the root again.
    var path = folder.standardizedFileURL.path
    var out: [URL] = []
    while true {
      out.append(URL(filePath: path, directoryHint: .isDirectory))
      if path == "/" || path.isEmpty { return out }
      path = (path as NSString).deletingLastPathComponent
    }
  }

  struct Manifest {
    var name: String?
    var dependencies: Set<String>
    var usesNext: Bool { dependencies.contains("next") }
    var usesReact: Bool { usesNext || dependencies.contains("react") }
  }

  static func manifest(at folder: URL) -> Manifest? {
    guard let data = try? Data(contentsOf: folder.appending(path: "package.json")), let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let keys = ["dependencies", "devDependencies", "peerDependencies"].flatMap { (json[$0] as? [String: Any])?.keys.map { $0 } ?? [] }
    return Manifest(name: json["name"] as? String, dependencies: Set(keys))
  }

  /// Next.js apps under a folder, nearest first, for a monorepo or a folder of projects.
  static func appsBelow(_ folder: URL) -> [URL] {
    var found: [URL] = []
    var level = [folder]
    var visited = 0
    for _ in 0..<searchDepth {
      var next: [URL] = []
      for each in level {
        visited += 1
        // A home folder or a whole drive would take minutes, and wouldn't point to a single app anyway.
        if visited > searchLimit { return found }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: each.path)) ?? []).sorted()
        for name in names where !name.hasPrefix(".") && !skipped.contains(name) {
          let child = each.appending(path: name, directoryHint: .isDirectory)
          var isFolder: ObjCBool = false
          guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isFolder), isFolder.boolValue else { continue }
          if manifest(at: child)?.usesNext == true { found.append(child) } else { next.append(child) }
        }
      }
      level = next
    }
    return found
  }

  /// Moodboard brings its own stand-ins for Next.js, so React is the one package a project must have installed.
  /// A monorepo keeps packages in the root's node_modules, so the search goes up as Node's does.
  private static func installed(_ app: URL, note: String?) -> Answer {
    let hasReact = ancestors(of: app).contains { FileManager.default.fileExists(atPath: $0.appending(path: "node_modules/react/package.json").path) }
    guard hasReact else {
      let (tool, folder) = packageManager(for: app)
      return .problem("\(app.lastPathComponent)'s packages aren't installed. Run `\(tool) install` in \(folder.path), then connect it again.")
    }
    return .project(app, note: note)
  }

  /// Which install command the project expects, from the lockfile nearest to it.
  static func packageManager(for app: URL) -> (tool: String, folder: URL) {
    let locks = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lock", "bun"), ("bun.lockb", "bun"), ("package-lock.json", "npm")]
    for folder in ancestors(of: app) {
      for (file, tool) in locks where FileManager.default.fileExists(atPath: folder.appending(path: file).path) { return (tool, folder) }
    }
    return ("npm", app)
  }
}

/// Vite, which runs each project, needs Node 20.19 or newer, found the way a login shell finds it.
enum NodeCheck {
  enum Result: Equatable { case ready(String), tooOld(String), missing }

  private static var known: Result?

  static func check() async -> Result {
    if let known, case .ready = known { return known }
    let node = await Shell.run("node --version")
    let result: Result
    if node.status == 0, let version = node.output.split(separator: "\n").last.map(String.init) {
      result = isRecent(version) ? .ready(version) : .tooOld(version)
    } else {
      result = .missing
    }
    known = result
    return result
  }

  nonisolated static func isRecent(_ version: String) -> Bool {
    let parts = version.trimmingCharacters(in: CharacterSet(charactersIn: "v \n")).split(separator: ".").compactMap { Int($0) }
    guard parts.count >= 2 else { return false }
    return parts[0] > 20 || (parts[0] == 20 && parts[1] >= 19)
  }

  static func problem(_ result: Result) -> String? {
    switch result {
    case .ready: nil
    case .tooOld(let version): "Moodboard runs projects with Node 20.19 or newer, and your shell has Node \(version). Install a newer Node from nodejs.org, then connect again."
    case .missing: "Moodboard couldn't find Node. It runs projects with the `node` your login shell finds. Install Node 20.19 or newer from nodejs.org, then connect again."
    }
  }
}
