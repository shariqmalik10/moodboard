import Foundation

struct ToolError: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

/// Listens on a private unix socket in Application Support, one JSON message per line. No port is open,
/// and only this user can reach it.
final class SocketServer {
  typealias Handler = (String, JSON) async throws -> Any

  private let handler: Handler
  private var listener: Int32 = -1
  private var source: DispatchSourceRead?
  private var clients: [Int32: Client] = [:]

  private final class Client {
    let fd: Int32
    let source: DispatchSourceRead
    var buffer = Data()

    init(fd: Int32, source: DispatchSourceRead) {
      self.fd = fd
      self.source = source
    }
  }

  init(handler: @escaping Handler) {
    self.handler = handler
  }

  func start() {
    let path = Paths.socket.path
    unlink(path)
    listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0, var address = Self.address(path) else { return }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(listener, 8) == 0 else { return }
    chmod(path, 0o600)
    let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: .main)
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
    source.resume()
    self.source = source
  }

  func stop() {
    source?.cancel()
    clients.values.forEach { close($0.fd) }
    if listener >= 0 { close(listener) }
    unlink(Paths.socket.path)
  }

  static func address(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
  }

  private func accept() {
    let fd = Darwin.accept(listener, nil, nil)
    guard fd >= 0 else { return }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    let client = Client(fd: fd, source: source)
    clients[fd] = client
    source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(fd) } }
    source.resume()
  }

  private func read(_ fd: Int32) {
    guard let client = clients[fd] else { return }
    var chunk = [UInt8](repeating: 0, count: 65536)
    let count = Darwin.read(fd, &chunk, chunk.count)
    if count <= 0 {
      if count == 0 || errno != EAGAIN { drop(client) }
      return
    }
    client.buffer.append(contentsOf: chunk[0..<count])
    while let end = client.buffer.firstIndex(of: 0x0a) {
      let line = client.buffer[client.buffer.startIndex..<end]
      client.buffer = Data(client.buffer[client.buffer.index(after: end)...])
      if !line.isEmpty { handle(Data(line), client) }
    }
  }

  private func handle(_ line: Data, _ client: Client) {
    guard let request = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { return }
    let id = request["id"] ?? NSNull()
    let method = request["method"] as? String ?? ""
    let params = request["params"] as? JSON ?? [:]
    Task {
      var response: JSON = ["id": id]
      do {
        response["result"] = try await handler(method, params)
      } catch {
        response["error"] = error.localizedDescription
      }
      guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
      send(data + Data([0x0a]), to: client)
    }
  }

  private func send(_ data: Data, to client: Client) {
    guard clients[client.fd] != nil else { return }
    _ = fcntl(client.fd, F_SETFL, fcntl(client.fd, F_GETFL) & ~O_NONBLOCK)
    data.withUnsafeBytes { raw in
      var sent = 0
      while sent < raw.count {
        let wrote = write(client.fd, raw.baseAddress?.advanced(by: sent), raw.count - sent)
        if wrote <= 0 { break }
        sent += wrote
      }
    }
    _ = fcntl(client.fd, F_SETFL, fcntl(client.fd, F_GETFL) | O_NONBLOCK)
  }

  private func drop(_ client: Client) {
    client.source.cancel()
    close(client.fd)
    clients[client.fd] = nil
  }
}
