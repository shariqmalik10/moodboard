import Foundation
import Testing

@testable import Moodboard

/// Folder trees made up in a temporary folder, each the shape of something a person might connect.
struct ProjectFinderTests {
  private let top: URL

  init() throws {
    top = FileManager.default.temporaryDirectory.appending(path: "finder \(UUID().uuidString)", directoryHint: .isDirectory).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: top, withIntermediateDirectories: true)
  }

  private func folder(_ path: String) throws -> URL {
    let url = top.appending(path: path, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func app(_ path: String, dependencies: [String] = ["next", "react"], installed: [String]? = nil) throws -> URL {
    let url = try folder(path)
    let manifest: [String: Any] = ["name": url.lastPathComponent, "dependencies": Dictionary(uniqueKeysWithValues: dependencies.map { ($0, "*") })]
    try JSONSerialization.data(withJSONObject: manifest).write(to: url.appending(path: "package.json"))
    for package in installed ?? dependencies { try install(package, in: url) }
    return url
  }

  private func install(_ package: String, in url: URL) throws {
    let folder = url.appending(path: "node_modules/\(package)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: folder.appending(path: "package.json"))
  }

  @Test func `a Next.js app connects as itself`() throws {
    let web = try app("web")
    #expect(ProjectFinder.find(web) == .project(web, note: nil))
  }

  @Test func `a folder inside an app connects the app`() throws {
    let web = try app("web")
    let inside = try folder("web/src/components")
    #expect(ProjectFinder.find(inside) == .project(web, note: nil))
  }

  @Test func `a monorepo with one app connects that app, using the root's packages`() throws {
    let repo = try app("repo", dependencies: ["turbo"], installed: [])
    let web = try app("repo/apps/web", installed: [])
    try install("next", in: repo)
    try install("react", in: repo)
    guard case .project(let found, let note) = ProjectFinder.find(repo) else { Issue.record("Expected a project"); return }
    #expect(found == web)
    #expect(note?.contains("apps/web") == true)
  }

  @Test func `a monorepo with several apps asks which`() throws {
    _ = try app("repo", dependencies: ["turbo"])
    let docs = try app("repo/apps/docs")
    let web = try app("repo/apps/web")
    #expect(ProjectFinder.find(top.appending(path: "repo")) == .several([docs, web]))
  }

  @Test func `packages that aren't installed name the install command from the lockfile`() throws {
    let web = try app("web", installed: [])
    try Data().write(to: web.appending(path: "pnpm-lock.yaml"))
    guard case .problem(let problem) = ProjectFinder.find(web) else { Issue.record("Expected a problem"); return }
    #expect(problem.contains("pnpm install"))
  }

  @Test func `a folder with no package.json says so`() throws {
    let empty = try folder("notes")
    guard case .problem(let problem) = ProjectFinder.find(empty) else { Issue.record("Expected a problem"); return }
    #expect(problem.contains("no package.json"))
  }

  @Test func `a project without React says it has nothing to show`() throws {
    let tool = try app("tool", dependencies: ["express"])
    guard case .problem(let problem) = ProjectFinder.find(tool) else { Issue.record("Expected a problem"); return }
    #expect(problem.contains("doesn't use React"))
  }

  @Test func `React without Next.js connects, with a note`() throws {
    let site = try app("site", dependencies: ["react", "vite"], installed: ["react"])
    guard case .project(let found, let note) = ProjectFinder.find(site) else { Issue.record("Expected a project"); return }
    #expect(found == site)
    #expect(note?.contains("without Next.js") == true)
  }

  @Test func `a symlink and a path with spaces land on the real folder`() throws {
    let web = try app("my projects/web app")
    let link = top.appending(path: "shortcut")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: web)
    #expect(ProjectFinder.find(link) == .project(web, note: nil))
  }

  @Test func `a folder that isn't there says so`() {
    guard case .problem(let problem) = ProjectFinder.find(top.appending(path: "gone")) else { Issue.record("Expected a problem"); return }
    #expect(problem.contains("no folder"))
  }

  @Test func `Node versions before 20.19 are too old`() {
    #expect(NodeCheck.isRecent("v20.19.0"))
    #expect(NodeCheck.isRecent("v22.1.0"))
    #expect(!NodeCheck.isRecent("v20.18.3"))
    #expect(!NodeCheck.isRecent("v18.20.0"))
    #expect(!NodeCheck.isRecent("zsh: command not found: node"))
  }

  @Test func `the MCP path starts from Claude Code's folder`() throws {
    #expect(try MCPBridge.projectPath(nil, workingIn: "/Users/a/site") == "/Users/a/site")
    #expect(try MCPBridge.projectPath("apps/web", workingIn: "/Users/a/repo") == "/Users/a/repo/apps/web")
    #expect(try MCPBridge.projectPath("../other app", workingIn: "/Users/a/site") == "/Users/a/other app")
    #expect(try MCPBridge.projectPath("/abs/path", workingIn: "/") == "/abs/path")
    #expect(throws: ToolError.self) { try MCPBridge.projectPath(nil, workingIn: "/") }
  }
}
