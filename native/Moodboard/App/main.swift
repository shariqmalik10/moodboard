import AppKit

if CommandLine.arguments.contains("--mcp") {
  MCPBridge.run()
}

let application = NSApplication.shared
// Tests load this app as their host. They must not open a second wall, which would take the socket.
let delegate = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? AppDelegate() : nil
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
