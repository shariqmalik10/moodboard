import AppKit

/// What Claude Code can ask of the running wall. Each method here is one MCP tool, named in `MCPBridge`.
final class Tools {
  private unowned let model: AppModel
  #if DEBUG
    private var recording: (activity: NSObjectProtocol, frame: NSRect, behavior: NSWindow.CollectionBehavior)?
  #endif

  init(model: AppModel) {
    self.model = model
  }

  func handle(method: String, params: JSON) async throws -> Any {
    #if DEBUG
      if method.hasPrefix("debug.") { return try await debug(method, params) }
    #endif
    try await waitUntilStarted()
    switch method {
    case "status": return await status()
    case "list_components": return try await listComponents()
    case "get_component": return try await brief(try componentId(params))
    case "import_from_paper": return try await importFromPaper(params)
    case "open_component": return try await openComponent(try componentId(params))
    case "set_dials": return try await setDials(try componentId(params), params["values"] as? JSON ?? [:])
    case "set_note": return try setNote(try componentId(params), params["note"] as? String ?? "")
    case "mark_built": return try markBuilt(try componentId(params), params)
    case "connect_project": return try await connectProject(params)
    case "list_projects": return listProjects()
    case "disconnect_project": return try disconnectProject(params)
    default: throw ToolError("There's no tool called \(method).")
    }
  }

  private func waitUntilStarted() async throws {
    for _ in 0..<150 {
      if model.chrome != nil { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ToolError("The wall is still starting. Try again in a moment.")
  }

  /// The id asked for, or whatever the person has open, which is what "this component" means to them.
  private func componentId(_ params: JSON) throws -> String {
    if let id = params["id"] as? String, !id.isEmpty {
      guard model.store?.items[id]?.isComponent == true else { throw ToolError("There's no component called \(id). list_components gives the ids.") }
      return id
    }
    guard let id = model.focus?.openItemId else { throw ToolError("Nothing is open on the wall. Pass an id, or ask the person to open a component.") }
    return id
  }

  func brief(_ id: String) async throws -> JSON {
    let note = model.statuses.note(id)
    let data = try await model.runtime.call("return await window.__runtime.brief(id, saved, note)", ["id": id, "saved": DialState.saved(id), "note": note])
    var brief = try JSONSerialization.jsonObject(with: data) as? JSON ?? [:]
    if !note.isEmpty { brief["note"] = note }
    brief["place"] = place(of: id)
    return brief
  }

  /// Where a component stands in the loop, in the words the person sees.
  private func place(of id: String) -> JSON {
    let status = model.statuses.status(id)
    var place: JSON = ["tuned": status.tuned, "needsBuilding": status.needsBuilding]
    if let file = ProjectCatalog.row(id)?.file {
      place["file"] = file
      place["writtenToSource"] = status.written
    }
    if let paper = status.paper { place["paper"] = paper.rawValue }
    if let built = model.statuses.built(id) {
      place["builtAt"] = built.at.formatted(.iso8601)
      place["changedSinceBuilt"] = status.build == .changedSince
      if let repository = built.repository { place["builtInto"] = repository }
    }
    let lost = model.statuses.lostTune(id)
    if !lost.isEmpty { place["tuneNoLongerApplies"] = lost }
    return place
  }

  private func status() async -> JSON {
    var state: JSON = ["components": model.store?.items.values.filter(\.isComponent).count ?? 0]
    if let id = model.focus?.openItemId, let item = model.store?.items[id] { state["open"] = ["id": id, "title": item.title] }
    guard let importer = model.importer else { return state }
    do {
      let (file, page, frames) = try await importer.paper.artboards()
      let selected = try await importer.paper.selection()
      state["paper"] = ["connected": true, "file": file, "page": page, "frames": frames.map(\.name), "selected": selected.map(\.name)] as JSON
    } catch {
      state["paper"] = ["connected": false, "problem": error.localizedDescription] as JSON
    }
    return state
  }

  private func listComponents() async throws -> [JSON] {
    guard let store = model.store else { return [] }
    // The watch sleeps while this app is behind others, which is often when Claude Code asks.
    await model.paperWatch?.check()
    let onWall = Set(store.visibleIds)
    return store.items.values.filter(\.isComponent).sorted(by: { $0.id < $1.id }).map { item in
      var row: JSON = ["id": item.id, "title": item.title, "project": item.project, "onWall": onWall.contains(item.id)]
      row.merge(place(of: item.id)) { _, new in new }
      let note = model.statuses.note(item.id)
      if !note.isEmpty { row["note"] = note }
      return row
    }
  }

  private func importFromPaper(_ params: JSON) async throws -> [JSON] {
    guard let importer = model.importer else { return [] }
    let nodes: [PaperClient.Node]
    if let fileId = params["fileId"] as? String, let nodeId = params["nodeId"] as? String {
      nodes = [try await importer.paper.nodeInfo(fileId: fileId, nodeId: nodeId)]
    } else if let frame = (params["frame"] as? String)?.lowercased(), !frame.isEmpty {
      let frames = try await importer.paper.artboards().nodes
      let exact = frames.filter { $0.name.lowercased() == frame }
      nodes = exact.isEmpty ? frames.filter { $0.name.lowercased().contains(frame) } : exact
      guard !nodes.isEmpty else { throw ToolError("No frame on this Paper page is called \(frame). It has: \(frames.map(\.name).joined(separator: ", "))") }
    } else {
      nodes = try await importer.paper.selection()
      guard !nodes.isEmpty else { throw ToolError("Nothing is selected in Paper. Select a frame there, or pass its name as frame.") }
    }
    var imported: [JSON] = []
    for node in nodes {
      let record = try await importer.importNode(node)
      var row: JSON = ["id": record.id, "title": record.title]
      let lost = model.statuses.lostTune(record.id)
      if !lost.isEmpty { row["tuneNoLongerApplies"] = lost }
      imported.append(row)
    }
    return imported
  }

  private func openComponent(_ id: String) async throws -> JSON {
    guard let canvas = model.canvas, let focus = model.focus, let list = model.list else { throw ToolError("The wall is still starting.") }
    if focus.openItemId == id { return ["open": id] }
    NSApp.activate()
    model.window.makeKeyAndOrderFront(nil)
    if let item = model.store?.items[id], model.chrome?.state.filter.includes(item) == false { model.show(filter: .all) }
    if let item = model.store?.items[id], model.chrome?.state.refinement.matches(item, model.statuses.status(id)) == false { model.refine(Refinement()) }
    if list.isActive {
      list.select(id)
      return ["open": id]
    }
    guard let home = canvas.homeRect(for: id) else { throw ToolError("\(id) isn't on the wall.") }
    focus.close()
    for _ in 0..<40 where focus.tile != nil { try await Task.sleep(for: .milliseconds(50)) }
    canvas.bringIntoView(home)
    for _ in 0..<40 {
      if let tile = canvas.tile(forItem: id), !canvas.isFlying { focus.open(tile); return ["open": id] }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw ToolError("The wall couldn't reach \(id). Is the window showing?")
  }

  private func setNote(_ id: String, _ note: String) throws -> JSON {
    model.statuses.setNote(id, note)
    model.statuses.save()
    model.focus?.syncInspector()
    return ["id": id, "note": model.statuses.note(id)]
  }

  private func markBuilt(_ id: String, _ params: JSON) throws -> JSON {
    model.statuses.markBuilt(id, repository: params["repository"] as? String, summary: params["summary"] as? String, session: nil)
    return place(of: id)
  }

  private func connectProject(_ params: JSON) async throws -> JSON {
    guard let path = params["path"] as? String, !path.isEmpty else { throw ToolError("Pass path, the project's folder.") }
    let project = try await model.projects.connect(URL(filePath: NSString(string: path).expandingTildeInPath, directoryHint: .isDirectory))
    return ["name": project.name, "project": project.slug, "root": project.root, "next": "Its components join the wall over the next minute. list_projects says how it's going."]
  }

  private func listProjects() -> [JSON] {
    model.projects.state.lines.map { line in
      var row: JSON = ["name": line.name, "project": line.slug, "root": line.root, "onWall": line.shown, "notShown": line.skipped.map { ["id": $0.id, "file": $0.file, "reason": $0.reason] }]
      if let progress = line.progress { row["progress"] = progress }
      if let problem = line.problem { row["problem"] = problem }
      return row
    }
  }

  private func disconnectProject(_ params: JSON) throws -> JSON {
    let asked = params["project"] as? String ?? ""
    guard let project = ProjectCatalog.projects.first(where: { $0.slug == asked || $0.name == asked || $0.root == asked }) else { throw ToolError("No connected project is called \(asked). list_projects gives them.") }
    model.projects.disconnect(slug: project.slug)
    return ["disconnected": project.name]
  }

  private func setDials(_ id: String, _ values: JSON) async throws -> Any {
    guard !values.isEmpty else { throw ToolError("Pass values, such as {\"Type.17 px\": 20}.") }
    if ProjectCatalog.contains(id) {
      guard let record = await model.projects.record(id), let values2 = ((try? JSONSerialization.jsonObject(with: record)) as? JSON)?["values"] as? JSON else { throw ToolError("The project's server isn't running.") }
      let unknown = values.keys.filter { values2[$0] == nil && !$0.hasPrefix(ProjectCatalog.samplePrefix) }
      guard unknown.isEmpty else { throw ToolError("\(id) has no dial called \(unknown.joined(separator: ", ")). It has: \(values2.keys.sorted().joined(separator: ", "))") }
      model.projects.setDials(id, values: values)
      await model.projects.settled(id)
      return model.statuses.changes(id).map { ["dial": $0.dial, "from": $0.from, "to": $0.to] as JSON }
    }
    let dials = Set(try await brief(id)["dials"] as? [String] ?? [])
    let unknown = values.keys.filter { !dials.contains($0) }
    guard unknown.isEmpty else { throw ToolError("\(id) has no dial called \(unknown.joined(separator: ", ")). It has: \(dials.sorted().joined(separator: ", "))") }
    model.focus?.setDial(id: id, values: values)
    return try await brief(id)["changes"] ?? []
  }

  #if DEBUG
    private func debug(_ method: String, _ params: JSON) async throws -> Any {
      switch method {
      case "debug.open":
        guard let canvas = model.canvas, let id = params["id"] as? String else { throw ToolError("Which tile?") }
        guard let tile = model.focus?.tile?.item?.id == id ? model.focus?.tile : canvas.tile(forItem: id) else { throw ToolError("That tile isn't on screen.") }
        model.focus?.open(tile)
        return true
      case "debug.import":
        guard let importer = model.importer, let fileId = params["fileId"] as? String, let nodeId = params["nodeId"] as? String else { throw ToolError("Which design?") }
        let node = try await importer.paper.nodeInfo(fileId: fileId, nodeId: nodeId)
        let record = try await importer.importNode(node)
        return ["id": record.id, "ground": record.ground, "dark": record.dark] as JSON
      case "debug.send":
        guard let id = params["id"] as? String, let repository = params["repository"] as? String else { throw ToolError("Which component, and which repository?") }
        if let ask = params["ask"] as? String { model.statuses.setNote(id, ask) }
        model.handoffs.send(id: id, repository: URL(filePath: repository, directoryHint: .isDirectory))
        return true
      case "debug.stop":
        model.handoffs.stop(params["id"] as? String ?? "")
        return true
      case "debug.handoff":
        guard let id = params["id"] as? String, let run = model.handoffs.run(for: id) else { return NSNull() }
        return ["status": run.status, "active": run.isActive, "session": run.sessionId ?? "", "changed": run.changedFiles.sorted()] as JSON
      case "debug.close":
        model.focus?.close()
        return true
      case "debug.onscreen":
        return model.canvas?.debugState()["tiles"] ?? []
      case "debug.eval":
        let body = params["js"] as? String ?? "return null"
        let web = params["target"] as? String == "panel" ? model.focus?.inspector.panelWeb : model.focus?.tile?.stage?.web ?? model.list?.stageWeb
        guard let web else { throw ToolError("Nothing is open.") }
        let data = try await web.callJSON(body)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
      case "debug.flight":
        return model.focus?.debugFlight() ?? [:] as JSON
      case "debug.state":
        var state = model.canvas?.debugState() ?? ["starting": true]
        state["window"] = model.window.windowNumber
        state["hidden"] = !model.window.isVisible
        state["occluded"] = !model.window.occlusionState.contains(.visible)
        return state
      case "debug.key":
        let code = params["keyCode"] as? Int ?? 48
        let text = params["text"] as? String ?? "\t"
        let flags: NSEvent.ModifierFlags = params["shift"] as? Bool == true ? [.shift] : []
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: model.window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(code)) {
          model.canvas?.keyDown(with: event)
        }
        return true
      case "debug.press":
        guard let id = params["id"] as? String, let tile = model.canvas?.tile(forItem: id) else { throw ToolError("That tile isn't on screen.") }
        return tile.accessibilityPerformPress()
      case "debug.focused":
        return model.canvas?.debugState()["keyboard"] ?? NSNull()
      case "debug.appearance":
        NSApp.appearance = (params["name"] as? String).flatMap { NSAppearance(named: $0 == "dark" ? .darkAqua : .aqua) }
        return true
      case "debug.add":
        guard let path = params["path"] as? String else { throw ToolError("Which file?") }
        model.addMaterials([URL(filePath: path)], at: nil)
        return true
      case "debug.remove":
        model.focus?.inspector.model.onRemove()
        return true
      case "debug.update":
        model.focus?.inspector.model.onUpdateFromPaper()
        return true
      case "debug.paper":
        model.chrome?.state.showsPaper = params["show"] as? Bool ?? true
        return true
      case "debug.click":
        let window = params["popover"] as? Bool == true ? NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible } : params["sheet"] as? Bool == true ? model.window.attachedSheet : model.window
        guard let window else { throw ToolError("That window isn't showing.") }
        let point = NSPoint(x: params["x"] as? Double ?? 0, y: window.frame.height - (params["y"] as? Double ?? 0))
        func mouse(_ type: NSEvent.EventType) -> NSEvent? { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) }
        guard let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) else { return false }
        // A text field tracks the mouse until it goes up, so the up has to be waiting already.
        NSApp.postEvent(up, atStart: false)
        if window === model.window, let view = window.contentView?.hitTest(point) {
          // While the app isn't active, the main window keeps a first click for itself, so its views get the events directly.
          view.mouseDown(with: down)
          if let waiting = NSApp.nextEvent(matching: .leftMouseUp, until: .now, inMode: .default, dequeue: true) { view.mouseUp(with: waiting) }
        } else {
          window.sendEvent(down)
        }
        try await Task.sleep(for: .milliseconds(60))
        return ["w": window.frame.width, "h": window.frame.height] as JSON
      case "debug.drag":
        let window: NSWindow = model.window
        let from = NSPoint(x: params["x"] as? Double ?? 0, y: window.frame.height - (params["y"] as? Double ?? 0))
        let across = params["dx"] as? Double ?? 0
        let steps = params["steps"] as? Int ?? 12
        let eases = params["ease"] as? Bool ?? false
        guard let view = window.contentView?.hitTest(from) else { return false }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? { NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) }
        if let down = mouse(.leftMouseDown, from) { view.mouseDown(with: down) }
        for step in 1...steps {
          try await Task.sleep(for: .milliseconds(16))
          let progress = Double(step) / Double(steps)
          let along = eases ? 0.5 - cos(.pi * progress) / 2 : progress
          if let drag = mouse(.leftMouseDragged, NSPoint(x: from.x + across * along, y: from.y)) { view.mouseDragged(with: drag) }
        }
        if let up = mouse(.leftMouseUp, NSPoint(x: from.x + across, y: from.y)) { view.mouseUp(with: up) }
        return true
      case "debug.view":
        let filter = (params["project"] as? String).map { $0 == "all" ? ProjectFilter.all : .project($0) }
        model.show((params["mode"] as? String).flatMap(ViewMode.init(rawValue:)), filter: filter)
        return true
      case "debug.list":
        if let id = params["select"] as? String { model.list?.select(id) }
        return model.list?.debugState() ?? [:] as JSON
      case "debug.shortcut":
        guard let key = params["key"] as? String, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: model.window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0) else { throw ToolError("Which key?") }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
      case "debug.arrow":
        let down = params["down"] as? Bool ?? true
        let glyph = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0, windowNumber: model.window.windowNumber, context: nil, characters: glyph, charactersIgnoringModifiers: glyph, isARepeat: false, keyCode: down ? 125 : 126) {
          model.window.sendEvent(event)
        }
        return true
      case "debug.resize":
        model.window.setContentSize(NSSize(width: params["w"] as? Double ?? 1440, height: params["h"] as? Double ?? 920))
        return ["w": model.window.contentView?.bounds.width ?? 0, "h": model.window.contentView?.bounds.height ?? 0] as JSON
      case "debug.chrome":
        let counts = model.chrome?.state.counts ?? [:]
        return ["mode": model.chrome?.state.mode.rawValue ?? "", "projects": model.chrome?.state.projects ?? [], "compact": model.chrome?.state.isCompact ?? false, "density": model.canvas?.density.rawValue ?? -1, "query": model.chrome?.state.refinement.query ?? "", "attention": model.chrome?.state.refinement.attention?.rawValue ?? NSNull(), "counts": Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })] as JSON
      case "debug.refine":
        model.refine(Refinement(query: params["query"] as? String ?? "", attention: (params["attention"] as? String).flatMap(Attention.init(rawValue:))))
        return true
      case "debug.density":
        model.canvas?.changeDensity(by: params["step"] as? Int ?? 1)
        model.chrome?.boardChanged()
        return model.canvas?.density.rawValue ?? -1
      case "debug.inspector":
        let state = model.focus?.inspector.model
        return ["id": state?.itemId ?? NSNull(), "note": state?.note ?? "", "changes": state?.changes.map(\.line) ?? [], "before": state?.showsBefore ?? false, "paper": state?.paper?.rawValue ?? NSNull(), "lost": state?.lostTune ?? [], "built": state?.builtLine ?? NSNull(), "mark": state?.status.mark?.label ?? NSNull()] as JSON
      case "debug.hold":
        model.focus?.inspector.model.onHoldBefore(params["on"] as? Bool ?? false)
        return true
      case "debug.revert":
        let state = model.focus?.inspector.model
        if let dial = params["dial"] as? String, let change = state?.changes.first(where: { $0.dial == dial }) { state?.onRevert(change) } else { state?.onRevertAll() }
        return true
      case "debug.typeNote":
        model.focus?.inspector.model.note = params["note"] as? String ?? ""
        model.focus?.inspector.model.onNoteEdited(params["note"] as? String ?? "")
        return true
      case "debug.action":
        let state = model.focus?.inspector.model
        switch params["name"] as? String {
        case "copyBrief": state?.onCopyBrief()
        case "copyChanges": state?.onCopyChanges()
        case "toggleBuilt": state?.onToggleBuilt()
        case "dismissLost": state?.onDismissLost()
        case "startOver": state?.onStartOver()
        default: throw ToolError("Which action?")
        }
        return true
      case "debug.paperCheck":
        await model.paperWatch?.check()
        return true
      case "debug.updateChanged":
        await model.importer?.updateChanged()
        return true
      case "debug.option":
        let flags: NSEvent.ModifierFlags = params["on"] as? Bool == true ? [.option] : []
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: model.window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58) { NSApp.sendEvent(event) }
        return model.focus?.inspector.model.showsBefore ?? false
      case "debug.commandReturn":
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: model.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return false }
        return model.window.performKeyEquivalent(with: event)
      case "debug.windowKey":
        let text = params["text"] as? String ?? "\r"
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: model.window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(params["keyCode"] as? Int ?? 36)) else { return false }
        model.window.sendEvent(event)
        return true
      case "debug.firstResponder":
        return model.window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
      case "debug.move":
        let point = NSPoint(x: params["x"] as? Double ?? 0, y: model.window.frame.height - (params["y"] as? Double ?? 0))
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: model.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
          model.window.sendEvent(event)
          if model.focus?.tile == nil { model.canvas?.mouseMoved(with: event) }
        }
        return true
      case "debug.hit":
        let point = model.root.superview.map { _ in NSPoint(x: params["x"] as? Double ?? 0, y: params["y"] as? Double ?? 0) } ?? .zero
        let hit = model.root.hitTest(point)
        var tracking: [JSON] = []
        if let web = model.focus?.tile?.stage?.web {
          for area in web.trackingAreas {
            let rect = web.convert(area.rect, to: nil)
            tracking.append(["x": rect.minX, "yFromTop": model.window.frame.height - rect.maxY, "w": rect.width, "h": rect.height])
          }
        }
        return ["view": hit.map { String(describing: type(of: $0)) } ?? "none", "tracking": tracking] as JSON
      case "debug.window":
        if params["miniaturize"] as? Bool == true { model.window.miniaturize(nil) } else { model.window.deminiaturize(nil) }
        return true
      case "debug.camera":
        model.canvas?.setCamera(Camera(x: params["x"] as? Double ?? 60, y: params["y"] as? Double ?? 60, z: params["z"] as? Double ?? 1))
        return true
      case "debug.scroll":
        model.canvas?.stats.start()
        model.canvas?.playScroll(dy: params["dy"] as? Double ?? -8, dx: params["dx"] as? Double ?? 0, frames: params["frames"] as? Int ?? 240)
        return true
      case "debug.rects":
        let height = model.window.frame.height
        func rect(_ view: NSView?) -> Any {
          guard let view, view.window === model.window else { return NSNull() }
          let frame = view.convert(view.bounds, to: nil)
          return ["x": frame.minX, "y": height - frame.maxY, "w": frame.width, "h": frame.height] as JSON
        }
        return ["window": ["w": model.window.frame.width, "h": height] as JSON, "stage": rect(model.focus?.tile?.stage?.web), "panel": rect(model.focus?.inspector.panelWeb), "list": rect(model.list?.stageWeb)] as JSON
      case "debug.recording":
        // A take parks the window past the edge of the screen, where only scripted events reach it. One point of it
        // stays on the display, because a view's display link stops for a window that's on no display.
        let on = params["on"] as? Bool ?? true
        let window = model.window
        window.ignoresMouseEvents = on
        // While the window is captured, macOS draws a sharing badge over the window buttons, and hiding them hides it.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = on }
        if on, recording == nil, let edge = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) {
          recording = (ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Recording a take"), window.frame, window.collectionBehavior)
          // Mission Control or a change of Space would take the window off the display halfway through.
          window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
          window.orderBack(nil)
          window.setFrameOrigin(NSPoint(x: edge.frame.maxX - 1, y: edge.frame.minY))
        } else if !on, let take = recording {
          ProcessInfo.processInfo.endActivity(take.activity)
          window.collectionBehavior = take.behavior
          window.setFrameOrigin(take.frame.origin)
          recording = nil
        }
        return ["occluded": !window.occlusionState.contains(.visible), "onDisplay": window.screen != nil, "x": window.frame.minX] as JSON
      case "debug.frames":
        guard var stats = model.canvas?.stats else { return [:] as JSON }
        stats.isRecording = false
        model.canvas?.stats.isRecording = params["stop"] as? Bool == true ? false : stats.isRecording
        return stats.summary()
      default:
        throw ToolError("No such method: \(method)")
      }
    }
  #endif
}
