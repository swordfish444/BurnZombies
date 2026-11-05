import AppKit
import SwiftUI

/// What the guide beside System Settings asks for.
enum AccessGuide: Equatable {
  /// BurnZombies is already in the Full Disk Access list, switched off.
  case turnOn
  /// macOS had nothing to refuse, so BurnZombies has to be dragged into the list first.
  case dragIn
}

/// The guide's content: one action, the password prompt to expect, and the app icon to drag
/// into the list if BurnZombies isn't there.
struct AccessGuideView: View {
  static let width: CGFloat = 300
  let guide: AccessGuide
  let appURL: URL
  let close: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(alignment: .firstTextBaseline) {
        Text(guide == .turnOn ? "Turn on BurnZombies" : "Add BurnZombies")
          .font(.system(size: 15, weight: .semibold))
        Spacer(minLength: 8)
        Button(action: close) {
          Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            .foregroundStyle(BurnTheme.muted).frame(width: 22, height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain).help("Close this guide").accessibilityLabel("Close guide")
      }
      Text(
        guide == .turnOn
          ? "Switch on BurnZombies in this list. macOS then asks for your password or Touch ID."
          : "Drag this icon into the list, then switch BurnZombies on. macOS asks for your password or Touch ID."
      ).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 11) {
        DraggableAppIcon(url: appURL).frame(width: 44, height: 44)
          .accessibilityLabel("BurnZombies app icon. Drag it into the Full Disk Access list.")
        Text(
          guide == .turnOn
            ? "Not in the list? Drag this icon into it." : "Drop it on the list of apps."
        )
        .font(.system(size: 11.5)).foregroundStyle(BurnTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
      }
      Text("If macOS offers Quit & Reopen, choose it. BurnZombies checks access by itself.")
        .font(.system(size: 11)).foregroundStyle(BurnTheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }.padding(16).frame(width: Self.width, alignment: .leading)
      .foregroundStyle(BurnTheme.cream)
      .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14))
      .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(BurnTheme.orange.opacity(0.55)))
      .preferredColorScheme(.dark)
      .accessibilityIdentifier("full-disk-access-guide")
  }
}

/// The app bundle as a file drag, the same thing Finder hands System Settings.
struct DraggableAppIcon: NSViewRepresentable {
  let url: URL
  func makeNSView(context: Context) -> AppIconDragSource { AppIconDragSource(url: url) }
  func updateNSView(_ view: AppIconDragSource, context: Context) {}
}

final class AppIconDragSource: NSView, NSDraggingSource {
  let url: URL
  private let icon: NSImage
  init(url: URL) {
    self.url = url
    icon = Self.image(for: url)
    super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 44))
    toolTip = "Drag into the Full Disk Access list"
  }
  /// The app's own icon when the bundle declares one; otherwise BZ's skull, which people know
  /// from the menu bar, rather than macOS's blank app placeholder. Either way the drag carries
  /// the app itself.
  static func image(for url: URL) -> NSImage {
    let info = Bundle(url: url)?.infoDictionary ?? [:]
    if info["CFBundleIconFile"] == nil, info["CFBundleIconName"] == nil,
      let skull = Bundle.module.url(forResource: "EmberSkull", withExtension: "png").flatMap(
        NSImage.init(contentsOf:))
    {
      return skull
    }
    return NSWorkspace.shared.icon(forFile: url.path)
  }
  required init?(coder: NSCoder) { nil }
  override var intrinsicContentSize: NSSize { NSSize(width: 44, height: 44) }
  override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
  override func mouseDown(with event: NSEvent) {}
  override func mouseDragged(with event: NSEvent) {
    let item = NSDraggingItem(pasteboardWriter: url as NSURL)
    item.setDraggingFrame(bounds, contents: icon)
    beginDraggingSession(with: [item], event: event, source: self)
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .outsideApplication ? [.copy, .link, .generic] : []
  }
}

/// A floating, non-activating panel beside the System Settings window. It never takes focus
/// from Settings, so the person's switch and password prompt stay in front, and it closes when
/// they return to BurnZombies, access is verified, they close it, or after 15 minutes.
@MainActor final class AccessGuidePanel {
  static let shared = AccessGuidePanel()
  private static let settingsBundle = "com.apple.systempreferences"
  private var panel: NSPanel?
  private var expiry: Timer?
  private var placement: Timer?
  private var placementAttempts = 0

  func show(_ guide: AccessGuide?, close: @escaping @MainActor @Sendable () -> Void) {
    expiry?.invalidate()
    placement?.invalidate()
    guard let guide else {
      panel?.orderOut(nil)
      panel = nil
      return
    }
    let host = NSHostingView(
      rootView: AccessGuideView(guide: guide, appURL: Bundle.main.bundleURL) {
        MainActor.assumeIsolated { close() }
      })
    host.frame.size = host.fittingSize
    let panel =
      self.panel
      ?? NSPanel(
        contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
    panel.contentView = host
    panel.setContentSize(host.frame.size)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isMovableByWindowBackground = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    self.panel = panel
    place(panel)
    panel.orderFrontRegardless()
    // System Settings takes a moment to open its window; follow it briefly, then stay put
    // so the person can move the guide.
    placementAttempts = 0
    placement = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        guard let self, let panel = self.panel, self.placementAttempts < 16 else {
          return timer.invalidate()
        }
        self.placementAttempts += 1
        if self.place(panel) { timer.invalidate() }
      }
    }
    expiry = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { _ in
      MainActor.assumeIsolated { close() }
    }
  }

  /// Puts the panel to the right of the System Settings window, or to its left when the right
  /// is off screen. Returns false while that window can't be found yet (top-right meanwhile).
  @discardableResult private func place(_ panel: NSPanel) -> Bool {
    let size = panel.frame.size
    guard let screen = NSScreen.screens.first, let visible = NSScreen.main?.visibleFrame else {
      return false
    }
    guard let settings = Self.settingsWindowFrame(primaryHeight: screen.frame.height) else {
      panel.setFrameOrigin(
        NSPoint(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16))
      return false
    }
    let gap: CGFloat = 14
    let display = NSScreen.screens.first { $0.frame.intersects(settings) }?.visibleFrame ?? visible
    var x = settings.maxX + gap
    if x + size.width > display.maxX { x = settings.minX - gap - size.width }
    if x < display.minX { x = settings.maxX - size.width - gap }
    let y = min(max(settings.maxY - size.height - 52, display.minY + 8), display.maxY - size.height)
    panel.setFrameOrigin(NSPoint(x: x, y: y))
    return true
  }

  /// The frontmost normal window of System Settings, in AppKit screen coordinates. Window
  /// bounds and owner need no screen-recording permission; titles are not read.
  private static func settingsWindowFrame(primaryHeight: CGFloat) -> NSRect? {
    let owners = Set(
      NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundle).map(
        \.processIdentifier))
    guard !owners.isEmpty,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    for window in windows {
      guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owners.contains(owner),
        (window[kCGWindowLayer as String] as? Int) == 0,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 200, rect.height > 200
      else { continue }
      return NSRect(
        x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    return nil
  }
}
