import UIKit
import UserNotifications

final class J6NotificationDelegate: NSObject,
    UIApplicationDelegate,
    UNUserNotificationCenterDelegate {

    static let otpCategoryID = "J6_SMS_OTP"
    static let smsCategoryID = "J6_SMS"
    static let missedCallCategoryID = "J6_MISSED_CALL"
    private static let copyOTPActionID = "J6_COPY_OTP"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let copyCode = UNNotificationAction(
            identifier: Self.copyOTPActionID,
            title: "Copy Code",
            options: [.foreground]
        )
        let otpCategory = UNNotificationCategory(
            identifier: Self.otpCategoryID,
            actions: [copyCode],
            intentIdentifiers: [],
            options: []
        )
        let smsCategory = UNNotificationCategory(
            identifier: Self.smsCategoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let missedCallCategory = UNNotificationCategory(
            identifier: Self.missedCallCategoryID,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([
            otpCategory,
            smsCategory,
            missedCallCategory
        ])

        return true
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler:
            @escaping ([any UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        guard let number = SystemCallActivity.phoneNumber(
            from: userActivity
        ) else {
            return false
        }
        let sourceIdentifier = SystemCallActivity.requestIdentifier(
            from: userActivity
        )

        Task { @MainActor in
            SystemCallRequestCenter.shared.enqueue(
                number,
                sourceIdentifier: sourceIdentifier
            )
        }

        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let smsID = info["smsID"] as? String

        await MainActor.run {
            if let smsID {
                SMSController.shared.markRead(smsID)
            }

            if response.actionIdentifier == Self.copyOTPActionID,
               let code = info["otpCode"] as? String,
               !code.isEmpty {
                UIPasteboard.general.string = code
                return
            }

            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               let sender = info["sender"] as? String,
               !sender.isEmpty {
                SMSController.shared.requestOpenThread(for: sender)
            }
        }
    }
}
