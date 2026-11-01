import BurnCore
import UserNotifications

@MainActor final class FindingNotifications: NSObject, UNUserNotificationCenterDelegate {
  let action: (String, String, String) -> Void
  init(action: @escaping (String, String, String) -> Void) {
    self.action = action
    super.init()
    let review = UNNotificationAction(identifier: "review", title: "Review", options: [.foreground])
    let snooze = UNNotificationAction(identifier: "snooze", title: "Tomorrow", options: [])
    let keep = UNNotificationAction(
      identifier: "keep", title: "Keep", options: [.authenticationRequired])
    let stop = UNNotificationAction(
      identifier: "approve", title: "Stop when idle",
      options: [.authenticationRequired, .destructive])
    let burn = UNNotificationAction(
      identifier: "approve", title: "Burn once", options: [.authenticationRequired, .destructive])
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: "bz-review", actions: [review, snooze], intentIdentifiers: [], options: []),
      UNNotificationCategory(
        identifier: "bz-owner", actions: [stop, keep, review], intentIdentifiers: [], options: []),
      UNNotificationCategory(
        identifier: "bz-burn", actions: [burn, keep, review], intentIdentifiers: [], options: []),
    ])
  }
  static func deliver(_ p: CleanupProposal, details: Bool) async throws {
    let content = UNMutableNotificationContent()
    content.title = "BurnZombies found something to review"
    content.body =
      "A cleanup finding is ready in your private inbox. Review its evidence and recovery options."
    content.categoryIdentifier = "bz-review"
    // Direct action requires an explicit details-visible preference and exact
    // recognizable scope. Generic process signals remain in the app.
    if p.id == "digest" {
      content.title = p.title
      content.body = p.detail
    }
    if p.id != "digest", p.notificationReviewOnly != true, details, p.ready, p.action == .ownerStop,
      p.state == "review"
    {
      content.title = p.title
      content.body = p.action.label + ". " + p.recovery
      content.categoryIdentifier = p.action == .ownerStop ? "bz-owner" : "bz-burn"
    }
    content.userInfo = ["proposal": p.id, "revision": p.revision]
    try await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: p.id + ":" + p.revision, content: content, trigger: nil))
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if let id = info["proposal"] as? String, let revision = info["revision"] as? String,
      response.actionIdentifier != UNNotificationDismissActionIdentifier
    {
      let chosen =
        response.actionIdentifier == UNNotificationDefaultActionIdentifier
        ? "review" : response.actionIdentifier
      Task { @MainActor in self.action(id, revision, chosen) }
    }
    completionHandler()
  }
}
