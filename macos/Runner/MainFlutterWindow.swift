import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let channelName = "discord_orb/window"
  private static let collapsedOrbSize = NSSize(width: 80, height: 80)
  private static let mainWindowSize = NSSize(width: 480, height: 680)
  private static let defaultMargin: CGFloat = 24
  private static let escapeKeyCode: UInt16 = 53

  private weak var flutterViewController: FlutterViewController?
  private var windowChannel: FlutterMethodChannel?
  private var isOverlayMode = false
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
    self.flutterViewController = flutterViewController
    self.contentViewController = flutterViewController

    configureMainWindow(centerWindow: true)
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

  private func configureMainWindow(centerWindow: Bool) {
    isOverlayMode = false
    styleMask = [.titled, .closable, .miniaturizable, .resizable]
    title = "Discord Orb"
    isOpaque = true
    backgroundColor = .windowBackgroundColor
    hasShadow = true
    level = .normal
    collectionBehavior = []
    flutterViewController?.backgroundColor = .windowBackgroundColor
    contentView?.wantsLayer = true
    contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    if centerWindow {
      let targetFrame = centeredFrameInVisibleScreen(size: Self.mainWindowSize)
      setFrame(targetFrame, display: true, animate: false)
    }
    invalidateShadow()
  }

  private func configureOverlayWindow() {
    isOverlayMode = true
    styleMask = [.borderless]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    flutterViewController?.backgroundColor = .clear
    contentView?.wantsLayer = true
    contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    invalidateShadow()
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
      if event.keyCode == Self.escapeKeyCode && self.isExpanded && self.isOverlayMode {
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
        guard let self = self, self.isExpanded, self.isOverlayMode else { return }
        self.notifyPanelDismissRequested()
      }
    )
    localObservers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: NSApp,
        queue: .main
      ) { [weak self] _ in
        guard let self = self, self.isExpanded, self.isOverlayMode else { return }
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
    case "moveOrb":
      guard let args = call.arguments as? [String: Any],
            let dx = (args["dx"] as? NSNumber)?.doubleValue,
            let dy = (args["dy"] as? NSNumber)?.doubleValue,
            dx.isFinite,
            dy.isFinite else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "moveOrb requires finite numeric dx and dy",
            details: nil
          )
        )
        return
      }
      moveOrbWindow(dx: CGFloat(dx), dy: CGFloat(dy))
      result(nil)
    case "showMainWindow":
      showMainWindow()
      result(nil)
    case "hideOrb":
      hideOrbWindow()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func showMainWindow() {
    isExpanded = false
    let shouldCenter =
      isOverlayMode ||
      frame.width < Self.mainWindowSize.width ||
      frame.height < Self.mainWindowSize.height
    configureMainWindow(centerWindow: shouldCenter)
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  private func showCollapsedOrbWindow() {
    configureOverlayWindow()
    let targetSize = Self.collapsedOrbSize
    let origin = collapsedOrigin ?? defaultCollapsedOrigin(for: targetSize)
    let targetFrame = clampFrameToVisibleScreen(NSRect(origin: origin, size: targetSize))

    collapsedOrigin = targetFrame.origin
    isExpanded = false
    setFrame(targetFrame, display: true, animate: false)
    invalidateShadow()
    orderFrontRegardless()
  }

  private func expandPanelWindow(size: NSSize) {
    configureOverlayWindow()
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
      y: anchorOrigin.y + Self.collapsedOrbSize.height - size.height,
      width: size.width,
      height: size.height
    )
    let clampedFrame = clampFrameToVisibleScreen(desiredFrame)

    isExpanded = true
    setFrame(clampedFrame, display: true, animate: false)
    invalidateShadow()
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  private func moveOrbWindow(dx: CGFloat, dy: CGFloat) {
    let desiredFrame = NSRect(
      x: frame.origin.x + dx,
      y: frame.origin.y - dy,
      width: frame.width,
      height: frame.height
    )
    let clampedFrame = clampFrameToVisibleScreen(desiredFrame)
    setFrame(clampedFrame, display: true, animate: false)
    if !isExpanded {
      collapsedOrigin = clampedFrame.origin
    }
  }

  private func hideOrbWindow() {
    isExpanded = false
    orderOut(nil)
  }

  private func activeVisibleFrame() -> NSRect? {
    return (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
  }

  private func centeredFrameInVisibleScreen(size: NSSize) -> NSRect {
    guard let visible = activeVisibleFrame() else {
      return NSRect(origin: NSPoint(x: 120, y: 120), size: size)
    }
    let width = min(size.width, visible.width)
    let height = min(size.height, visible.height)
    let origin = NSPoint(
      x: visible.midX - (width / 2),
      y: visible.midY - (height / 2)
    )
    return clampFrameToVisibleScreen(NSRect(origin: origin, size: NSSize(width: width, height: height)))
  }

  private func defaultCollapsedOrigin(for size: NSSize) -> NSPoint {
    guard let visible = activeVisibleFrame() else {
      return NSPoint(x: Self.defaultMargin, y: Self.defaultMargin)
    }
    return NSPoint(
      x: visible.maxX - size.width - Self.defaultMargin,
      y: visible.maxY - size.height - Self.defaultMargin
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
