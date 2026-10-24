import Cocoa
import FlutterMacOS

private let protocolChannelName = "com.deploydash.desktop/protocol"
private let deliverProtocolUriMethod = "deliverProtocolUri"
private let protocolIngressReadyMethod = "protocolIngressReady"
private let desktopUpdateChannelName = "com.deploydash.desktop/updates"
private let checkForUpdatesMethod = "checkForUpdates"

final class ProtocolRelayCoordinator {
  static let shared = ProtocolRelayCoordinator()

  private var channel: FlutterMethodChannel?
  private var pendingUrls: [String] = []
  private var ingressReady = false

  private init() {}

  func attach(to messenger: FlutterBinaryMessenger) {
    let relayChannel = FlutterMethodChannel(
      name: protocolChannelName,
      binaryMessenger: messenger
    )
    relayChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "deallocated", message: nil, details: nil))
        return
      }
      if call.method == protocolIngressReadyMethod {
        self.ingressReady = true
        self.flushPendingUrls()
        result(nil)
        return
      }
      result(FlutterMethodNotImplemented)
    }
    channel = relayChannel
    flushPendingUrls()
  }

  func handle(urls: [URL]) -> Bool {
    var handled = false
    for url in urls where url.scheme == "deploydash" {
      handled = true
      deliverOrQueue(url.absoluteString)
    }
    return handled
  }

  private func deliverOrQueue(_ url: String) {
    guard !url.isEmpty else {
      return
    }
    guard ingressReady, let channel else {
      pendingUrls.append(url)
      return
    }
    channel.invokeMethod(deliverProtocolUriMethod, arguments: url)
  }

  private func flushPendingUrls() {
    guard ingressReady, let channel, !pendingUrls.isEmpty else {
      return
    }
    let urls = pendingUrls
    pendingUrls.removeAll()
    for url in urls {
      channel.invokeMethod(deliverProtocolUriMethod, arguments: url)
    }
  }
}

final class DesktopUpdateCoordinator {
  static let shared = DesktopUpdateCoordinator()

  private init() {}

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: desktopUpdateChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == checkForUpdatesMethod else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let feedUrl = arguments["feedUrl"] as? String,
        !feedUrl.isEmpty
      else {
        result(FlutterError(
          code: "invalid_sparkle_feed",
          message: "The Sparkle update feed is missing.",
          details: nil
        ))
        return
      }
      var errorBuffer = [CChar](repeating: 0, count: 1024)
      let started = errorBuffer.withUnsafeMutableBufferPointer { buffer in
        feedUrl.withCString { pointer in
          deploydash_sparkle_check_for_updates(
            pointer,
            buffer.baseAddress,
            buffer.count
          )
        }
      }
      if started == 1 {
        result(true)
        return
      }
      result(FlutterError(
        code: "sparkle_unavailable",
        message: String(cString: errorBuffer),
        details: nil
      ))
    }
  }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    ProtocolRelayCoordinator.shared.attach(to: flutterViewController.engine.binaryMessenger)
    DesktopUpdateCoordinator.shared.attach(to: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
