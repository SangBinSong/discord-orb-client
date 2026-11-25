import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let channelName = "discord_orb/window"
  private static let collapsedOrbSize = NSSize(width: 80, height: 80)
  private static let mainWindowSize = NSSize(width: 480, height: 680)
  private static let defaultMargin: CGFloat = 24
  private static let escapeKeyCode: UInt16 = 53
  private static let dragThreshold: CGFloat = 4.0

  private weak var flutterViewController: FlutterViewController?
  private var windowChannel: FlutterMethodChannel?
  private var isOverlayMode = false
  private var isExpanded = false
  private var collapsedOrigin: NSPoint?
  private var lastProgrammaticExpandedOrigin: NSPoint?
  private var didMoveWhileExpanded = false
  private var keyMonitor: Any?
  private var mouseMonitor: Any?
  private var pendingDragEvent: NSEvent?
  private var pendingDragStartScreenPoint: NSPoint?
  private var isNativeDragging = false
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
    if let monitor = mouseMonitor {
      NSEvent.removeMonitor(monitor)
      mouseMonitor = nil
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
    lastProgrammaticExpandedOrigin = nil
    didMoveWhileExpanded = false
    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
    isNativeDragging = false
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

    mouseMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      guard let self = self else { return event }
      return self.handleMouseEvent(event)
    }

    let center = NotificationCenter.default
    localObservers.append(
      center.addObserver(
        forName: NSWindow.didMoveNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        guard let self = self, self.isOverlayMode else { return }
        if self.isExpanded {
          if let initialOrigin = self.lastProgrammaticExpandedOrigin,
             self.frame.origin == initialOrigin {
            return
          }
          self.lastProgrammaticExpandedOrigin = nil
          self.didMoveWhileExpanded = true
        }
        self.syncCollapsedOriginFromCurrentFrame()
      }
    )
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
    case "startOrbDrag":
      startOrbDragFromChannel()
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
    if isOverlayMode && isExpanded {
      if didMoveWhileExpanded ||
          (lastProgrammaticExpandedOrigin != nil && frame.origin != lastProgrammaticExpandedOrigin) {
        syncCollapsedOriginFromCurrentFrame()
      }
    }
    configureOverlayWindow()
    let targetSize = Self.collapsedOrbSize
    let origin = collapsedOrigin ?? defaultCollapsedOrigin(for: targetSize)
    let targetFrame = clampFrameToVisibleScreen(NSRect(origin: origin, size: targetSize))

    collapsedOrigin = targetFrame.origin
    lastProgrammaticExpandedOrigin = nil
    didMoveWhileExpanded = false
    isExpanded = false
    setFrame(targetFrame, display: true, animate: false)
    invalidateShadow()
    orderFrontRegardless()
  }

  private func expandPanelWindow(size: NSSize) {
    configureOverlayWindow()
    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
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
    didMoveWhileExpanded = false
    lastProgrammaticExpandedOrigin = clampedFrame.origin
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
    if isExpanded {
      lastProgrammaticExpandedOrigin = nil
      didMoveWhileExpanded = true
    }
    syncCollapsedOriginFromCurrentFrame()
  }

  private func isPointInOrbDragRegion(_ pointInWindow: NSPoint) -> Bool {
    if !isExpanded {
      return true
    }
    let width = frame.width
    let height = frame.height
    return pointInWindow.x >= width - Self.collapsedOrbSize.width &&
      pointInWindow.x <= width &&
      pointInWindow.y >= height - Self.collapsedOrbSize.height &&
      pointInWindow.y <= height
  }

  private func syncCollapsedOriginFromCurrentFrame() {
    guard isOverlayMode else { return }
    let rawOrigin: NSPoint
    if isExpanded {
      rawOrigin = NSPoint(
        x: frame.maxX - Self.collapsedOrbSize.width,
        y: frame.maxY - Self.collapsedOrbSize.height
      )
    } else {
      rawOrigin = frame.origin
    }
    let clampedOrbFrame = clampFrameToVisibleScreen(
      NSRect(origin: rawOrigin, size: Self.collapsedOrbSize)
    )
    collapsedOrigin = clampedOrbFrame.origin
  }

  private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
    guard isOverlayMode, event.window === self else {
      if event.type == .leftMouseUp {
        pendingDragEvent = nil
        pendingDragStartScreenPoint = nil
      }
      return event
    }

    switch event.type {
    case .leftMouseDown:
      if isPointInOrbDragRegion(event.locationInWindow) {
        pendingDragEvent = event
        pendingDragStartScreenPoint = NSEvent.mouseLocation
      } else {
        pendingDragEvent = nil
        pendingDragStartScreenPoint = nil
      }
      return event

    case .leftMouseDragged:
      guard !isNativeDragging,
            let downEvent = pendingDragEvent,
            let startPoint = pendingDragStartScreenPoint else {
        return event
      }
      let currentPoint = NSEvent.mouseLocation
      let distance = hypot(currentPoint.x - startPoint.x, currentPoint.y - startPoint.y)
      if distance >= Self.dragThreshold {
        beginNativeDrag(with: downEvent)
        return nil
      }
      return event

    case .leftMouseUp:
      pendingDragEvent = nil
      pendingDragStartScreenPoint = nil
      return event

    default:
      return event
    }
  }

  private func startOrbDragFromChannel() {
    guard isOverlayMode, !isNativeDragging else {
      return
    }
    let candidateEvent = pendingDragEvent ?? NSApp.currentEvent
    guard let dragEvent = candidateEvent,
          dragEvent.type == .leftMouseDown || dragEvent.type == .leftMouseDragged else {
      return
    }
    if isExpanded && pendingDragEvent == nil &&
        !isPointInOrbDragRegion(dragEvent.locationInWindow) {
      return
    }
    beginNativeDrag(with: dragEvent)
  }

  private func beginNativeDrag(with event: NSEvent) {
    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
    isNativeDragging = true

    sendSyntheticMouseUpOutsideWindow()
    performDrag(with: event)

    isNativeDragging = false
    let clampedFrame = clampFrameToVisibleScreen(frame)
    if clampedFrame.origin != frame.origin || clampedFrame.size != frame.size {
      setFrame(clampedFrame, display: true, animate: false)
    }
    if isExpanded {
      lastProgrammaticExpandedOrigin = nil
      didMoveWhileExpanded = true
    }
    syncCollapsedOriginFromCurrentFrame()

    sendSyntheticMouseUpOutsideWindow()
  }

  private func sendSyntheticMouseUpOutsideWindow() {
    guard let syntheticUp = NSEvent.mouseEvent(
      with: .leftMouseUp,
      location: NSPoint(x: -1000, y: -1000),
      modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 0
    ) else {
      return
    }
    flutterViewController?.view.mouseUp(with: syntheticUp)
  }

  private func hideOrbWindow() {
    isExpanded = false
    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
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
