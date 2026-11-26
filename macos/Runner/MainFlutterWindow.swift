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
  private var toastPanel: OrbToastPanel?
  private var isOverlayMode = false
  private var isExpanded = false
  private var isToastShowing = false
  private var isPanelPinned: Bool = true
  private var isToastNotificationsEnabled: Bool = true
  private var isCompactToastLayout: Bool = false
  private var isProgrammaticFrameUpdate = false
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

    toastPanel?.hide(animated: false)
    toastPanel = nil

    windowChannel?.setMethodCallHandler(nil)
    windowChannel = nil
  }

  private func configureMainWindow(centerWindow: Bool) {
    toastPanel?.hide(animated: false)
    isOverlayMode = false
    isExpanded = false
    isToastShowing = false
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
      performProgrammaticFrameUpdate {
        setFrame(targetFrame, display: true, animate: false)
      }
    }
    invalidateShadow()
  }

  private func configureOverlayWindow() {
    guard !isOverlayMode else { return }
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
  }

  private func performProgrammaticFrameUpdate(_ block: () -> Void) {
    let previous = isProgrammaticFrameUpdate
    isProgrammaticFrameUpdate = true
    block()
    isProgrammaticFrameUpdate = previous
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
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
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
        guard let self = self, self.isOverlayMode, !self.isProgrammaticFrameUpdate else { return }
        if self.isExpanded || self.isToastShowing {
          if let initialOrigin = self.lastProgrammaticExpandedOrigin,
             self.frame.origin == initialOrigin {
            return
          }
          self.lastProgrammaticExpandedOrigin = nil
          self.didMoveWhileExpanded = true
        }
        self.syncCollapsedOriginFromCurrentFrame()
        if !self.isExpanded {
          self.repositionToastPanelIfVisible()
        }
      }
    )
    localObservers.append(
      center.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        guard let self = self,
              self.isExpanded,
              self.isOverlayMode,
              !self.isPanelPinned,
              self.activeResizeEdges.isEmpty else { return }
        self.notifyPanelDismissRequested()
      }
    )
    localObservers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: NSApp,
        queue: .main
      ) { [weak self] _ in
        guard let self = self,
              self.isExpanded,
              self.isOverlayMode,
              !self.isPanelPinned,
              self.activeResizeEdges.isEmpty else { return }
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
    case "showToastOverlay":
      guard let args = call.arguments as? [String: Any],
            let width = (args["width"] as? NSNumber)?.doubleValue,
            let height = (args["height"] as? NSNumber)?.doubleValue,
            width > 0,
            height > 0 else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "showToastOverlay requires positive numeric width and height",
            details: nil
          )
        )
        return
      }
      let direction = showToastOverlayWindow(size: NSSize(width: width, height: height))
      result(direction.rawValue)
    case "updateToastStack":
      guard let args = call.arguments as? [String: Any],
            let rawMessages = args["messages"] as? [[String: Any]] else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "updateToastStack requires a messages list",
            details: nil
          )
        )
        return
      }
      let maxVisible = (args["maxVisibleCount"] as? NSNumber)?.intValue ?? 3
      let channelName = args["channelName"] as? String
      let compact = (args["compact"] as? Bool) ?? isCompactToastLayout
      isCompactToastLayout = compact
      updateNativeToastStack(
        rawMessages: rawMessages,
        maxVisibleCount: maxVisible,
        channelName: channelName,
        compact: compact
      )
      result(nil)
    case "hideToastStack":
      toastPanel?.hide(animated: true)
      result(nil)
    case "setPanelPinned":
      guard let args = call.arguments as? [String: Any],
            let pinned = args["pinned"] as? Bool else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "setPanelPinned requires a boolean pinned argument",
            details: nil
          )
        )
        return
      }
      isPanelPinned = pinned
      result(nil)
    case "setToastNotificationsEnabled":
      guard let args = call.arguments as? [String: Any],
            let enabled = args["enabled"] as? Bool else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "setToastNotificationsEnabled requires a boolean enabled argument",
            details: nil
          )
        )
        return
      }
      isToastNotificationsEnabled = enabled
      if !enabled {
        toastPanel?.hide(animated: true)
      }
      result(nil)
    case "setToastLayout":
      guard let args = call.arguments as? [String: Any],
            let compact = args["compact"] as? Bool else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "setToastLayout requires a boolean compact argument",
            details: nil
          )
        )
        return
      }
      isCompactToastLayout = compact
      toastPanel?.updateCompact(
        compact,
        anchorOrigin: currentCollapsedAnchorOrigin(),
        orbSize: Self.collapsedOrbSize,
        visibleFrame: activeVisibleFrame()
      )
      result(nil)
    case "quitApp":
      result(nil)
      DispatchQueue.main.async { [weak self] in
        self?.quitApplication()
      }
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
    toastPanel?.hide(animated: false)
    isExpanded = false
    isToastShowing = false
    let shouldCenter =
      isOverlayMode ||
      frame.width < Self.mainWindowSize.width ||
      frame.height < Self.mainWindowSize.height
    configureMainWindow(centerWindow: shouldCenter)
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  private func showCollapsedOrbWindow() {
    if isOverlayMode && (isExpanded || isToastShowing) {
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
    isToastShowing = false
    activeResizeEdges = []
    resizeStartScreenPoint = nil
    resizeStartFrame = nil
    resetResizeCursorIfNeeded()
    if frame != targetFrame {
      performProgrammaticFrameUpdate {
        setFrame(targetFrame, display: false, animate: false)
      }
    }
    orderFrontRegardless()
  }

  private func ensureToastPanel() -> OrbToastPanel {
    if let existing = toastPanel {
      return existing
    }
    let panel = OrbToastPanel(
      onTap: { [weak self] in
        self?.notifyToastTapped()
      },
      onDismiss: { [weak self] messageId in
        self?.notifyToastDismissed(messageId: messageId)
      }
    )
    toastPanel = panel
    return panel
  }

  private func currentCollapsedAnchorOrigin() -> NSPoint {
    if isOverlayMode && !isExpanded && !isToastShowing && frame.size == Self.collapsedOrbSize {
      collapsedOrigin = frame.origin
      return frame.origin
    }
    if let existing = collapsedOrigin {
      return existing
    }
    let fallback = defaultCollapsedOrigin(for: Self.collapsedOrbSize)
    collapsedOrigin = fallback
    return fallback
  }

  private func updateNativeToastStack(
    rawMessages: [[String: Any]],
    maxVisibleCount: Int,
    channelName: String?,
    compact: Bool
  ) {
    guard isOverlayMode, !isExpanded else {
      toastPanel?.hide(animated: false)
      return
    }
    let payloads: [OrbToastPayload] = rawMessages.compactMap { item in
      guard let id = item["id"] as? String, !id.isEmpty,
            let authorName = item["authorName"] as? String,
            let content = item["content"] as? String else {
        return nil
      }
      let avatarUrl = item["authorAvatarUrl"] as? String
      return OrbToastPayload(
        id: id,
        authorName: authorName,
        authorAvatarUrl: avatarUrl,
        content: content,
        channelName: channelName
      )
    }

    if payloads.isEmpty {
      toastPanel?.hide(animated: true)
      return
    }

    let panel = ensureToastPanel()
    let anchorOrigin = currentCollapsedAnchorOrigin()
    let clampedMax = min(max(maxVisibleCount, 1), 5)
    panel.update(
      messages: payloads,
      maxVisibleCount: clampedMax,
      compact: compact,
      anchorOrigin: anchorOrigin,
      orbSize: Self.collapsedOrbSize,
      visibleFrame: activeVisibleFrame()
    )
  }

  private func repositionToastPanelIfVisible() {
    guard let panel = toastPanel, panel.isShowingToast, isOverlayMode, !isExpanded else {
      return
    }
    panel.reposition(
      anchorOrigin: currentCollapsedAnchorOrigin(),
      orbSize: Self.collapsedOrbSize,
      visibleFrame: activeVisibleFrame()
    )
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
    toastPanel?.hide(animated: false)
    configureOverlayWindow()
    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
    activeResizeEdges = []
    resizeStartScreenPoint = nil
    resizeStartFrame = nil
    resetResizeCursorIfNeeded()

    if isToastShowing {
      if didMoveWhileExpanded ||
          (lastProgrammaticExpandedOrigin != nil && frame.origin != lastProgrammaticExpandedOrigin) {
        syncCollapsedOriginFromCurrentFrame()
      }
    } else if !isExpanded {
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
    isToastShowing = false
    isExpanded = true
    didMoveWhileExpanded = false
    lastProgrammaticExpandedOrigin = clampedFrame.origin
    performProgrammaticFrameUpdate {
      setFrame(clampedFrame, display: true, animate: false)
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    return direction
  }

  private func showToastOverlayWindow(size: NSSize) -> ExpandDirection {
    configureOverlayWindow()
    pendingDragEvent = nil
    pendingDragStartScreenPoint = nil
    activeResizeEdges = []
    resizeStartScreenPoint = nil
    resizeStartFrame = nil
    resetResizeCursorIfNeeded()

    if isToastShowing {
      if didMoveWhileExpanded ||
          (lastProgrammaticExpandedOrigin != nil && frame.origin != lastProgrammaticExpandedOrigin) {
        syncCollapsedOriginFromCurrentFrame()
      }
    } else if !isExpanded {
      if frame.size == Self.collapsedOrbSize {
        collapsedOrigin = frame.origin
      } else if collapsedOrigin == nil {
        collapsedOrigin = defaultCollapsedOrigin(for: Self.collapsedOrbSize)
      }
    }

    let targetSize: NSSize
    if let visible = activeVisibleFrame() {
      targetSize = NSSize(
        width: min(max(size.width, Self.collapsedOrbSize.width), visible.width),
        height: min(max(size.height, Self.collapsedOrbSize.height), visible.height)
      )
    } else {
      targetSize = NSSize(
        width: max(size.width, Self.collapsedOrbSize.width),
        height: max(size.height, Self.collapsedOrbSize.height)
      )
    }
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
    isExpanded = false
    isToastShowing = true
    didMoveWhileExpanded = false
    lastProgrammaticExpandedOrigin = clampedFrame.origin
    performProgrammaticFrameUpdate {
      setFrame(clampedFrame, display: false, animate: false)
    }
    // Non-focus-stealing presentation: never activate NSApp or makeKey for toasts.
    orderFrontRegardless()
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
    performProgrammaticFrameUpdate {
      setFrame(clampedFrame, display: true, animate: false)
    }
    if isExpanded || isToastShowing {
      lastProgrammaticExpandedOrigin = nil
      didMoveWhileExpanded = true
    }
    syncCollapsedOriginFromCurrentFrame()
    if !isExpanded {
      repositionToastPanelIfVisible()
    }
  }

  private func isPointInOrbDragRegion(_ pointInWindow: NSPoint) -> Bool {
    if !isExpanded && !isToastShowing {
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
    if isExpanded || isToastShowing {
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

    case .rightMouseDown:
      if isPointInOrbDragRegion(event.locationInWindow) {
        pendingDragEvent = nil
        pendingDragStartScreenPoint = nil
        showOrbContextMenu(with: event)
        return nil
      }
      return event

    default:
      return event
    }
  }

  private func showOrbContextMenu(with event: NSEvent) {
    let menu = NSMenu(title: "Discord Orb")
    let toastItem = NSMenuItem(
      title: "Toast Popups",
      action: #selector(handleContextMenuToggleToasts(_:)),
      keyEquivalent: ""
    )
    toastItem.target = self
    toastItem.state = isToastNotificationsEnabled ? .on : .off
    menu.addItem(toastItem)

    let compactItem = NSMenuItem(
      title: "Compact Toasts",
      action: #selector(handleContextMenuToggleCompactToasts(_:)),
      keyEquivalent: ""
    )
    compactItem.target = self
    compactItem.state = isCompactToastLayout ? .on : .off
    menu.addItem(compactItem)

    menu.addItem(NSMenuItem.separator())

    let quitItem = NSMenuItem(
      title: "Quit Discord Orb",
      action: #selector(handleContextMenuQuit(_:)),
      keyEquivalent: ""
    )
    quitItem.target = self
    menu.addItem(quitItem)

    if let view = contentView {
      NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
  }

  @objc private func handleContextMenuToggleToasts(_ sender: Any?) {
    isToastNotificationsEnabled.toggle()
    if !isToastNotificationsEnabled {
      toastPanel?.hide(animated: true)
    }
    notifyToastEnabledToggled(enabled: isToastNotificationsEnabled)
  }

  @objc private func handleContextMenuToggleCompactToasts(_ sender: Any?) {
    isCompactToastLayout.toggle()
    toastPanel?.updateCompact(
      isCompactToastLayout,
      anchorOrigin: currentCollapsedAnchorOrigin(),
      orbSize: Self.collapsedOrbSize,
      visibleFrame: activeVisibleFrame()
    )
    notifyToastLayoutToggled(compact: isCompactToastLayout)
  }

  @objc private func handleContextMenuQuit(_ sender: Any?) {
    quitApplication()
  }

  private func quitApplication() {
    toastPanel?.hide(animated: false)
    toastPanel = nil
    orderOut(nil)
    NSApp.terminate(nil)
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
    if (isExpanded || isToastShowing) && pendingDragEvent == nil &&
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
      performProgrammaticFrameUpdate {
        setFrame(clampedFrame, display: true, animate: false)
      }
    }
    if isExpanded || isToastShowing {
      lastProgrammaticExpandedOrigin = nil
      didMoveWhileExpanded = true
    }
    syncCollapsedOriginFromCurrentFrame()
    if !isExpanded {
      repositionToastPanelIfVisible()
    }

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
    toastPanel?.hide(animated: false)
    isExpanded = false
    isToastShowing = false
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
      self?.toastPanel?.hide(animated: false)
      self?.windowChannel?.invokeMethod("onLockOrSleep", arguments: nil)
    }
  }

  private func notifyToastTapped() {
    DispatchQueue.main.async { [weak self] in
      self?.windowChannel?.invokeMethod("onToastTapped", arguments: nil)
    }
  }

  private func notifyToastDismissed(messageId: String) {
    DispatchQueue.main.async { [weak self] in
      self?.windowChannel?.invokeMethod(
        "onToastDismissed",
        arguments: ["messageId": messageId]
      )
    }
  }

  private func notifyToastEnabledToggled(enabled: Bool) {
    DispatchQueue.main.async { [weak self] in
      self?.windowChannel?.invokeMethod(
        "onToastEnabledToggled",
        arguments: ["enabled": enabled]
      )
    }
  }

  private func notifyToastLayoutToggled(compact: Bool) {
    DispatchQueue.main.async { [weak self] in
      self?.windowChannel?.invokeMethod(
        "onToastLayoutToggled",
        arguments: ["compact": compact]
      )
    }
  }
}

private struct OrbToastPayload {
  let id: String
  let authorName: String
  let authorAvatarUrl: String?
  let content: String
  let channelName: String?
}

/// Separate non-activating floating `NSPanel` for macOS toast stacks so the
/// collapsed `80x80` orb window never resizes or flickers on toast show/hide.
private final class OrbToastPanel: NSPanel {
  private static let panelWidth: CGFloat = 288
  private static let standardCardHeight: CGFloat = 62
  private static let compactCardHeight: CGFloat = 40
  private static let standardCornerRadius: CGFloat = 14
  private static let compactCornerRadius: CGFloat = 11
  private static let cardSpacing: CGFloat = 6
  private static let maxOverflowLayers = 3
  private static let overflowStepY: CGFloat = 6
  private static let overflowInsetPerDepth: CGFloat = 6
  private static let badgeRowHeight: CGFloat = 22
  private static let outerPadding: CGFloat = 8
  private static let orbGap: CGFloat = 8
  private static let maxCachedAvatars = 24

  private enum Direction {
    case below
    case above
  }

  private let onTap: () -> Void
  private let onDismiss: (String) -> Void

  private var currentMessages: [OrbToastPayload] = []
  private var currentMaxVisibleCount: Int = 3
  private var currentCompact: Bool = false
  private var currentDirection: Direction = .below
  private var hideGeneration: Int = 0
  private var _isShowingToast = false

  private var inMemoryAvatars: [String: NSImage] = [:]
  private var inFlightAvatarTasks: [String: URLSessionDataTask] = [:]
  private var avatarViewsByUrl: [String: [_ToastAvatarView]] = [:]

  private lazy var ephemeralSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.httpCookieStorage = nil
    config.httpShouldSetCookies = false
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 8
    return URLSession(configuration: config)
  }()

  var isShowingToast: Bool { _isShowingToast }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  init(onTap: @escaping () -> Void, onDismiss: @escaping (String) -> Void) {
    self.onTap = onTap
    self.onDismiss = onDismiss
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.standardCardHeight),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovable = false
    animationBehavior = .none
    alphaValue = 0.0
  }

  deinit {
    purgeMemory()
    ephemeralSession.invalidateAndCancel()
  }

  func update(
    messages: [OrbToastPayload],
    maxVisibleCount: Int,
    compact: Bool,
    anchorOrigin: NSPoint,
    orbSize: NSSize,
    visibleFrame: NSRect?
  ) {
    let clampedMax = min(max(maxVisibleCount, 1), 5)
    currentMessages = messages
    currentMaxVisibleCount = clampedMax
    currentCompact = compact
    hideGeneration += 1

    let visibleCount = min(messages.count, clampedMax)
    let overflowCount = max(0, messages.count - visibleCount)
    let totalHeight = computeTotalHeight(
      visibleCount: visibleCount,
      overflowCount: overflowCount,
      compact: compact
    )

    let (targetFrame, direction) = computeFrameAndDirection(
      panelHeight: totalHeight,
      anchorOrigin: anchorOrigin,
      orbSize: orbSize,
      visibleFrame: visibleFrame
    )
    currentDirection = direction

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    rebuildContentView(
      messages: messages,
      maxVisibleCount: clampedMax,
      compact: compact,
      direction: direction,
      panelSize: targetFrame.size
    )
    setFrame(targetFrame, display: true, animate: false)
    CATransaction.commit()

    let wasShown = _isShowingToast
    _isShowingToast = true
    if !wasShown {
      alphaValue = 0.0
      orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.animator().alphaValue = 1.0
      }
    } else {
      orderFrontRegardless()
      if alphaValue < 1.0 {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.10
          self.animator().alphaValue = 1.0
        }
      }
    }
  }

  func updateCompact(
    _ compact: Bool,
    anchorOrigin: NSPoint,
    orbSize: NSSize,
    visibleFrame: NSRect?
  ) {
    currentCompact = compact
    guard _isShowingToast, !currentMessages.isEmpty else { return }
    update(
      messages: currentMessages,
      maxVisibleCount: currentMaxVisibleCount,
      compact: compact,
      anchorOrigin: anchorOrigin,
      orbSize: orbSize,
      visibleFrame: visibleFrame
    )
  }

  func reposition(anchorOrigin: NSPoint, orbSize: NSSize, visibleFrame: NSRect?) {
    guard _isShowingToast, !currentMessages.isEmpty else { return }
    let visibleCount = min(currentMessages.count, currentMaxVisibleCount)
    let overflowCount = max(0, currentMessages.count - visibleCount)
    let totalHeight = computeTotalHeight(
      visibleCount: visibleCount,
      overflowCount: overflowCount,
      compact: currentCompact
    )
    let (targetFrame, direction) = computeFrameAndDirection(
      panelHeight: totalHeight,
      anchorOrigin: anchorOrigin,
      orbSize: orbSize,
      visibleFrame: visibleFrame
    )
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if direction != currentDirection {
      currentDirection = direction
      rebuildContentView(
        messages: currentMessages,
        maxVisibleCount: currentMaxVisibleCount,
        compact: currentCompact,
        direction: direction,
        panelSize: targetFrame.size
      )
    }
    setFrame(targetFrame, display: true, animate: false)
    CATransaction.commit()
  }

  func hide(animated: Bool) {
    hideGeneration += 1
    let expectedGen = hideGeneration
    purgeMemory()

    guard _isShowingToast || isVisible else {
      _isShowingToast = false
      alphaValue = 0.0
      orderOut(nil)
      contentView = nil
      return
    }
    _isShowingToast = false

    if animated {
      NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.12
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        self.animator().alphaValue = 0.0
      }, completionHandler: { [weak self] in
        DispatchQueue.main.async {
          guard let self = self,
                self.hideGeneration == expectedGen,
                !self._isShowingToast else { return }
          self.orderOut(nil)
          self.contentView = nil
        }
      })
    } else {
      alphaValue = 0.0
      orderOut(nil)
      contentView = nil
    }
  }

  private func purgeMemory() {
    currentMessages.removeAll()
    avatarViewsByUrl.removeAll()
    for (_, task) in inFlightAvatarTasks {
      task.cancel()
    }
    inFlightAvatarTasks.removeAll()
    inMemoryAvatars.removeAll()
  }

  private func computeTotalHeight(
    visibleCount: Int,
    overflowCount: Int,
    compact: Bool
  ) -> CGFloat {
    let cardH = compact ? Self.compactCardHeight : Self.standardCardHeight
    guard visibleCount > 0 else { return cardH + (Self.outerPadding * 2) }
    let cardsHeight = CGFloat(visibleCount) * cardH +
      CGFloat(max(0, visibleCount - 1)) * Self.cardSpacing
    let stackedDepth = min(Self.maxOverflowLayers, max(0, overflowCount))
    let overflowHeight: CGFloat = stackedDepth > 0
      ? (CGFloat(stackedDepth) * Self.overflowStepY) + Self.badgeRowHeight
      : 0
    return cardsHeight + overflowHeight + (Self.outerPadding * 2)
  }

  private func computeFrameAndDirection(
    panelHeight: CGFloat,
    anchorOrigin: NSPoint,
    orbSize: NSSize,
    visibleFrame: NSRect?
  ) -> (NSRect, Direction) {
    let orbFrame = NSRect(origin: anchorOrigin, size: orbSize)
    let width = visibleFrame.map { min(Self.panelWidth, $0.width) } ?? Self.panelWidth
    let height = visibleFrame.map { min(panelHeight, $0.height) } ?? panelHeight

    let direction: Direction
    if let visible = visibleFrame {
      let spaceBelow = orbFrame.minY - visible.minY - Self.orbGap
      let spaceAbove = visible.maxY - orbFrame.maxY - Self.orbGap
      if spaceBelow >= height {
        direction = .below
      } else if spaceAbove > spaceBelow {
        direction = .above
      } else {
        direction = .below
      }
    } else {
      direction = .below
    }

    var x = orbFrame.maxX - width
    var y = direction == .above
      ? (orbFrame.maxY + Self.orbGap)
      : (orbFrame.minY - Self.orbGap - height)

    if let visible = visibleFrame {
      x = min(max(x, visible.minX), visible.maxX - width)
      y = min(max(y, visible.minY), visible.maxY - height)
    }

    return (NSRect(x: x, y: y, width: width, height: height), direction)
  }

  private func rebuildContentView(
    messages: [OrbToastPayload],
    maxVisibleCount: Int,
    compact: Bool,
    direction: Direction,
    panelSize: NSSize
  ) {
    avatarViewsByUrl.removeAll()

    let root = _FlippedContainerView(frame: NSRect(origin: .zero, size: panelSize))
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.clear.cgColor

    let visible = Array(messages.prefix(maxVisibleCount))
    let overflowCount = max(0, messages.count - visible.count)
    let stackedDepth = min(Self.maxOverflowLayers, overflowCount)
    let isAbove = direction == .above
    let orderedVisible = isAbove ? Array(visible.reversed()) : visible

    let cardHeight = compact ? Self.compactCardHeight : Self.standardCardHeight
    let cornerRadius = compact ? Self.compactCornerRadius : Self.standardCornerRadius
    let cardWidth = panelSize.width - (Self.outerPadding * 2)
    let totalPeek = CGFloat(stackedDepth) * Self.overflowStepY
    var cursorY = Self.outerPadding

    if isAbove && stackedDepth > 0 {
      let badgeRow = buildOverflowBadgeRow(
        overflowCount: overflowCount,
        isAbove: true,
        width: cardWidth
      )
      badgeRow.frame = NSRect(
        x: Self.outerPadding,
        y: cursorY,
        width: cardWidth,
        height: Self.badgeRowHeight
      )
      root.addSubview(badgeRow)
      cursorY += Self.badgeRowHeight

      // Add deepest tucked card-back layers first so front card renders on top.
      for depth in stride(from: stackedDepth, through: 1, by: -1) {
        let inset = CGFloat(depth) * Self.overflowInsetPerDepth
        let layerY = cursorY + CGFloat(stackedDepth - depth) * Self.overflowStepY
        let backView = buildDeckBackCardView(
          frame: NSRect(
            x: Self.outerPadding + inset,
            y: layerY,
            width: max(40, cardWidth - (inset * 2)),
            height: cardHeight
          ),
          depth: depth,
          cornerRadius: cornerRadius
        )
        root.addSubview(backView)
      }
      cursorY += totalPeek
    }

    for (index, payload) in orderedVisible.enumerated() {
      if index > 0 {
        cursorY += Self.cardSpacing
      }
      let isBottomOverflowAnchor = !isAbove && stackedDepth > 0 && index == (orderedVisible.count - 1)
      if isBottomOverflowAnchor {
        // Add deepest tucked card-back layers behind the farthest visible card.
        for depth in stride(from: stackedDepth, through: 1, by: -1) {
          let inset = CGFloat(depth) * Self.overflowInsetPerDepth
          let layerY = cursorY + CGFloat(depth) * Self.overflowStepY
          let backView = buildDeckBackCardView(
            frame: NSRect(
              x: Self.outerPadding + inset,
              y: layerY,
              width: max(40, cardWidth - (inset * 2)),
              height: cardHeight
            ),
            depth: depth,
            cornerRadius: cornerRadius
          )
          root.addSubview(backView)
        }
      }

      let cardView = _ToastCardView(
        frame: NSRect(
          x: Self.outerPadding,
          y: cursorY,
          width: cardWidth,
          height: cardHeight
        ),
        payload: payload,
        compact: compact,
        onTap: onTap,
        onDismiss: onDismiss
      )
      if let avatarUrl = normalizedHttpsUrl(payload.authorAvatarUrl) {
        if let cached = inMemoryAvatars[avatarUrl.absoluteString] {
          cardView.avatarView.setImage(cached)
        } else {
          registerAvatarLoad(url: avatarUrl, for: cardView.avatarView)
        }
      }
      root.addSubview(cardView)
      cursorY += cardHeight
    }

    if !isAbove && stackedDepth > 0 {
      cursorY += totalPeek
      let badgeRow = buildOverflowBadgeRow(
        overflowCount: overflowCount,
        isAbove: false,
        width: cardWidth
      )
      badgeRow.frame = NSRect(
        x: Self.outerPadding,
        y: cursorY,
        width: cardWidth,
        height: Self.badgeRowHeight
      )
      root.addSubview(badgeRow)
    }

    contentView = root
  }

  private func buildDeckBackCardView(
    frame: NSRect,
    depth: Int,
    cornerRadius: CGFloat
  ) -> NSView {
    let fillColors: [NSColor] = [
      NSColor(srgbRed: 0.122, green: 0.129, blue: 0.156, alpha: 0.92),
      NSColor(srgbRed: 0.102, green: 0.109, blue: 0.133, alpha: 0.84),
      NSColor(srgbRed: 0.085, green: 0.091, blue: 0.114, alpha: 0.76),
    ]
    let borderAlphas: [CGFloat] = [0.13, 0.10, 0.08]
    let idx = min(max(depth - 1, 0), fillColors.count - 1)

    let view = _ToastTapView(frame: frame, onTap: onTap)
    view.wantsLayer = true
    view.layer?.backgroundColor = fillColors[idx].cgColor
    view.layer?.cornerRadius = cornerRadius
    view.layer?.borderWidth = 0.9
    view.layer?.borderColor = NSColor.white.withAlphaComponent(borderAlphas[idx]).cgColor
    return view
  }

  private func buildOverflowBadgeRow(
    overflowCount: Int,
    isAbove: Bool,
    width: CGFloat
  ) -> NSView {
    let container = _ToastTapView(
      frame: NSRect(x: 0, y: 0, width: width, height: Self.badgeRowHeight),
      onTap: onTap
    )
    container.wantsLayer = true

    let badgeText = "+\(overflowCount) more"
    let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    let textSize = (badgeText as NSString).size(withAttributes: [.font: badgeFont])
    let badgeWidth = ceil(textSize.width) + 16
    let badgeHeight: CGFloat = 18

    let badgeView = _FlippedContainerView(
      frame: NSRect(
        x: width - badgeWidth - 2,
        y: isAbove ? 0 : (Self.badgeRowHeight - badgeHeight),
        width: badgeWidth,
        height: badgeHeight
      )
    )
    badgeView.wantsLayer = true
    badgeView.layer?.backgroundColor = NSColor(
      srgbRed: 0.345,
      green: 0.396,
      blue: 0.949,
      alpha: 0.94
    ).cgColor
    badgeView.layer?.cornerRadius = badgeHeight / 2
    badgeView.layer?.borderWidth = 0.75
    badgeView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

    let labelHeight = ceil(textSize.height)
    let labelY = max(0, (badgeHeight - labelHeight) / 2 - 0.5)
    let badgeLabel = NSTextField(labelWithString: badgeText)
    badgeLabel.font = badgeFont
    badgeLabel.textColor = .white
    badgeLabel.alignment = .center
    badgeLabel.frame = NSRect(x: 0, y: labelY, width: badgeWidth, height: labelHeight)
    badgeView.addSubview(badgeLabel)

    container.addSubview(badgeView)
    return container
  }

  private func normalizedHttpsUrl(_ raw: String?) -> URL? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty,
          let url = URL(string: trimmed),
          url.scheme?.lowercased() == "https",
          let host = url.host,
          !host.isEmpty else {
      return nil
    }
    return url
  }

  private func registerAvatarLoad(url: URL, for avatarView: _ToastAvatarView) {
    let key = url.absoluteString
    avatarViewsByUrl[key, default: []].append(avatarView)
    guard inFlightAvatarTasks[key] == nil else { return }

    let gen = hideGeneration
    let task = ephemeralSession.dataTask(with: url) { [weak self] data, response, error in
      guard error == nil,
            let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            let data = data,
            let image = NSImage(data: data) else {
        DispatchQueue.main.async {
          self?.inFlightAvatarTasks.removeValue(forKey: key)
        }
        return
      }
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.inFlightAvatarTasks.removeValue(forKey: key)
        guard self.hideGeneration == gen, self._isShowingToast else { return }
        if self.inMemoryAvatars.count >= Self.maxCachedAvatars {
          self.inMemoryAvatars.removeAll()
        }
        self.inMemoryAvatars[key] = image
        for view in self.avatarViewsByUrl[key] ?? [] {
          view.setImage(image)
        }
      }
    }
    inFlightAvatarTasks[key] = task
    task.resume()
  }
}

private final class _FlippedContainerView: NSView {
  override var isFlipped: Bool { true }
}

private final class _ToastTapView: NSView {
  private let onTap: () -> Void

  init(frame: NSRect, onTap: @escaping () -> Void) {
    self.onTap = onTap
    super.init(frame: frame)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseUp(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    if bounds.contains(pt) {
      onTap()
    }
  }
}

private final class _ToastDismissButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class _ToastAvatarView: NSView {
  private static let palette: [NSColor] = [
    NSColor(srgbRed: 0.345, green: 0.396, blue: 0.949, alpha: 1.0),
    NSColor(srgbRed: 0.231, green: 0.647, blue: 0.365, alpha: 1.0),
    NSColor(srgbRed: 0.929, green: 0.259, blue: 0.271, alpha: 1.0),
    NSColor(srgbRed: 0.980, green: 0.651, blue: 0.102, alpha: 1.0),
    NSColor(srgbRed: 0.922, green: 0.271, blue: 0.620, alpha: 1.0),
    NSColor(srgbRed: 0.000, green: 0.659, blue: 0.988, alpha: 1.0),
    NSColor(srgbRed: 0.608, green: 0.349, blue: 0.714, alpha: 1.0),
    NSColor(srgbRed: 0.102, green: 0.737, blue: 0.612, alpha: 1.0),
  ]

  private let initialsLabel: NSTextField
  private let imageView: NSImageView

  init(frame: NSRect, name: String) {
    initialsLabel = NSTextField(labelWithString: Self.initialsFor(name))
    imageView = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
    super.init(frame: frame)

    wantsLayer = true
    layer?.cornerRadius = frame.width / 2
    layer?.masksToBounds = true
    layer?.backgroundColor = Self.colorFor(name).cgColor

    let fontSize: CGFloat = frame.width <= 22 ? 9.5 : 11.5
    let labelHeight: CGFloat = frame.width <= 22 ? 12 : 15
    initialsLabel.font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    initialsLabel.textColor = .white
    initialsLabel.alignment = .center
    initialsLabel.frame = NSRect(
      x: 0,
      y: (frame.height - labelHeight) / 2,
      width: frame.width,
      height: labelHeight
    )
    addSubview(initialsLabel)

    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.isHidden = true
    addSubview(imageView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func setImage(_ image: NSImage) {
    imageView.image = image
    imageView.isHidden = false
    initialsLabel.isHidden = true
  }

  private static func initialsFor(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "?" }
    let words = trimmed.split(whereSeparator: { $0.isWhitespace })
    if words.count >= 2, let a = words[0].first, let b = words[1].first {
      return "\(a)\(b)".uppercased()
    }
    return String(trimmed.prefix(2)).uppercased()
  }

  private static func colorFor(_ name: String) -> NSColor {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return palette[0] }
    var hash = 0
    for codeUnit in normalized.utf16 {
      hash = ((hash &* 31) &+ Int(codeUnit)) & 0x7fffffff
    }
    return palette[hash % palette.count]
  }
}

private final class _ToastCardView: NSView {
  let avatarView: _ToastAvatarView
  private let messageId: String
  private let onTap: () -> Void
  private let onDismiss: (String) -> Void
  private let dismissButton: _ToastDismissButton

  init(
    frame: NSRect,
    payload: OrbToastPayload,
    compact: Bool,
    onTap: @escaping () -> Void,
    onDismiss: @escaping (String) -> Void
  ) {
    self.messageId = payload.id
    self.onTap = onTap
    self.onDismiss = onDismiss
    let avatarSize: CGFloat = compact ? 20 : 28
    let avatarX: CGFloat = compact ? 8 : 10
    let avatarY: CGFloat = compact ? ((frame.height - avatarSize) / 2) : 10
    self.avatarView = _ToastAvatarView(
      frame: NSRect(x: avatarX, y: avatarY, width: avatarSize, height: avatarSize),
      name: payload.authorName
    )
    let dismissY: CGFloat = compact ? ((frame.height - 22) / 2) : 6
    self.dismissButton = _ToastDismissButton(
      frame: NSRect(x: frame.width - 26, y: dismissY, width: 22, height: 22)
    )
    super.init(frame: frame)

    wantsLayer = true
    layer?.backgroundColor = NSColor(
      srgbRed: 0.145,
      green: 0.153,
      blue: 0.180,
      alpha: 0.96
    ).cgColor
    layer?.cornerRadius = compact ? 11 : 14
    layer?.borderWidth = 1.0
    layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

    addSubview(avatarView)

    let compactContent = payload.content
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if compact {
      let rowX: CGFloat = avatarX + avatarSize + 6
      let availableWidth = max(60, frame.width - rowX - 28)
      let authorFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
      let measuredAuthor = ceil(
        (payload.authorName as NSString).size(withAttributes: [.font: authorFont]).width
      )
      let authorWidth = min(max(32, measuredAuthor + 2), min(82, availableWidth * 0.42))
      let labelHeight: CGFloat = 16
      let labelY = (frame.height - labelHeight) / 2

      let authorLabel = NSTextField(labelWithString: payload.authorName)
      authorLabel.font = authorFont
      authorLabel.textColor = NSColor(srgbRed: 0.62, green: 0.67, blue: 1.0, alpha: 1.0)
      authorLabel.lineBreakMode = .byTruncatingTail
      authorLabel.maximumNumberOfLines = 1
      authorLabel.frame = NSRect(x: rowX, y: labelY, width: authorWidth, height: labelHeight)
      addSubview(authorLabel)

      let bodyX = rowX + authorWidth + 6
      let bodyWidth = max(30, frame.width - bodyX - 28)
      let bodyLabel = NSTextField(labelWithString: compactContent)
      bodyLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
      bodyLabel.textColor = NSColor.white.withAlphaComponent(0.92)
      bodyLabel.lineBreakMode = .byTruncatingTail
      bodyLabel.maximumNumberOfLines = 1
      bodyLabel.frame = NSRect(x: bodyX, y: labelY, width: bodyWidth, height: labelHeight)
      addSubview(bodyLabel)
    } else {
      let textX: CGFloat = 46
      let textWidth = max(60, frame.width - textX - 30)

      let headerText: String
      if let channel = payload.channelName, !channel.isEmpty {
        headerText = "\(payload.authorName)  #\(channel)"
      } else {
        headerText = payload.authorName
      }
      let authorLabel = NSTextField(labelWithString: headerText)
      authorLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
      authorLabel.textColor = NSColor(srgbRed: 0.62, green: 0.67, blue: 1.0, alpha: 1.0)
      authorLabel.lineBreakMode = .byTruncatingTail
      authorLabel.maximumNumberOfLines = 1
      authorLabel.frame = NSRect(x: textX, y: 8, width: textWidth, height: 16)
      addSubview(authorLabel)

      let bodyLabel = NSTextField(wrappingLabelWithString: compactContent)
      bodyLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
      bodyLabel.textColor = NSColor.white.withAlphaComponent(0.92)
      bodyLabel.lineBreakMode = .byTruncatingTail
      bodyLabel.maximumNumberOfLines = 2
      bodyLabel.cell?.truncatesLastVisibleLine = true
      bodyLabel.frame = NSRect(x: textX, y: 25, width: textWidth, height: 30)
      addSubview(bodyLabel)
    }

    dismissButton.title = "×"
    dismissButton.isBordered = false
    dismissButton.font = NSFont.systemFont(ofSize: compact ? 13 : 14, weight: .medium)
    dismissButton.contentTintColor = NSColor.white.withAlphaComponent(0.70)
    dismissButton.target = self
    dismissButton.action = #selector(handleDismissClick)
    addSubview(dismissButton)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseUp(with event: NSEvent) {
    let pt = convert(event.locationInWindow, from: nil)
    if dismissButton.frame.contains(pt) {
      return
    }
    if bounds.contains(pt) {
      onTap()
    }
  }

  @objc private func handleDismissClick() {
    onDismiss(messageId)
  }
}
