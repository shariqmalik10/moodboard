// Records an app's largest window, with its sheets and other child windows, into a movie.
//   record --pid <pid> --out take.mov [--fps 60] [--mbps 40]
// Prints one JSON line when the first frame arrives, with its wall-clock time, so a script
// that drives the app can line its own timestamps up with the movie. Stops on SIGINT or SIGTERM.

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

struct Options {
  var pid: pid_t = 0
  var out = URL(filePath: "take.mov")
  var fps = 60
  var mbps = 40

  init(_ arguments: [String]) throws {
    var rest = arguments.dropFirst().makeIterator()
    while let flag = rest.next() {
      guard let value = rest.next() else { throw Failure("\(flag) needs a value") }
      switch flag {
      case "--pid": pid = pid_t(value) ?? 0
      case "--out": out = URL(filePath: value)
      case "--fps": fps = Int(value) ?? fps
      case "--mbps": mbps = Int(value) ?? mbps
      default: throw Failure("Unknown option \(flag)")
      }
    }
    if pid == 0 { throw Failure("Pass --pid of the app to record.") }
  }
}

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

func say(_ object: [String: Any]) {
  guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
  FileHandle.standardOutput.write(data + Data("\n".utf8))
}

/// Everything here runs on `queue`, the queue ScreenCaptureKit delivers frames on.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  let queue = DispatchQueue(label: "record")
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private var first: CMTime?
  private var last: (pixels: CVPixelBuffer, time: CMTime)?
  private var frames = 0
  private var dropped = 0
  private var quiet: [String: Int] = [:]
  private let window: CGRect
  private let size: CGSize

  init(out: URL, size: CGSize, window: CGRect, fps: Int, mbps: Int) throws {
    try? FileManager.default.removeItem(at: out)
    writer = try AVAssetWriter(outputURL: out, fileType: .mov)
    input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: Int(size.width),
      AVVideoHeightKey: Int(size.height),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: mbps * 1_000_000,
        AVVideoExpectedSourceFrameRateKey: fps,
      ],
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ])
    input.expectsMediaDataInRealTime = true
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    writer.add(input)
    self.window = window
    self.size = size
    super.init()
    guard writer.startWriting() else { throw Failure(writer.error?.localizedDescription ?? "The movie couldn't be started.") }
    writer.startSession(atSourceTime: .zero)
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sampleBuffer.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let status = (attachments.first?[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:))
    else { return }
    guard status == .complete, let pixels = sampleBuffer.imageBuffer else {
      let name = switch status {
      case .idle: "idle"
      case .blank: "blank"
      case .suspended: "suspended"
      case .started: "started"
      case .stopped: "stopped"
      default: "other"
      }
      quiet[name, default: 0] += 1
      return
    }
    let time = sampleBuffer.presentationTimeStamp
    // A long wait between pictures is either a still window or a stall, and the statuses in between tell which.
    if let first, let last, CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(time, first), last.time)) > 0.3 {
      say(["event": "gap", "from": CMTimeGetSeconds(last.time), "to": CMTimeGetSeconds(CMTimeSubtract(time, first)), "statuses": quiet])
    }
    quiet = [:]
    if first == nil {
      first = time
      // Frame times are on the host clock. Work out the wall-clock time of this frame.
      let now = CMClockGetTime(CMClockGetHostTimeClock())
      let wall = Date().timeIntervalSince1970 * 1000 - CMTimeGetSeconds(CMTimeSubtract(now, time)) * 1000
      say(["event": "started", "wallMs": wall, "width": size.width, "height": size.height, "window": ["x": window.minX, "y": window.minY, "w": window.width, "h": window.height]])
    }
    guard let first else { return }
    let at = CMTimeSubtract(time, first)
    last = (pixels, at)
    guard input.isReadyForMoreMediaData else {
      dropped += 1
      return
    }
    if adaptor.append(pixels, withPresentationTime: at) { frames += 1 } else { dropped += 1 }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    say(["event": "error", "message": error.localizedDescription])
  }

  /// Holds the last picture until now, so the movie lasts as long as the take did.
  func finish() async {
    let (frames, dropped, duration) = await withCheckedContinuation { continuation in
      queue.async {
        if let first = self.first, let last = self.last {
          let now = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), first)
          if CMTimeCompare(now, last.time) > 0, self.input.isReadyForMoreMediaData { self.adaptor.append(last.pixels, withPresentationTime: now) }
        }
        self.input.markAsFinished()
        continuation.resume(returning: (self.frames, self.dropped, self.last.map { CMTimeGetSeconds($0.time) } ?? 0))
      }
    }
    await writer.finishWriting()
    say(["event": "stopped", "frames": frames, "dropped": dropped, "seconds": duration, "status": writer.status == .completed ? "ok" : writer.error?.localizedDescription ?? "failed"])
  }
}

@main
struct Record {
  static func main() async {
    // Single-window capture needs a window server connection, which an app gets for free.
    _ = NSApplication.shared
    do {
      try await run(Options(CommandLine.arguments))
      exit(0)
    } catch {
      say(["event": "error", "message": String(describing: error)])
      exit(1)
    }
  }

  static func run(_ options: Options) async throws {
    // The window can be on another Space, and an app that just launched takes a moment to show one.
    var found: SCWindow?
    for _ in 0..<40 where found == nil {
      let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
      found = content.windows.filter { $0.owningApplication?.processID == options.pid && $0.windowLayer == 0 }.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
      if found == nil { try await Task.sleep(for: .milliseconds(250)) }
    }
    guard let window = found else { throw Failure("The app with pid \(options.pid) has no window.") }
    // A single-window capture leaves out what the system draws over the screen, such as the
    // badge that marks a window as being shared.
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let scale = CGFloat(filter.pointPixelScale)
    let size = CGSize(width: (window.frame.width * scale).rounded(), height: (window.frame.height * scale).rounded())

    let config = SCStreamConfiguration()
    config.includeChildWindows = true
    config.ignoreShadowsSingleWindow = true
    config.width = Int(size.width)
    config.height = Int(size.height)
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    config.showsCursor = false
    config.queueDepth = 8
    config.capturesAudio = false

    let recorder = try Recorder(out: options.out, size: size, window: window.frame, fps: options.fps, mbps: options.mbps)
    let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
    try await stream.startCapture()

    await waitForStop()
    try? await stream.stopCapture()
    await recorder.finish()
  }

  /// Returns on SIGINT or SIGTERM.
  static func waitForStop() async {
    let stops = AsyncStream<Void> { continuation in
      let sources = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { continuation.yield() }
        source.resume()
        return source
      }
      continuation.onTermination = { _ in sources.forEach { $0.cancel() } }
    }
    for await _ in stops { return }
  }
}
