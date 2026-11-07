import AppKit

/// Talks to the Paper app's own MCP server on this machine. The wall only ever reads from Paper.
final class PaperClient {
  enum Failure: LocalizedError {
    case notRunning
    case tool(String)

    var errorDescription: String? {
      switch self {
      case .notRunning: "Paper isn't open."
      case .tool(let message): message
      }
    }
  }

  /// What a tool returned: Paper sends a file header first, then the answer.
  struct Reply {
    let file: (id: String, name: String)?
    let payload: JSON
    let text: String
    let image: Data?
  }

  struct Node: Identifiable, Equatable {
    let id: String
    let fileId: String
    let fileName: String?
    let name: String
    let width: Double
    let height: Double
  }

  static let endpoint = URL(string: "http://127.0.0.1:29979/mcp")!

  private var session: String?
  private var nextId = 0
  private let urlSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 20
    return URLSession(configuration: configuration)
  }()

  private func post(_ body: JSON) async throws -> JSON? {
    var request = URLRequest(url: Self.endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "accept")
    if let session { request.setValue(session, forHTTPHeaderField: "mcp-session-id") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await urlSession.data(for: request)
    } catch {
      session = nil
      throw Failure.notRunning
    }
    guard let http = response as? HTTPURLResponse else { throw Failure.notRunning }
    if let id = http.value(forHTTPHeaderField: "mcp-session-id") { session = id }
    if http.statusCode == 404 || http.statusCode == 400 {
      session = nil
      throw Failure.tool("Paper dropped the connection.")
    }
    guard body["id"] != nil else { return nil }
    return Self.parse(data, contentType: http.value(forHTTPHeaderField: "content-type") ?? "")
  }

  static func parse(_ data: Data, contentType: String) -> JSON? {
    if contentType.contains("event-stream") {
      let text = String(decoding: data, as: UTF8.self)
      let lines = text.split(separator: "\n").filter { $0.hasPrefix("data:") }
      guard let last = lines.last else { return nil }
      return (try? JSONSerialization.jsonObject(with: Data(last.dropFirst(5).utf8))) as? JSON
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? JSON
  }

  private func connect() async throws {
    guard session == nil else { return }
    nextId += 1
    _ = try await post([
      "jsonrpc": "2.0", "id": nextId, "method": "initialize",
      "params": ["protocolVersion": "2025-06-18", "capabilities": [:] as JSON, "clientInfo": ["name": "moodboard", "version": "1.0"]],
    ])
    _ = try await post(["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:] as JSON])
  }

  func call(_ tool: String, _ arguments: JSON = [:]) async throws -> Reply {
    do {
      return try await attempt(tool, arguments)
    } catch Failure.tool(let message) where message == "Paper dropped the connection." {
      return try await attempt(tool, arguments)
    }
  }

  private func attempt(_ tool: String, _ arguments: JSON) async throws -> Reply {
    try await connect()
    nextId += 1
    let reply = try await post(["jsonrpc": "2.0", "id": nextId, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
    if let error = reply?["error"] as? JSON { throw Failure.tool(error["message"] as? String ?? "Paper said no.") }
    guard let result = reply?["result"] as? JSON, let content = result["content"] as? [JSON] else { throw Failure.tool("Paper answered with nothing.") }
    let texts = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
    if result["isError"] as? Bool == true { throw Failure.tool(texts.first ?? "Paper said no.") }

    var file: (String, String)?
    var body = texts.last ?? ""
    if let first = texts.first, let header = Self.json(first), let info = header["file"] as? JSON, let id = info["id"] as? String {
      file = (id, info["name"] as? String ?? "")
      if texts.count == 1 { body = "" }
    }
    let image = content.first { $0["type"] as? String == "image" }.flatMap { ($0["data"] as? String).flatMap { Data(base64Encoded: $0) } }
    return Reply(file: file, payload: Self.json(body) ?? [:], text: body, image: image)
  }

  private static func json(_ text: String) -> JSON? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? JSON
  }

  // MARK: What the app asks

  func selection() async throws -> [Node] {
    let reply = try await call("get_selection")
    let nodes = reply.payload["selectedNodes"] as? [JSON] ?? []
    guard let file = reply.file else { return [] }
    var found: [Node] = []
    for node in nodes {
      guard let id = node["id"] as? String, let info = try? await nodeInfo(fileId: file.id, fileName: file.name, nodeId: id) else { continue }
      found.append(info)
    }
    return found
  }

  func artboards() async throws -> (file: String, page: String, nodes: [Node]) {
    let reply = try await call("get_basic_info")
    let fileId = reply.file?.id ?? ""
    let name = reply.file?.name ?? reply.payload["fileName"] as? String
    let boards = reply.payload["artboards"] as? [JSON] ?? []
    let nodes = boards.compactMap { board -> Node? in
      guard let id = board["id"] as? String else { return nil }
      return Node(id: id, fileId: fileId, fileName: name, name: board["name"] as? String ?? "Untitled", width: board["width"] as? Double ?? 0, height: board["height"] as? Double ?? 0)
    }
    return (name ?? "", reply.payload["pageName"] as? String ?? "", nodes)
  }

  func nodeInfo(fileId: String, fileName: String? = nil, nodeId: String) async throws -> Node {
    let reply = try await call("get_node_info", ["fileId": fileId, "nodeId": nodeId])
    return Node(
      id: nodeId, fileId: fileId, fileName: fileName ?? reply.file?.name, name: reply.payload["name"] as? String ?? "Untitled",
      width: reply.payload["width"] as? Double ?? 0, height: reply.payload["height"] as? Double ?? 0
    )
  }

  func jsx(_ node: Node) async throws -> String {
    try await jsx(fileId: node.fileId, nodeId: node.id)
  }

  func jsx(fileId: String, nodeId: String) async throws -> String {
    try await call("get_jsx", ["fileId": fileId, "nodeId": nodeId, "includeNodeIds": false, "format": "inline-styles"]).text
  }

  func tokens(fileId: String) async throws -> [ComponentRecord.Token] {
    let reply = try await call("get_tokens", ["fileId": fileId])
    let data = try JSONSerialization.data(withJSONObject: reply.payload["tokens"] ?? [])
    return try JSONDecoder().decode([ComponentRecord.Token].self, from: data)
  }

  func thumbnail(_ node: Node) async -> NSImage? {
    let reply = try? await call("get_screenshot", ["fileId": node.fileId, "nodeId": node.id, "scale": 0.25])
    return reply?.image.flatMap(NSImage.init(data:))
  }
}
