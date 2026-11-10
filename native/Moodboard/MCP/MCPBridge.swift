import Foundation

/// `Moodboard --mcp`: the MCP server Claude Code talks to. It speaks JSON-RPC over stdio, and asks the
/// running wall to do everything through its private socket, opening the wall first if it's closed.
enum MCPBridge {
  private static let instructions = """
    Moodboard is the person's wall of live, isolated components. It is where a design gets tuned by eye before it is built.

    The loop: design in Paper with the Paper MCP server. Call import_from_paper so the design stands on the wall with generated dials. The person tunes it there. When they ask for it to be built, call get_component with no id for the one they have open. Its markdown field holds the design with the tune already applied, and is what to build from.

    Treat tuned values as final, because the person chose them by looking. Build with the target repository's own components, tokens and conventions.

    The person can leave a note on any component. It comes back as note, and it says what they want next. After you build a component, call mark_built so the wall shows that the code now matches this tune. When you've done what a note asks without building, clear it with set_note.

    A component whose id starts with project/ runs from a connected repository. Its file is in place.file. Your saved edits show on the wall at once. set_dials on it edits that file directly, so there's nothing to build and no need for mark_built.
    """

  private static var tools: [JSON] { ToolName.allCases.map(schema) }

  /// What Claude Code reads about each tool. The switch is exhaustive, so a new tool can't go undescribed.
  private static func schema(_ kind: ToolName) -> JSON {
    let name = kind.rawValue
    return switch kind {
    case .status:
      tool(name, "Says what the wall has open, how many components it holds, and what Paper has open and selected. Use it to orient yourself.")
    case .listComponents:
      tool(name, "Lists every component on the wall with its id, title and project, and where it stands: tuned (how many dials moved), needsBuilding, note, paper (current or changed), and builtAt with changedSinceBuilt.")
    case .getComponent:
      tool(
        name,
        "Gets a component as the person tuned it. Returns markdown (the brief to build from), note (what the person wants, if they left one), place (where it stands in the loop), changes (each dial moved, from and to), dials (every dial path), css, jsx (the design with the tune applied, for a design from Paper) and source. With no id, it gets the component the person has open.",
        ["id": string("Component id. Leave it out for the one open on the wall.")]
      )
    case .importFromPaper:
      tool(
        name,
        "Puts a design from Paper on the wall with generated dials, reading Paper and never changing it. With no arguments it imports what's selected in Paper. Importing the same design again updates it and keeps its tune. It doesn't open the wall's window or take focus.",
        [
          "frame": string("Name of a frame on the current Paper page."),
          "fileId": string("Paper file id. Pass it with nodeId for a node you just wrote to Paper."),
          "nodeId": string("Paper node id. Pass it with fileId."),
        ]
      )
    case .openComponent:
      tool(
        name,
        "Brings the wall forward, scrolls to a component and opens it with its dials. This takes focus, so use it when the person asks to see something.",
        ["id": string("Component id. Leave it out for the one already open.")]
      )
    case .setDials:
      tool(
        name,
        "Moves dials on a component, and the running component and any open panel follow. Only do this when the person asks. Returns every dial now changed from its default.",
        [
          "id": string("Component id. Leave it out for the one open on the wall."),
          "values": ["type": "object", "description": "Dial paths from get_component's dials, with their new values, such as {\"Type.17 px\": 20}."] as JSON,
        ],
        required: ["values"]
      )
    case .setNote:
      tool(
        name,
        "Writes the note on a component, or clears it with an empty string. Clear a note once you've done what it asks. Don't overwrite a note the person wrote unless they ask.",
        ["id": string("Component id. Leave it out for the one open on the wall."), "note": string("The note. An empty string clears it.")],
        required: ["note"]
      )
    case .connectProject:
      tool(
        name,
        "Connects a Next.js project on this Mac and waits up to 45 seconds for its components to join the wall as live tiles. Saved edits to them show at once, and moving a dial edits the source file. It adds nothing to the project's folder. A folder inside an app, or a monorepo with one app, connects that app. Connecting a project again is safe, and retries one that stopped. The result says how many components are on the wall, which aren't and why, any problem, and what to do next. It opens Moodboard behind other windows if it's closed.",
        ["path": string("The project's folder. A relative path starts from the folder Claude Code is working in. Leave it out to connect that folder.")]
      )
    case .listProjects:
      tool(name, "Lists connected projects: how many components are on the wall, which aren't and why, and any problem running them.")
    case .disconnectProject:
      tool(
        name,
        "Disconnects a project and takes its tiles off the wall. The project's files stay as they are.",
        ["project": string("The project's name, id or folder, from list_projects.")],
        required: ["project"]
      )
    case .markBuilt:
      tool(
        name,
        "Records that this component's current tune and design are now in code, and clears its note. The wall then shows it as built until the tune or design changes.",
        ["id": string("Component id. Leave it out for the one open on the wall."), "repository": string("Absolute path of the repository it went into."), "summary": string("One line on what was done.")]
      )
    }
  }

  private static let prompts: [JSON] = [
    [
      "name": "connect",
      "description": "Connect this project to the wall, and say what joined it.",
      "arguments": [["name": "path", "description": "The project's folder. Leave it out for the folder Claude Code is working in.", "required": false]],
    ],
    [
      "name": "implement_component",
      "description": "Build the component open on the wall, as tuned, into this repository.",
      "arguments": [["name": "id", "description": "Component id. Leave it out for the one open on the wall.", "required": false]],
    ],
    [
      "name": "build_tuned",
      "description": "Build everything tuned on the wall that isn't in the code yet.",
      "arguments": [] as [JSON],
    ],
    [
      "name": "apply_notes",
      "description": "Work through the notes left on the wall.",
      "arguments": [] as [JSON],
    ],
    [
      "name": "design_in_paper",
      "description": "Design a component in Paper, then put it on the wall to tune.",
      "arguments": [["name": "what", "description": "What to design.", "required": true]],
    ],
  ]

  private static func string(_ description: String) -> JSON { ["type": "string", "description": description] }

  private static func tool(_ name: String, _ description: String, _ properties: JSON = [:], required: [String] = []) -> JSON {
    ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required] as JSON]
  }

  static func run() -> Never {
    while let line = readLine(strippingNewline: true) {
      guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON, let method = request["method"] as? String else { continue }
      // A message with no id is a notification, and gets no answer.
      guard let id = request["id"] else { continue }
      var reply: JSON = ["jsonrpc": "2.0", "id": id]
      do {
        reply["result"] = try answer(method, request["params"] as? JSON ?? [:])
      } catch RPCFailure.noSuchMethod {
        reply["error"] = ["code": -32601, "message": "No method called \(method)."] as JSON
      } catch {
        reply["error"] = ["code": -32603, "message": error.localizedDescription] as JSON
      }
      guard let data = try? JSONSerialization.data(withJSONObject: reply) else { continue }
      FileHandle.standardOutput.write(data + Data([0x0a]))
    }
    exit(0)
  }

  private enum RPCFailure: Error { case noSuchMethod }

  private static func answer(_ method: String, _ params: JSON) throws -> JSON {
    switch method {
    case "initialize":
      return [
        "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
        "capabilities": ["tools": [:] as JSON, "prompts": [:] as JSON],
        "serverInfo": ["name": "moodboard", "version": "1.0"],
        "instructions": instructions,
      ]
    case "ping": return [:]
    case "tools/list": return ["tools": tools]
    case "prompts/list": return ["prompts": prompts]
    case "tools/call": return callTool(params["name"] as? String ?? "", params["arguments"] as? JSON ?? [:])
    case "prompts/get": return try prompt(params["name"] as? String ?? "", params["arguments"] as? JSON ?? [:])
    default: throw RPCFailure.noSuchMethod
    }
  }

  /// A tool that fails says so in its result, so Claude Code can read why and do something about it.
  private static func callTool(_ name: String, _ arguments: JSON) -> JSON {
    do {
      var arguments = arguments
      if name == ToolName.connectProject.rawValue { arguments["path"] = try projectPath(arguments["path"] as? String) }
      let result = try WallSocket.ask(name, arguments)
      let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
      return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    } catch {
      return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
    }
  }

  /// Claude Code starts this server in the folder it's working in, so that folder is what "this project" means.
  /// The wall runs in another process, so this resolves a relative path against that folder.
  nonisolated static func projectPath(_ given: String?, workingIn folder: String = FileManager.default.currentDirectoryPath) throws -> String {
    let given = given.map { NSString(string: $0).expandingTildeInPath } ?? ""
    if given.hasPrefix("/") { return given }
    guard folder != "/" || !given.isEmpty else { throw ToolError("Claude Code didn't start this server in a project folder. Pass path, the project's folder.") }
    return URL(filePath: given.isEmpty ? "." : given, relativeTo: URL(filePath: folder, directoryHint: .isDirectory)).standardizedFileURL.path
  }

  private static func prompt(_ name: String, _ arguments: JSON) throws -> JSON {
    let text: String
    switch name {
    case "implement_component":
      let brief = try WallSocket.ask("get_component", arguments) as? JSON
      text = (brief?["markdown"] as? String ?? "") + "\n\nBuild this into the repository you're working in. Then call mark_built from the moodboard server for \(brief?["id"] as? String ?? "this component")."
    case "connect":
      text = "Call connect_project from the moodboard server\((arguments["path"] as? String).map { " with path \"\($0)\"" } ?? " with no path, to connect the project in this folder"). Then tell me in a sentence or two how many components joined the wall. If its result has a problem, or components it couldn't show, explain each in plain words and do what its next field says, or tell me what I need to do."
    case "build_tuned":
      text = "Call list_components from the moodboard server. For each component with needsBuilding, call get_component and build it into the repository you're working in, following its brief. Call mark_built after each one. Tell me if a component has tuneNoLongerApplies before you build it."
    case "apply_notes":
      text = "Call list_components from the moodboard server, and work through each component that has a note. If its id starts with paper/, revise the design in Paper with the Paper MCP server, then call import_from_paper with its frame. Otherwise change the component in the repository you're working in. Clear each note with set_note once it's done, and stop to ask me if a note is unclear."
    case "design_in_paper":
      text = """
        Design this in Paper with the Paper MCP server: \(arguments["what"] as? String ?? "a new component").

        Follow Paper's own guide, and write a brief first if there's no design system yet. When the design is done, call import_from_paper from the moodboard server with the frame's name, so I can tune it on the wall. Then stop and wait for me to tune it.
        """
    default:
      throw ToolError("There's no prompt called \(name).")
    }
    return ["messages": [["role": "user", "content": ["type": "text", "text": text]]]]
  }
}

/// One blocking request to the running wall.
private enum WallSocket {
  static func ask(_ method: String, _ params: JSON) throws -> Any {
    let fd = try connectOpeningWall()
    defer { close(fd) }
    var timeout = timeval(tv_sec: 120, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    let message = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params] as JSON) + Data([0x0a])
    let wrote = message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard wrote == message.count else { throw ToolError("The wall stopped listening.") }

    var reply = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !reply.contains(0x0a) {
      let count = read(fd, &chunk, chunk.count)
      guard count > 0 else { throw ToolError("The wall stopped answering.") }
      reply.append(contentsOf: chunk[0..<count])
    }
    guard let answer = (try JSONSerialization.jsonObject(with: reply)) as? JSON else { throw ToolError("The wall answered with nothing.") }
    if let failure = answer["error"] as? String { throw ToolError(failure) }
    return answer["result"] ?? NSNull()
  }

  private static func connectOnce() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, var address = SocketServer.address(Paths.socket.path) else { return nil }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if connected == 0 { return fd }
    close(fd)
    return nil
  }

  private static func connectOpeningWall() throws -> Int32 {
    if let fd = connectOnce() { return fd }
    // `-g` opens it behind whatever the person is doing.
    let open = Process()
    open.executableURL = URL(filePath: "/usr/bin/open")
    open.arguments = ["-g", Bundle.main.bundlePath, "--args", "-MoodboardInBackground", "YES"]
    try open.run()
    open.waitUntilExit()
    guard open.terminationStatus == 0 else {
      throw ToolError("Moodboard couldn't be opened from \(Bundle.main.bundlePath). Install it again, then run: claude mcp add -s user moodboard -- ~/Applications/Moodboard.app/Contents/MacOS/Moodboard --mcp")
    }
    for _ in 0..<150 {
      usleep(100_000)
      if let fd = connectOnce() { return fd }
    }
    throw ToolError("Moodboard opened but didn't start within 15 seconds. If macOS is showing a dialog about it, answer it, then try again.")
  }
}
