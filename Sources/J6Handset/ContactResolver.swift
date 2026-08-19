import Contacts
import Foundation

struct ContactCallMetadata: Equatable, Sendable {
    let rawNumber: String
    let normalizedNumber: String
    let formattedNumber: String
    let displayName: String?
    let contactIdentifier: String?
    let thumbnailImageData: Data?

    var matchedContact: Bool {
        contactIdentifier != nil
    }
}

@MainActor
final class ContactResolver: ObservableObject {

    @Published private(set) var authorizationText = "Checking…"
    @Published private(set) var canReadContacts = false
    @Published private(set) var lastLookupStatus = "No lookup yet"

    private var cache: [String: ContactCallMetadata] = [:]
    private var storeChangeObserver: NSObjectProtocol?

    init() {
        refreshAuthorizationStatus()

        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.cache.removeAll()
                self?.lastLookupStatus =
                    "Contacts changed; caller-ID cache refreshed"
                self?.refreshAuthorizationStatus()
            }
        }
    }

    deinit {
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(
                storeChangeObserver
            )
        }
    }

    func requestAccessIfNeeded() {
        let status = CNContactStore.authorizationStatus(
            for: .contacts
        )

        if isUsableAuthorization(status) {
            refreshAuthorizationStatus()
            return
        }

        guard status == .notDetermined else {
            refreshAuthorizationStatus()
            return
        }

        authorizationText = "Requesting Contacts access…"

        CNContactStore().requestAccess(
            for: .contacts
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.refreshAuthorizationStatus()
            }
        }
    }

    func refreshAuthorizationStatus() {
        let status = CNContactStore.authorizationStatus(
            for: .contacts
        )

        if #available(iOS 18.0, *),
           status == .limited {
            authorizationText = "Limited Contacts access"
            canReadContacts = true
            return
        }

        switch status {
        case .authorized:
            authorizationText = "Full Contacts access"
            canReadContacts = true

        case .notDetermined:
            authorizationText = "Contacts permission not requested"
            canReadContacts = false

        case .denied:
            authorizationText = "Contacts access denied"
            canReadContacts = false

        case .restricted:
            authorizationText = "Contacts access restricted"
            canReadContacts = false

        case .limited:
            if #available(iOS 18.0, *) {
                authorizationText = "Limited Contacts access"
                canReadContacts = true
            } else {
                authorizationText = "Contacts access unavailable"
                canReadContacts = false
            }

        @unknown default:
            authorizationText = "Contacts access unavailable"
            canReadContacts = false
        }
    }

    func basicMetadata(
        for number: String
    ) -> ContactCallMetadata {
        let normalized = Self.normalizedHandle(number)
        return ContactCallMetadata(
            rawNumber: number,
            normalizedNumber: normalized,
            formattedNumber: Self.formatDisplayNumber(
                normalized
            ),
            displayName: nil,
            contactIdentifier: nil,
            thumbnailImageData: nil
        )
    }

    func resolve(
        number: String
    ) async -> ContactCallMetadata {
        let key = Self.canonicalDigits(number)

        if let cached = cache[key] {
            lastLookupStatus = cached.matchedContact
                ? "Matched \(cached.displayName ?? "contact")"
                : "No matching contact"
            return cached
        }

        let basic = basicMetadata(for: number)

        guard canReadContacts else {
            lastLookupStatus =
                "Contacts unavailable; using phone number"
            cache[key] = basic
            return basic
        }

        let resolved = await Task.detached(
            priority: .userInitiated
        ) {
            Self.lookupContact(number: number) ?? basic
        }.value

        cache[key] = resolved
        lastLookupStatus = resolved.matchedContact
            ? "Matched \(resolved.displayName ?? "contact")"
            : "No matching contact"

        return resolved
    }

    func normalizedHandle(
        for number: String
    ) -> String {
        Self.normalizedHandle(number)
    }

    private func isUsableAuthorization(
        _ status: CNAuthorizationStatus
    ) -> Bool {
        if status == .authorized {
            return true
        }

        if #available(iOS 18.0, *),
           status == .limited {
            return true
        }

        return false
    }

    nonisolated private static func lookupContact(
        number rawNumber: String
    ) -> ContactCallMetadata? {
        let status = CNContactStore.authorizationStatus(
            for: .contacts
        )

        let usable: Bool
        if status == .authorized {
            usable = true
        } else if #available(iOS 18.0, *),
                  status == .limited {
            usable = true
        } else {
            usable = false
        }

        guard usable else {
            return nil
        }

        let store = CNContactStore()

        let keys: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(
                for: .fullName
            )
        ]

        // First use Apple's own phone-number matching predicate.
        do {
            let predicate = CNContact.predicateForContacts(
                matching: CNPhoneNumber(
                    stringValue: rawNumber
                )
            )

            let contacts = try store.unifiedContacts(
                matching: predicate,
                keysToFetch: keys
            )

            if let contact = contacts.first,
               let metadata = metadata(
                    from: contact,
                    requestedNumber: rawNumber
               ) {
                return metadata
            }
        } catch {
            // Fall through to the conservative canonical-digit scan.
        }

        // Local cellular numbers can arrive in different forms. Example:
        //   989997248
        //   +992989997248
        // Apple's direct predicate normally handles common formats, but this
        // fallback deliberately handles country-prefix differences too.
        let requestedDigits = canonicalDigits(rawNumber)
        guard requestedDigits.count >= 8 else {
            return nil
        }

        var best:
            (
                score: Int,
                contact: CNContact,
                phone: String
            )?

        do {
            let request = CNContactFetchRequest(
                keysToFetch: keys
            )
            request.unifyResults = true

            try store.enumerateContacts(
                with: request
            ) { contact, stop in
                for labeled in contact.phoneNumbers {
                    let candidate =
                        labeled.value.stringValue
                    let candidateDigits =
                        canonicalDigits(candidate)
                    let score = matchScore(
                        requestedDigits,
                        candidateDigits
                    )

                    guard score > 0 else {
                        continue
                    }

                    if best == nil ||
                       score > best!.score {
                        best = (
                            score,
                            contact,
                            candidate
                        )
                    }

                    if score >= 100 {
                        stop.pointee = true
                        return
                    }
                }
            }
        } catch {
            return nil
        }

        guard let best else {
            return nil
        }

        return metadata(
            from: best.contact,
            requestedNumber: rawNumber,
            preferredPhone: best.phone
        )
    }

    nonisolated private static func metadata(
        from contact: CNContact,
        requestedNumber: String,
        preferredPhone: String? = nil
    ) -> ContactCallMetadata? {
        let requestedDigits =
            canonicalDigits(requestedNumber)

        var selectedPhone = preferredPhone
        var selectedScore = -1

        if selectedPhone == nil {
            for labeled in contact.phoneNumbers {
                let candidate =
                    labeled.value.stringValue
                let score = matchScore(
                    requestedDigits,
                    canonicalDigits(candidate)
                )

                if score > selectedScore {
                    selectedScore = score
                    selectedPhone = candidate
                }
            }
        }

        guard let selectedPhone else {
            return nil
        }

        let formattedName =
            CNContactFormatter.string(
                from: contact,
                style: .fullName
            )?
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        let organization =
            contact.organizationName
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

        let name: String?
        if let formattedName,
           !formattedName.isEmpty {
            name = formattedName
        } else if !organization.isEmpty {
            name = organization
        } else {
            name = nil
        }

        let normalized =
            normalizedHandle(selectedPhone)

        return ContactCallMetadata(
            rawNumber: requestedNumber,
            normalizedNumber: normalized,
            formattedNumber:
                selectedPhone.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    ? formatDisplayNumber(normalized)
                    : selectedPhone,
            displayName: name,
            contactIdentifier: contact.identifier,
            thumbnailImageData:
                contact.thumbnailImageData
        )
    }

    nonisolated private static func matchScore(
        _ lhs: String,
        _ rhs: String
    ) -> Int {
        guard lhs.count >= 8, rhs.count >= 8 else {
            return 0
        }

        if lhs == rhs {
            return 100
        }

        let shorter =
            lhs.count <= rhs.count ? lhs : rhs
        let longer =
            lhs.count > rhs.count ? lhs : rhs
        let difference =
            longer.count - shorter.count

        // Conservative fallback:
        // - at least 8 matching subscriber digits;
        // - only a short country/trunk prefix may differ.
        if difference <= 4,
           shorter.count >= 8,
           longer.hasSuffix(shorter) {
            return 90 - difference
        }

        return 0
    }

    nonisolated private static func canonicalDigits(
        _ value: String
    ) -> String {
        var digits =
            value.filter { $0.isNumber }

        if value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).hasPrefix("00"),
           digits.hasPrefix("00") {
            digits.removeFirst(2)
        }

        return digits
    }

    nonisolated private static func normalizedHandle(
        _ value: String
    ) -> String {
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let digits = canonicalDigits(trimmed)

        if trimmed.hasPrefix("00") {
            return "+" + digits
        }

        if trimmed.hasPrefix("+") {
            return "+" + digits
        }

        return digits
    }

    nonisolated private static func formatDisplayNumber(
        _ value: String
    ) -> String {
        let normalized = normalizedHandle(value)
        let isInternational =
            normalized.hasPrefix("+")
        let digits =
            normalized.filter { $0.isNumber }

        // Tajikistan cellular style used by the J6 SIM in this project:
        // +992 98 999 7248 / 98 999 7248
        if digits.hasPrefix("992"),
           digits.count == 12 {
            let country = digits.prefix(3)
            let national = digits.dropFirst(3)
            let a = national.prefix(2)
            let b = national.dropFirst(2).prefix(3)
            let c = national.dropFirst(5)

            return
                "+\(country) \(a) \(b) \(c)"
        }

        if !isInternational,
           digits.count == 9 {
            let a = digits.prefix(2)
            let b = digits.dropFirst(2).prefix(3)
            let c = digits.dropFirst(5)
            return "\(a) \(b) \(c)"
        }

        guard digits.count > 4 else {
            return normalized
        }

        // Generic readable fallback: group from the right in threes.
        var groups: [String] = []
        var remaining = digits

        while remaining.count > 3 {
            let split =
                remaining.index(
                    remaining.endIndex,
                    offsetBy: -3
                )
            groups.insert(
                String(remaining[split...]),
                at: 0
            )
            remaining =
                String(remaining[..<split])
        }

        if !remaining.isEmpty {
            groups.insert(remaining, at: 0)
        }

        let body = groups.joined(separator: " ")
        return isInternational
            ? "+" + body
            : body
    }
}
