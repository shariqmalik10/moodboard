import AppKit

/// The menu bar. Commands find their target through the responder chain, or through the app delegate.
enum MainMenu {
  static func build() -> NSMenu {
    let bar = NSMenu()

    let app = NSMenu()
    app.addItem(withTitle: "About Moodboard", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    app.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Hide Moodboard", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    others.keyEquivalentModifierMask = [.command, .option]
    app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(withTitle: "Quit Moodboard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    add(app, "Moodboard", to: bar)

    let file = NSMenu(title: "File")
    file.addItem(withTitle: "Add Picture or Film…", action: #selector(AppDelegate.addMaterial(_:)), keyEquivalent: "o")
    file.addItem(withTitle: "Import from Paper…", action: #selector(AppDelegate.importFromPaper(_:)), keyEquivalent: "i")
    let updateAll = file.addItem(withTitle: "Update Changed from Paper", action: #selector(AppDelegate.updateChanged(_:)), keyEquivalent: "u")
    updateAll.keyEquivalentModifierMask = [.command, .shift]
    file.addItem(.separator())
    let connect = file.addItem(withTitle: "Connect Next.js Project…", action: #selector(AppDelegate.connectProject(_:)), keyEquivalent: "o")
    connect.keyEquivalentModifierMask = [.command, .shift]
    file.addItem(.separator())
    file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    add(file, "File", to: bar)

    let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Find…", action: #selector(AppDelegate.findComponent(_:)), keyEquivalent: "f")
    add(edit, "Edit", to: bar)

    let view = NSMenu(title: "View")
    view.addItem(withTitle: "Wall", action: #selector(AppDelegate.showWall(_:)), keyEquivalent: "1")
    view.addItem(withTitle: "Grid", action: #selector(AppDelegate.showGrid(_:)), keyEquivalent: "2")
    view.addItem(withTitle: "List", action: #selector(AppDelegate.showList(_:)), keyEquivalent: "3")
    view.addItem(.separator())
    view.addItem(withTitle: "Previous Component", action: #selector(AppDelegate.previousComponent(_:)), keyEquivalent: "[")
    view.addItem(withTitle: "Next Component", action: #selector(AppDelegate.nextComponent(_:)), keyEquivalent: "]")
    view.addItem(.separator())
    view.addItem(withTitle: "Zoom In", action: #selector(AppDelegate.zoomInWall(_:)), keyEquivalent: "+")
    view.addItem(withTitle: "Zoom Out", action: #selector(AppDelegate.zoomOutWall(_:)), keyEquivalent: "-")
    view.addItem(withTitle: "Back to the Start", action: #selector(AppDelegate.goHome(_:)), keyEquivalent: "0")
    view.addItem(.separator())
    let fullScreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    add(view, "View", to: bar)

    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    add(window, "Window", to: bar)
    NSApp.windowsMenu = window

    let help = NSMenu(title: "Help")
    help.addItem(withTitle: "Welcome to Moodboard", action: #selector(AppDelegate.showWelcome(_:)), keyEquivalent: "")
    help.addItem(withTitle: "What's New in Moodboard", action: #selector(AppDelegate.showWhatsNew(_:)), keyEquivalent: "")
    help.addItem(withTitle: "Moodboard on GitHub", action: #selector(AppDelegate.openRepository(_:)), keyEquivalent: "")
    add(help, "Help", to: bar)
    NSApp.helpMenu = help

    return bar
  }

  private static func add(_ menu: NSMenu, _ title: String, to bar: NSMenu) {
    menu.title = title
    let item = bar.addItem(withTitle: title, action: nil, keyEquivalent: "")
    item.submenu = menu
  }
}

extension AppDelegate {
  @objc func addMaterial(_ sender: Any?) { model?.chrome?.chooseMaterial() }
  @objc func importFromPaper(_ sender: Any?) { model?.chrome?.state.onPaper() }
  @objc func connectProject(_ sender: Any?) { model?.projects.choose() }
  @objc func showWelcome(_ sender: Any?) { model?.welcome.show() }
  @objc func checkForUpdates(_ sender: Any?) { updater?.check(quietly: false) }
  @objc func showWhatsNew(_ sender: Any?) { model?.whatsNew.show() }
  @objc func openRepository(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/shariqmalik10/moodboard")!) }
  @objc func zoomInWall(_ sender: Any?) { zoom(by: 1) }
  @objc func zoomOutWall(_ sender: Any?) { zoom(by: -1) }
  @objc func findComponent(_ sender: Any?) { model?.startSearch() }
  @objc func updateChanged(_ sender: Any?) { Task { await model?.importer?.updateChanged() } }
  @objc func previousComponent(_ sender: Any?) { model?.list?.selectNeighbor(by: -1) }
  @objc func nextComponent(_ sender: Any?) { model?.list?.selectNeighbor(by: 1) }

  /// The Wall zooms. Grid changes the size of its cards.
  private func zoom(by step: Int) {
    guard let canvas = model?.canvas else { return }
    if canvas.mode == .grid {
      canvas.changeDensity(by: step)
      model?.chrome?.boardChanged()
    } else {
      canvas.zoomFromCenter(factor: step > 0 ? 1.2 : 1 / 1.2)
    }
  }
  @objc func goHome(_ sender: Any?) { model?.canvas?.goHome() }
  @objc func showWall(_ sender: Any?) { model?.show(.wall) }
  @objc func showGrid(_ sender: Any?) { model?.show(.grid) }
  @objc func showList(_ sender: Any?) { model?.show(.list) }
}

extension AppDelegate: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    let current = model?.chrome?.state.mode ?? .wall
    switch item.action {
    case #selector(showWall(_:)): item.state = current == .wall ? .on : .off
    case #selector(showGrid(_:)): item.state = current == .grid ? .on : .off
    case #selector(showList(_:)): item.state = current == .list ? .on : .off
    case #selector(zoomInWall(_:)), #selector(zoomOutWall(_:)): return current != .list
    case #selector(previousComponent(_:)), #selector(nextComponent(_:)): return current == .list
    case #selector(updateChanged(_:)): return (model?.chrome?.state.counts[.paperChanged] ?? 0) > 0
    case #selector(goHome(_:)): return current != .list
    default: break
    }
    return true
  }
}
