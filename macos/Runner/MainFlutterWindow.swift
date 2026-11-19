import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let channelName = "discord_orb/window"
  private static let collapsedOrbSize = NSSize(width: 64, height: 64)
  private static let defaultMargin: CGFloat = 24
  private static let escapeKeyCode: UInt16 = 53

  private var windowChannel: FlutterMethodChannel?
  private var isExpanded = false
  private var collapsedOrigin: NSPoint?
  private var keyMonitor: Any?
  private var localObservers: [NSObjectProtocol] = []
  private var workspaceObservers: [NSObjectProtocol] = []
  private var distributedObservers: [NSObjectProtocol] = []

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    flutterViewController.backgroundColor = .clear
    flutterViewController.view.wantsLayer = true
    flutterViewController.view.layer?.backgroundColor = NSColor.clear.cgColor

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    configureOverlayWindow()
    registerWindowChannel(messenger: flutterViewController.engine.binaryMessenger)
    installEventMonitorsAndObservers()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  deinit {
    if let monitor = keyMonitor {
      NSEvent.removeMonitor(monitor)
      keyMonitor = nil
    }
    for observer in localObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    localObservers.removeAll()

    for observer in workspaceObservers {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    workspaceObservers.removeAll()

    for observer in distributedObservers {
      DistributedNotificationCenter.default().removeObserver(observer)
    }
    distributedObservers.removeAll()

    windowChannel?.setMethodCallHandler(nil)
    windowChannel = nil
  }

  private func configureOverlayWindow() {
    styleMask = [.borderless]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
  }

  private func registerWindowChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleMethodCall(call, result: result)
    }
    windowChannel = channel
  }

  private func installEventMonitorsAndObservers() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self else { return event }
      if event.keyCode == Self.escapeKeyCode && self.isExpanded {
        self.notifyPanelDismissRequested()
        return nil
      }
      return event
    }

    let center = NotificationCenter.default
    localObservers.append(
      center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        guard let self = self, self.isExpanded else { return }
        self.notifyPanelDismissRequested()
      }
    )
    localObservers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: NSApp,
        queue: .main
      ) { [weak self] _ in
        guard let self = self, self.isExpanded else { return }
        self.notifyPanelDismissRequested()
      }
    )

    distributedObservers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.screenIsLocked"),
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.notifyLockOrSleep()
      }
    )

    workspaceObservers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.screensDidSleepNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.notifyLockOrSleep()
      }
    )
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "hasOverlayPermission":
      result(true)
    case "openOverlayPermissionSettings":
      result(nil)
    case "showCollapsedOrb", "collapsePanel":
      showCollapsedOrbWindow()
      result(nil)
    case "expandPanel":
      guard let args = call.arguments as? [String: Any],
            let width = (args["width"] as? NSNumber)?.doubleValue,
            let height = (args["height"] as? NSNumber)?.doubleValue,
            width > 0,
            height > 0 else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "expandPanel requires positive numeric width and height",
            details: nil
          )
        )
        return
      }
      expandPanelWindow(size: NSSize(width: width, height: height))
      result(nil)
    case "hideOrb":
      hideOrbWindow()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func showCollapsedOrbWindow() {
    let targetSize = Self.collapsedOrbSize
    let origin = collapsedOrigin ?? defaultCollapsedOrigin(for: targetSize)
    let targetFrame = clampFrameToVisibleScreen(NSRect(origin: origin, size: targetSize))

    collapsedOrigin = targetFrame.origin
    isExpanded = false
    setFrame(targetFrame, display: true, animate: false)
    orderFrontRegardless()
  }

  private func expandPanelWindow(size: NSSize) {
    if !isExpanded {
      if frame.size == Self.collapsedOrbSize {
        collapsedOrigin = frame.origin
      } else if collapsedOrigin == nil {
        collapsedOrigin = defaultCollapsedOrigin(for: Self.collapsedOrbSize)
      }
    }

    let anchorOrigin = collapsedOrigin ?? defaultCollapsedOrigin(for: Self.collapsedOrbSize)
    let desiredFrame = NSRect(
      x: anchorOrigin.x + Self.collapsedOrbSize.width - size.width,
      y: anchorOrigin.y,
      width: size.width,
      height: size.height
    )
    let clampedFrame = clampFrameToVisibleScreen(desiredFrame)

    isExpanded = true
    setFrame(clampedFrame, display: true, animate: false)
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  private func hideOrbWindow() {
    isExpanded = false
    orderOut(nil)
  }

  private func activeVisibleFrame() -> NSRect? {
    return (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
  }

  private func defaultCollapsedOrigin(for size: NSSize) -> NSPoint {
    guard let visible = activeVisibleFrame() else {
      return NSPoint(x: Self.defaultMargin, y: Self.defaultMargin)
    }
    return NSPoint(
      x: visible.maxX - size.width - Self.defaultMargin,
      y: visible.minY + Self.defaultMargin
    )
  }

  private func clampFrameToVisibleScreen(_ frame: NSRect) -> NSRect {
    guard let visible = activeVisibleFrame() else {
      return frame
    }
    let width = min(frame.width, visible.width)
    let height = min(frame.height, visible.height)
    let x = min(max(frame.origin.x, visible.minX), visible.maxX - width)
    let y = min(max(frame.origin.y, visible.minY), visible.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  private func notifyPanelDismissRequested() {
    DispatchQueue.main.async { [weak self] in
      self?.windowChannel?.invokeMethod("onPanelDismissRequested", arguments: nil)
    }
  }

  private func notifyLockOrSleep() {
    DispatchQueue.main.async { [weak self] in
      self?.windowChannel?.invokeMethod("onLockOrSleep", arguments: nil)
    }
  }
}
