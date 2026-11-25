import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private static let channelName = "discord_orb/window"
  private static let collapsedOrbSize = NSSize(width: 80, height: 80)
  private static let mainWindowSize = NSSize(width: 480, height: 680)
  private static let minExpandedSize = NSSize(width: 260, height: 240)
  private static let maxExpandedSize = NSSize(width: 720, height: 800)
  private static let persistedWidthDefaultsKey = "discord_orb.expanded_panel_width"
  private static let persistedHeightDefaultsKey = "discord_orb.expanded_panel_height"
  private static let defaultMargin: CGFloat = 24
  private static let escapeKeyCode: UInt16 = 53
  private static let dragThreshold: CGFloat = 4.0

  private enum ExpandDirection: String {
    case below
    case above
  }

  private struct ResizeEdges: OptionSet {
    let rawValue: Int
    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let top = ResizeEdges(rawValue: 1 << 2)
    static let bottom = ResizeEdges(rawValue: 1 << 3)

    init(rawValue: Int) {
      self.rawValue = rawValue
    }

    init?(wireName: String) {
      switch wireName {
      case "left": self = [.left]
      case "right": self = [.right]
      case "top": self = [.top]
      case "bottom": self = [.bottom]
      case "topLeft": self = [.top, .left]
      case "topRight": self = [.top, .right]
      case "bottomLeft": self = [.bottom, .left]
      case "bottomRight": self = [.bottom, .right]
      default: return nil
      }
    }
  }

  private weak var flutterViewController: FlutterViewController?
  private var windowChannel: FlutterMethodChannel?
  private var isOverlayMode = false
  private var isExpanded = false
  private var currentExpandDirection: ExpandDirection = .below
  private var persistedExpandedSize: NSSize?
  private var collapsedOrigin: NSPoint?
  private var lastProgrammaticExpandedOrigin: NSPoint?
  private var didMoveWhileExpanded = false
  private var keyMonitor: Any?
  private var mouseMonitor: Any?
  private var pendingDragEvent: NSEvent?
  private var pendingDragStartScreenPoint: NSPoint?
  private var isNativeDragging = false
  private var activeResizeEdges: ResizeEdges = []
  private var resizeStartScreenPoint: NSPoint?
  private var resizeStartFrame: NSRect?
  private var isShowingResizeCursor = false
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
    loadPersistedExpandedSize()
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
    currentExpandDirection = .below
    lastProgrammaticExpandedOrigin = nil
    didMoveWhileExpanded = false
    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
    isNativeDragging = false
    activeResizeEdges = []
    resizeStartScreenPoint = nil
    resizeStartFrame = nil
    resetResizeCursorIfNeeded()
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
    acceptsMouseMovedEvents = true
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
        guard let self = self, self.isExpanded, self.isOverlayMode, self.activeResizeEdges.isEmpty else { return }
        self.notifyPanelDismissRequested()
      }
    )
    localObservers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: NSApp,
        queue: .main
      ) { [weak self] _ in
        guard let self = self, self.isExpanded, self.isOverlayMode, self.activeResizeEdges.isEmpty else { return }
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
      let direction = expandPanelWindow(size: NSSize(width: width, height: height))
      result(direction.rawValue)
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
    case "startPanelResize":
      guard let args = call.arguments as? [String: Any],
            let edgeName = args["edge"] as? String,
            let edges = ResizeEdges(wireName: edgeName) else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "startPanelResize requires a valid edge name",
            details: nil
          )
        )
        return
      }
      result(nil)
      startNativePanelResize(edges: edges)
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
    currentExpandDirection = .below
    lastProgrammaticExpandedOrigin = nil
    didMoveWhileExpanded = false
    isExpanded = false
    activeResizeEdges = []
    resizeStartScreenPoint = nil
    resizeStartFrame = nil
    resetResizeCursorIfNeeded()
    setFrame(targetFrame, display: true, animate: false)
    invalidateShadow()
    orderFrontRegardless()
  }

  private func clampExpandedSize(_ size: NSSize) -> NSSize {
    let clampedWidth = min(max(size.width, Self.minExpandedSize.width), Self.maxExpandedSize.width)
    let clampedHeight = min(max(size.height, Self.minExpandedSize.height), Self.maxExpandedSize.height)
    if let visible = activeVisibleFrame() {
      return NSSize(
        width: min(clampedWidth, visible.width),
        height: min(clampedHeight, visible.height)
      )
    }
    return NSSize(width: clampedWidth, height: clampedHeight)
  }

  private func expandPanelWindow(size: NSSize) -> ExpandDirection {
    configureOverlayWindow()
    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
    activeResizeEdges = []
    resizeStartScreenPoint = nil
    resizeStartFrame = nil
    resetResizeCursorIfNeeded()

    if !isExpanded {
      if frame.size == Self.collapsedOrbSize {
        collapsedOrigin = frame.origin
      } else if collapsedOrigin == nil {
        collapsedOrigin = defaultCollapsedOrigin(for: Self.collapsedOrbSize)
      }
    }

    let targetSize = clampExpandedSize(persistedExpandedSize ?? size)
    let anchorOrigin = collapsedOrigin ?? defaultCollapsedOrigin(for: Self.collapsedOrbSize)

    let direction: ExpandDirection
    if let visible = activeVisibleFrame() {
      let spaceBelow = (anchorOrigin.y + Self.collapsedOrbSize.height) - visible.minY
      let spaceAbove = visible.maxY - anchorOrigin.y
      if spaceBelow >= targetSize.height {
        direction = .below
      } else if spaceAbove > spaceBelow {
        direction = .above
      } else {
        direction = .below
      }
    } else {
      direction = .below
    }

    let desiredY = direction == .above
      ? anchorOrigin.y
      : anchorOrigin.y + Self.collapsedOrbSize.height - targetSize.height
    let desiredFrame = NSRect(
      x: anchorOrigin.x + Self.collapsedOrbSize.width - targetSize.width,
      y: desiredY,
      width: targetSize.width,
      height: targetSize.height
    )
    let clampedFrame = clampFrameToVisibleScreen(desiredFrame)

    currentExpandDirection = direction
    isExpanded = true
    didMoveWhileExpanded = false
    lastProgrammaticExpandedOrigin = clampedFrame.origin
    setFrame(clampedFrame, display: true, animate: false)
    invalidateShadow()
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    return direction
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
    let inRightBand = pointInWindow.x >= width - Self.collapsedOrbSize.width &&
      pointInWindow.x <= width
    guard inRightBand else {
      return false
    }
    if currentExpandDirection == .above {
      return pointInWindow.y >= 0 && pointInWindow.y <= Self.collapsedOrbSize.height
    }
    return pointInWindow.y >= height - Self.collapsedOrbSize.height &&
      pointInWindow.y <= height
  }

  private func loadPersistedExpandedSize() {
    let defaults = UserDefaults.standard
    let width = defaults.double(forKey: Self.persistedWidthDefaultsKey)
    let height = defaults.double(forKey: Self.persistedHeightDefaultsKey)
    if width >= Self.minExpandedSize.width && height >= Self.minExpandedSize.height {
      persistedExpandedSize = clampExpandedSize(NSSize(width: width, height: height))
    }
  }

  private func savePersistedExpandedSize(_ size: NSSize) {
    let clamped = clampExpandedSize(size)
    persistedExpandedSize = clamped
    let defaults = UserDefaults.standard
    defaults.set(Double(clamped.width), forKey: Self.persistedWidthDefaultsKey)
    defaults.set(Double(clamped.height), forKey: Self.persistedHeightDefaultsKey)
  }

  private func updateCursor(for edges: ResizeEdges) {
    if edges.isEmpty {
      resetResizeCursorIfNeeded()
      return
    }
    let hasHorizontal = edges.contains(.left) || edges.contains(.right)
    let hasVertical = edges.contains(.top) || edges.contains(.bottom)
    if hasHorizontal && hasVertical {
      NSCursor.crosshair.set()
    } else if hasHorizontal {
      NSCursor.resizeLeftRight.set()
    } else {
      NSCursor.resizeUpDown.set()
    }
    isShowingResizeCursor = true
  }

  private func resetResizeCursorIfNeeded() {
    guard isShowingResizeCursor else { return }
    NSCursor.arrow.set()
    isShowingResizeCursor = false
  }

  private func startNativePanelResize(edges: ResizeEdges) {
    guard isOverlayMode, isExpanded, !edges.isEmpty, activeResizeEdges.isEmpty, !isNativeDragging else {
      return
    }
    // Only enter modal tracking if the primary mouse button is still pressed.
    guard (NSEvent.pressedMouseButtons & 1) != 0 else {
      return
    }

    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
    activeResizeEdges = edges
    resizeStartScreenPoint = NSEvent.mouseLocation
    resizeStartFrame = frame
    updateCursor(for: edges)

    // Release Flutter pointer state before blocking inside AppKit event tracking.
    sendSyntheticMouseUpOutsideWindow()

    while true {
      guard let nextEvent = NSApp.nextEvent(
        matching: [.leftMouseDragged, .leftMouseUp],
        until: .distantFuture,
        inMode: .eventTracking,
        dequeue: true
      ) else {
        break
      }
      if nextEvent.type == .leftMouseUp {
        break
      }
      applyResize(to: NSEvent.mouseLocation)
    }

    activeResizeEdges = []
    resizeStartScreenPoint = nil
    resizeStartFrame = nil
    resetResizeCursorIfNeeded()
    sendSyntheticMouseUpOutsideWindow()
  }

  private func applyResize(to currentScreenPoint: NSPoint) {
    guard !activeResizeEdges.isEmpty,
          let startPoint = resizeStartScreenPoint,
          let startFrame = resizeStartFrame else {
      return
    }

    let dx = currentScreenPoint.x - startPoint.x
    let dy = currentScreenPoint.y - startPoint.y
    let visible = activeVisibleFrame()

    let minW = Self.minExpandedSize.width
    let maxW = visible.map { min(Self.maxExpandedSize.width, $0.width) } ?? Self.maxExpandedSize.width
    let minH = Self.minExpandedSize.height
    let maxH = visible.map { min(Self.maxExpandedSize.height, $0.height) } ?? Self.maxExpandedSize.height

    var newX = startFrame.origin.x
    var newY = startFrame.origin.y
    var newWidth = startFrame.width
    var newHeight = startFrame.height

    if activeResizeEdges.contains(.left) {
      let anchorRight = startFrame.maxX
      var width = min(max(startFrame.width - dx, minW), maxW)
      if let visible = visible {
        width = min(width, anchorRight - visible.minX)
      }
      width = max(width, minW)
      newWidth = width
      newX = anchorRight - width
    } else if activeResizeEdges.contains(.right) {
      let anchorLeft = startFrame.minX
      var width = min(max(startFrame.width + dx, minW), maxW)
      if let visible = visible {
        width = min(width, visible.maxX - anchorLeft)
      }
      width = max(width, minW)
      newWidth = width
      newX = anchorLeft
    }

    if activeResizeEdges.contains(.bottom) {
      let anchorTop = startFrame.maxY
      var height = min(max(startFrame.height - dy, minH), maxH)
      if let visible = visible {
        height = min(height, anchorTop - visible.minY)
      }
      height = max(height, minH)
      newHeight = height
      newY = anchorTop - height
    } else if activeResizeEdges.contains(.top) {
      let anchorBottom = startFrame.minY
      var height = min(max(startFrame.height + dy, minH), maxH)
      if let visible = visible {
        height = min(height, visible.maxY - anchorBottom)
      }
      height = max(height, minH)
      newHeight = height
      newY = anchorBottom
    }

    let nextFrame = clampFrameToVisibleScreen(
      NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
    )
    setFrame(nextFrame, display: true, animate: false)
    invalidateShadow()
    savePersistedExpandedSize(nextFrame.size)
    lastProgrammaticExpandedOrigin = nil
    didMoveWhileExpanded = true
    syncCollapsedOriginFromCurrentFrame()
  }

  private func syncCollapsedOriginFromCurrentFrame() {
    guard isOverlayMode else { return }
    let rawOrigin: NSPoint
    if isExpanded {
      let y = currentExpandDirection == .above
        ? frame.minY
        : frame.maxY - Self.collapsedOrbSize.height
      rawOrigin = NSPoint(
        x: frame.maxX - Self.collapsedOrbSize.width,
        y: y
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
    guard activeResizeEdges.isEmpty else {
      return event
    }

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
