import AppKit
import SwiftUI

/// Keep the cursor tied to an enabled control, never its surrounding text or form.
private struct ClickPointer: ViewModifier {
  @Environment(\.isEnabled) private var enabled
  @State private var pushed = false
  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.pointerStyle(enabled ? .link : .default)
    } else {
      content.onContinuousHover { phase in
        switch phase {
        case .active where enabled:
          if !pushed { NSCursor.pointingHand.push(); pushed = true }
          else if NSCursor.current != .pointingHand { NSCursor.pointingHand.set() }
        default: clear()
        }
      }.onChange(of: enabled) { _, value in if !value { clear() } }
        .onDisappear { clear() }
    }
  }
  private func clear() { if pushed { NSCursor.pop(); pushed = false } }
}
extension View {
  func clickPointer() -> some View { modifier(ClickPointer()) }
}

/// Only the disclosure header is clickable; expanded content keeps its own cursors.
struct ClickDisclosureStyle: DisclosureGroupStyle {
  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { configuration.isExpanded.toggle() } label: {
        HStack(spacing: 7) {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold)).frame(width: 10)
          configuration.label
          Spacer(minLength: 0)
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).clickPointer()
        .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
      if configuration.isExpanded { configuration.content }
    }
  }
}
