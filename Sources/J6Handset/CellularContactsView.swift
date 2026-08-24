import Contacts
import Foundation
import ImageIO
import SwiftUI
import UIKit

struct CellularContactSelection: Identifiable, Hashable, Sendable {
    let id: String
}

enum CellularContactAction: Equatable, Sendable {
    case call(String)
    case message(String)
}

private struct CellularContactPhone: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let number: String

    var displayLabel: String {
        label.isEmpty ? "phone" : label
    }

    var menuTitle: String {
        label.isEmpty ? number : "\(label): \(number)"
    }
}

private struct CellularContactListEntry: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let primaryPhoneText: String?
    let thumbnailImageData: Data?
    let searchIndex: String

    var initials: String {
        Self.initials(from: displayName)
    }

    static func initials(from value: String) -> String {
        let characters = value
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap(\.first)

        let result = String(characters).uppercased()
        return result.isEmpty ? "?" : result
    }
}

private struct CellularContactDetail: Equatable, Sendable {
    let id: String
    let displayName: String
    let organization: String?
    let imageData: Data?
    let phoneNumbers: [CellularContactPhone]

    var initials: String {
        CellularContactListEntry.initials(from: displayName)
    }
}

private struct CellularContactListLoadResult: Sendable {
    let entries: [CellularContactListEntry]
    let errorMessage: String?
}

private struct CellularContactDetailLoadResult: Sendable {
    let contact: CellularContactDetail?
    let errorMessage: String?
}

private enum CellularContactLoader {
    nonisolated static func loadEntries() -> CellularContactListLoadResult {
        guard canReadContacts else {
            return CellularContactListLoadResult(
                entries: [],
                errorMessage: nil
            )
        }

        let keys: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        request.unifyResults = true

        var entries: [CellularContactListEntry] = []

        do {
            try CNContactStore().enumerateContacts(
                with: request
            ) { contact, stop in
                if Task.isCancelled {
                    stop.pointee = true
                    return
                }

                let phones = phoneRecords(from: contact)
                let name = displayName(for: contact, phones: phones)
                let organization = contact.organizationName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let primaryPhoneText = phones.first.map {
                    $0.label.isEmpty
                        ? $0.number
                        : "\($0.label)  \($0.number)"
                }
                let searchIndex = ([
                    name,
                    organization
                ] + phones.flatMap { [$0.label, $0.number] })
                    .joined(separator: " ")
                    .folding(
                        options: [
                            .caseInsensitive,
                            .diacriticInsensitive
                        ],
                        locale: .current
                    )

                entries.append(
                    CellularContactListEntry(
                        id: contact.identifier,
                        displayName: name,
                        primaryPhoneText: primaryPhoneText,
                        thumbnailImageData: contact.thumbnailImageData,
                        searchIndex: searchIndex
                    )
                )
            }

            return CellularContactListLoadResult(
                entries: entries,
                errorMessage: nil
            )
        } catch {
            return CellularContactListLoadResult(
                entries: [],
                errorMessage: "Contacts could not be loaded."
            )
        }
    }

    nonisolated static func loadDetail(
        identifier: String
    ) -> CellularContactDetailLoadResult {
        guard canReadContacts else {
            return CellularContactDetailLoadResult(
                contact: nil,
                errorMessage: "Contacts access is unavailable."
            )
        }

        let keys: [CNKeyDescriptor] = [
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]

        do {
            let contact = try CNContactStore().unifiedContact(
                withIdentifier: identifier,
                keysToFetch: keys
            )
            let phones = phoneRecords(from: contact)
            let name = displayName(for: contact, phones: phones)
            let organizationValue = contact.organizationName
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let organization = organizationValue.isEmpty ||
                organizationValue == name
                ? nil
                : organizationValue

            return CellularContactDetailLoadResult(
                contact: CellularContactDetail(
                    id: contact.identifier,
                    displayName: name,
                    organization: organization,
                    imageData: contact.imageData ??
                        contact.thumbnailImageData,
                    phoneNumbers: phones
                ),
                errorMessage: nil
            )
        } catch {
            return CellularContactDetailLoadResult(
                contact: nil,
                errorMessage: "This contact could not be loaded."
            )
        }
    }

    nonisolated private static var canReadContacts: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .authorized {
            return true
        }
        if #available(iOS 18.0, *), status == .limited {
            return true
        }
        return false
    }

    nonisolated private static func displayName(
        for contact: CNContact,
        phones: [CellularContactPhone]
    ) -> String {
        let formattedName = CNContactFormatter.string(
            from: contact,
            style: .fullName
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let formattedName,
           !formattedName.isEmpty {
            return formattedName
        }

        let organization = contact.organizationName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !organization.isEmpty {
            return organization
        }

        if let number = phones.first?.number,
           !number.isEmpty {
            return number
        }

        return "No Name"
    }

    nonisolated private static func phoneRecords(
        from contact: CNContact
    ) -> [CellularContactPhone] {
        contact.phoneNumbers.enumerated().compactMap { index, labeled in
            let number = labeled.value.stringValue.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !number.isEmpty else { return nil }

            let label = labeled.label.map {
                CNLabeledValue<NSString>.localizedString(forLabel: $0)
            } ?? ""

            return CellularContactPhone(
                id: "\(index)|\(number)",
                label: label,
                number: number
            )
        }
    }
}

struct CellularContactsListView: View {
    @EnvironmentObject private var contacts: ContactResolver

    let onSelect: @MainActor (CellularContactSelection) -> Void

    @State private var allEntries: [CellularContactListEntry] = []
    @State private var displayedEntries: [CellularContactListEntry] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var listRevision = 0

    var body: some View {
        Group {
            if !contacts.canReadContacts {
                accessUnavailableView
            } else if isLoading && allEntries.isEmpty {
                ProgressView("Loading Contacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView(
                    "Contacts Unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(errorMessage)
                )
            } else if displayedEntries.isEmpty {
                emptyView
            } else {
                contactList
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Contacts")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Search")
        )
        .onAppear {
            contacts.requestAccessIfNeeded()
        }
        .task(
            id: "\(contacts.canReadContacts)|\(contacts.contactsRevision)"
        ) {
            await reloadContacts()
        }
        .task(id: "\(searchText)|\(listRevision)") {
            await updateDisplayedEntries()
        }
    }

    @ViewBuilder
    private var emptyView: some View {
        if searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            ContentUnavailableView(
                "No Contacts",
                systemImage: "person.crop.circle"
            )
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    private var contactList: some View {
        List(displayedEntries) { entry in
            Button {
                onSelect(CellularContactSelection(id: entry.id))
            } label: {
                CellularContactRow(entry: entry)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .refreshable {
            await reloadContacts()
        }
    }

    private var accessUnavailableView: some View {
        ContentUnavailableView {
            Label(
                "Contacts Unavailable",
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
        } description: {
            Text(contacts.authorizationText)
        } actions: {
            Button("Review Contact Access") {
                reviewContactAccess()
            }
        }
    }

    private func reviewContactAccess() {
        let status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .notDetermined {
            contacts.requestAccessIfNeeded()
            return
        }

        guard let url = URL(
            string: UIApplication.openSettingsURLString
        ) else {
            return
        }
        UIApplication.shared.open(url)
    }

    private func reloadContacts() async {
        guard contacts.canReadContacts else {
            allEntries = []
            displayedEntries = []
            errorMessage = nil
            isLoading = false
            listRevision &+= 1
            return
        }

        isLoading = true
        let result = await Task.detached(
            priority: .userInitiated
        ) {
            CellularContactLoader.loadEntries()
        }.value
        guard !Task.isCancelled else { return }

        allEntries = result.entries
        errorMessage = result.errorMessage
        isLoading = false
        listRevision &+= 1
    }

    private func updateDisplayedEntries() async {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
        let source = allEntries

        if query.isEmpty {
            displayedEntries = source
            return
        }

        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }

        let matches = await Task.detached(
            priority: .userInitiated
        ) {
            source.filter {
                $0.searchIndex.localizedCaseInsensitiveContains(query)
            }
        }.value
        guard !Task.isCancelled else { return }

        displayedEntries = matches
    }
}

private struct CellularContactRow: View {
    let entry: CellularContactListEntry

    var body: some View {
        HStack(spacing: 12) {
            ContactAvatarView(
                initials: entry.initials,
                imageData: entry.thumbnailImageData,
                cacheKey: "contacts:\(entry.id)",
                size: 42
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let primaryPhoneText = entry.primaryPhoneText {
                    Text(primaryPhoneText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens contact details")
    }
}

struct CellularContactDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let selection: CellularContactSelection
    let onAction: @MainActor (CellularContactAction) -> Void

    @State private var state: DetailState = .loading

    var body: some View {
        ZStack {
            detailBackground

            Group {
                switch state {
                case .loading:
                    ProgressView("Loading Contact…")
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity
                        )

                case .failed(let message):
                    ContentUnavailableView(
                        "Contact Unavailable",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text(message)
                    )

                case .loaded(let contact):
                    detailList(contact)
                }
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
        .task(id: selection.id) {
            await loadContact()
        }
    }

    private var navigationTitle: String {
        if case .loaded(let contact) = state {
            return contact.displayName
        }
        return "Contact"
    }

    @ViewBuilder
    private var detailBackground: some View {
        if case .loaded(let contact) = state {
            ContactDetailPhotoBackground(
                imageData: contact.imageData,
                cacheKey: contact.id
            )
        } else {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
        }
    }

    private func detailList(
        _ contact: CellularContactDetail
    ) -> some View {
        List {
            Section {
                VStack(spacing: 16) {
                    ContactAvatarView(
                        initials: contact.initials,
                        imageData: contact.imageData,
                        cacheKey: "contact-detail:\(contact.id)",
                        size: 112
                    )

                    VStack(spacing: 4) {
                        Text(contact.displayName)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)

                        if let organization = contact.organization {
                            Text(organization)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }

                    actionRow(contact.phoneNumbers)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if contact.phoneNumbers.isEmpty {
                Section {
                    Text("No phone numbers")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Phone Numbers") {
                    ForEach(contact.phoneNumbers) { phone in
                        Button {
                            complete(.call(phone.number))
                        } label: {
                            HStack(spacing: 12) {
                                VStack(
                                    alignment: .leading,
                                    spacing: 3
                                ) {
                                    Text(phone.displayLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Text(phone.number)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "phone.fill")
                                    .foregroundStyle(AppTheme.tint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "Call \(phone.number), \(phone.displayLabel)"
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func actionRow(
        _ phoneNumbers: [CellularContactPhone]
    ) -> some View {
        HStack(spacing: 12) {
            contactAction(
                title: "Call",
                symbol: "phone.fill",
                phoneNumbers: phoneNumbers,
                action: { complete(.call($0)) }
            )

            contactAction(
                title: "Message",
                symbol: "message.fill",
                phoneNumbers: phoneNumbers,
                action: { complete(.message($0)) }
            )
        }
    }

    private func complete(
        _ action: CellularContactAction
    ) {
        onAction(action)
        dismiss()
    }

    @ViewBuilder
    private func contactAction(
        title: String,
        symbol: String,
        phoneNumbers: [CellularContactPhone],
        action: @escaping @MainActor (String) -> Void
    ) -> some View {
        if phoneNumbers.count > 1 {
            Menu {
                ForEach(phoneNumbers) { phone in
                    Button(phone.menuTitle) {
                        action(phone.number)
                    }
                }
            } label: {
                ContactActionLabel(
                    title: title,
                    symbol: symbol,
                    isEnabled: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        } else {
            Button {
                guard let number = phoneNumbers.first?.number else {
                    return
                }
                action(number)
            } label: {
                ContactActionLabel(
                    title: title,
                    symbol: symbol,
                    isEnabled: !phoneNumbers.isEmpty
                )
            }
            .buttonStyle(.plain)
            .disabled(phoneNumbers.isEmpty)
            .accessibilityLabel(title)
        }
    }

    private func loadContact() async {
        state = .loading
        let result = await Task.detached(
            priority: .userInitiated
        ) {
            CellularContactLoader.loadDetail(
                identifier: selection.id
            )
        }.value
        guard !Task.isCancelled else { return }

        if let contact = result.contact {
            state = .loaded(contact)
        } else {
            state = .failed(
                result.errorMessage ??
                    "This contact could not be loaded."
            )
        }
    }

    private enum DetailState: Equatable {
        case loading
        case loaded(CellularContactDetail)
        case failed(String)
    }
}

private struct ContactActionLabel: View {
    let title: String
    let symbol: String
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))

            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(
            isEnabled
                ? AppTheme.tint
                : Color.secondary
        )
        .frame(maxWidth: .infinity, minHeight: 68)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    Color(uiColor: .separator).opacity(0.35),
                    lineWidth: 0.5
                )
        }
        .contentShape(.rect(cornerRadius: 16))
    }
}

private struct ContactDetailPhotoBackground: View {
    let imageData: Data?
    let cacheKey: String

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)

            if let imageData,
               !imageData.isEmpty {
                ContactDetailBackdropImage(
                    imageData: imageData,
                    cacheKey: cacheKey
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1.16)
                .blur(radius: 24, opaque: true)

                Color(uiColor: .systemBackground)
                    .opacity(0.52)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct DecodedContactBackdrop: @unchecked Sendable {
    let image: UIImage
}

private final class ContactDetailBackdropCache: @unchecked Sendable {
    static let shared = ContactDetailBackdropCache()

    let images: NSCache<NSString, UIImage>

    private init() {
        images = NSCache<NSString, UIImage>()
        images.countLimit = 12
        images.totalCostLimit = 24 * 1_024 * 1_024
    }
}

private struct ContactDetailBackdropImage: View {
    let imageData: Data
    let cacheKey: String

    @State private var decodedImage: UIImage?

    private let targetPixelSize = 1_200

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let decodedImage {
                    Image(uiImage: decodedImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.clear
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
            .clipped()
        }
        .task(id: decodeIdentifier) {
            await decodeIfNeeded()
        }
    }

    private var decodeIdentifier: String {
        "\(cacheKey)|\(imageData.count)|\(targetPixelSize)"
    }

    @MainActor
    private func decodeIfNeeded() async {
        let key = decodeIdentifier as NSString
        if let cached = ContactDetailBackdropCache.shared.images.object(
            forKey: key
        ) {
            decodedImage = cached
            return
        }

        let data = imageData
        let pixelSize = targetPixelSize
        let decoded = await Task.detached(priority: .utility) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            ),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil as DecodedContactBackdrop?
            }

            return DecodedContactBackdrop(
                image: UIImage(cgImage: cgImage)
            )
        }.value

        guard !Task.isCancelled,
              let decoded else {
            return
        }

        ContactDetailBackdropCache.shared.images.setObject(
            decoded.image,
            forKey: key,
            cost: targetPixelSize * targetPixelSize * 4
        )
        decodedImage = decoded.image
    }
}
