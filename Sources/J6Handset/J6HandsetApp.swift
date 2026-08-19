import SwiftUI

@main
@MainActor
struct J6HandsetApp: App {
    @StateObject private var ble: BLECallController
    @StateObject private var relay: RelayController
    @StateObject private var contacts: ContactResolver
    @StateObject private var callKit: CallKitCoordinator

    init() {
        let ble = BLECallController()
        let relay = RelayController()
        let contacts = ContactResolver()
        let callKit = CallKitCoordinator(
            ble: ble,
            relay: relay,
            contacts: contacts
        )

        _ble = StateObject(wrappedValue: ble)
        _relay = StateObject(wrappedValue: relay)
        _contacts = StateObject(wrappedValue: contacts)
        _callKit = StateObject(wrappedValue: callKit)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(relay)
                .environmentObject(contacts)
                .environmentObject(callKit)
        }
    }
}
