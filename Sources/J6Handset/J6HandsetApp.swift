import SwiftUI

@main
@MainActor
struct J6HandsetApp: App {
    @UIApplicationDelegateAdaptor(J6NotificationDelegate.self)
    private var notificationDelegate

    @StateObject private var ble: BLECallController
    @StateObject private var relay: RelayController
    @StateObject private var contacts: ContactResolver
    @StateObject private var callKit: CallKitCoordinator
    @StateObject private var callHistory: CallHistoryStore
    @StateObject private var sms: SMSController

    init() {
        DiagnosticLog.active?.log("APP", "J6HandsetApp.init begin")

        let ble = BLECallController()
        let relay = RelayController()
        let contacts = ContactResolver()
        let callHistory = CallHistoryStore()
        let callKit = CallKitCoordinator(
            ble: ble,
            relay: relay,
            contacts: contacts,
            callHistory: callHistory
        )
        let sms = SMSController.shared

        _ble = StateObject(wrappedValue: ble)
        _relay = StateObject(wrappedValue: relay)
        _contacts = StateObject(wrappedValue: contacts)
        _callKit = StateObject(wrappedValue: callKit)
        _callHistory = StateObject(wrappedValue: callHistory)
        _sms = StateObject(wrappedValue: sms)

        DiagnosticLog.active?.log("APP", "J6HandsetApp.init complete")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(relay)
                .environmentObject(contacts)
                .environmentObject(callKit)
                .environmentObject(callHistory)
                .environmentObject(sms)
        }
    }
}
