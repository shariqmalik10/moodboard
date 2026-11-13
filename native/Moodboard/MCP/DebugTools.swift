#if DEBUG
  import AppKit

  /// The `debug.` methods the scripts in tools/ drive the running wall with. Not part of the MCP server.
  extension Tools {
    func debug(_ method: String, _ params: JSON) async throws -> Any {
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
        return ["status": run.status, "active": run.isWorking, "session": run.sessionId ?? "", "changed": run.changedFiles.sorted()] as JSON
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
        if let event = Synthetic.key(text, keyCode: code, flags: flags, in: model.window) {
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
        model.focus?.perform(.remove)
        return true
      case "debug.update":
        model.focus?.perform(.updateFromPaper)
        return true
      case "debug.paper":
        model.chrome?.state.showsPaper = params["show"] as? Bool ?? true
        return true
      case "debug.click":
        let window = params["popover"] as? Bool == true ? NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible } : params["sheet"] as? Bool == true ? model.window.attachedSheet : model.window
        guard let window else { throw ToolError("That window isn't showing.") }
        let point = NSPoint(x: params["x"] as? Double ?? 0, y: window.frame.height - (params["y"] as? Double ?? 0))
        guard let down = Synthetic.mouse(.leftMouseDown, at: point, in: window), let up = Synthetic.mouse(.leftMouseUp, at: point, in: window) else { return false }
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
        if let down = Synthetic.mouse(.leftMouseDown, at: from, in: window) { view.mouseDown(with: down) }
        for step in 1...steps {
          try await Task.sleep(for: .milliseconds(16))
          let progress = Double(step) / Double(steps)
          let along = eases ? 0.5 - cos(.pi * progress) / 2 : progress
          if let drag = Synthetic.mouse(.leftMouseDragged, at: NSPoint(x: from.x + across * along, y: from.y), in: window) { view.mouseDragged(with: drag) }
        }
        if let up = Synthetic.mouse(.leftMouseUp, at: NSPoint(x: from.x + across, y: from.y), in: window) { view.mouseUp(with: up) }
        return true
      case "debug.view":
        let filter = (params["project"] as? String).map { $0 == "all" ? ProjectFilter.all : .project($0) }
        model.show((params["mode"] as? String).flatMap(ViewMode.init(rawValue:)), filter: filter)
        return true
      case "debug.list":
        if let id = params["select"] as? String { model.list?.select(id) }
        return model.list?.debugState() ?? [:] as JSON
      case "debug.shortcut":
        guard let key = params["key"] as? String, let event = Synthetic.key(key, keyCode: 0, flags: [.command], in: model.window) else { throw ToolError("Which key?") }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
      case "debug.arrow":
        let down = params["down"] as? Bool ?? true
        let glyph = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        if let event = Synthetic.key(glyph, keyCode: down ? 125 : 126, flags: [.function, .numericPad], in: model.window) {
          model.window.sendEvent(event)
        }
        return true
      case "debug.resize":
        model.window.setContentSize(NSSize(width: params["w"] as? Double ?? 1440, height: params["h"] as? Double ?? 920))
        return ["w": model.window.contentView?.bounds.width ?? 0, "h": model.window.contentView?.bounds.height ?? 0] as JSON
      case "debug.chrome":
        let counts = model.chrome?.state.counts ?? [:]
        return ["mode": model.chrome?.state.view.mode.rawValue ?? "", "projects": model.chrome?.state.projects ?? [], "compact": model.chrome?.state.isCompact ?? false, "density": model.canvas?.density.rawValue ?? -1, "query": model.chrome?.state.view.refinement.query ?? "", "attention": model.chrome?.state.view.refinement.attention?.rawValue ?? NSNull(), "counts": Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })] as JSON
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
        model.focus?.perform(.holdBefore(params["on"] as? Bool ?? false))
        return true
      case "debug.revert":
        let state = model.focus?.inspector.model
        if let dial = params["dial"] as? String, let change = state?.changes.first(where: { $0.dial == dial }) { model.focus?.perform(.revert(change)) } else { model.focus?.perform(.revertAll) }
        return true
      case "debug.typeNote":
        model.focus?.inspector.model.note = params["note"] as? String ?? ""
        model.focus?.perform(.noteEdited(params["note"] as? String ?? ""))
        return true
      case "debug.action":
        let action: InspectorAction
        switch params["name"] as? String {
        case "copyBrief": action = .copyBrief
        case "copyChanges": action = .copyChanges
        case "toggleBuilt": action = .toggleBuilt
        case "dismissLost": action = .dismissLost
        case "startOver": action = .startOver
        default: throw ToolError("Which action?")
        }
        model.focus?.perform(action)
        return true
      case "debug.paperCheck":
        await model.paperWatch?.check()
        return true
      case "debug.updateChanged":
        await model.importer?.updateChanged()
        return true
      case "debug.option":
        let flags: NSEvent.ModifierFlags = params["on"] as? Bool == true ? [.option] : []
        if let event = Synthetic.key("", keyCode: 58, flags: flags, type: .flagsChanged, in: model.window) { NSApp.sendEvent(event) }
        return model.focus?.inspector.model.showsBefore ?? false
      case "debug.commandReturn":
        guard let event = Synthetic.key("\r", keyCode: 36, flags: [.command], in: model.window) else { return false }
        return model.window.performKeyEquivalent(with: event)
      case "debug.windowKey":
        let text = params["text"] as? String ?? "\r"
        guard let event = Synthetic.key(text, keyCode: params["keyCode"] as? Int ?? 36, in: model.window) else { return false }
        model.window.sendEvent(event)
        return true
      case "debug.firstResponder":
        return model.window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
      case "debug.move":
        let point = NSPoint(x: params["x"] as? Double ?? 0, y: model.window.frame.height - (params["y"] as? Double ?? 0))
        if let event = Synthetic.mouse(.mouseMoved, at: point, in: model.window, clickCount: 0) {
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
        // Reading the frames ends the recording, so the display link can pause again.
        guard let canvas = model.canvas else { return [:] as JSON }
        canvas.stats.isRecording = false
        return canvas.stats.summary()
      default:
        throw ToolError("No such method: \(method)")
      }
    }
  }

  /// Events made up for the scripts, as if the person had pressed or moved something in this window.
  private enum Synthetic {
    static func key(_ text: String, keyCode: Int, flags: NSEvent.ModifierFlags = [], type: NSEvent.EventType = .keyDown, in window: NSWindow) -> NSEvent? {
      NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: UInt16(keyCode))
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int = 1) -> NSEvent? {
      NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: clickCount > 0 ? 1 : 0)
    }
  }
#endif
