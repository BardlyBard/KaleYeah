import Foundation
import SwiftData

@Model
final class PersistedFlag {
    var id: UUID
    var name: String
    var colorHex: String
    var sortOrder: Int

    init(id: UUID = UUID(), name: String, colorHex: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }
}

@Model
final class PersistedAppSettings {
    var id: UUID
    var sortRaw: String
    var filterRaw: String
    var vipAddressesCSV: String
    var notificationPolicyRaw: String
    /// JSON blob mirroring account toggles / signatures for Stage 1 persistence.
    var accountsJSON: Data?
    var foldersJSON: Data?
    var ladderOrderJSON: Data?

    init(
        id: UUID = UUID(),
        sortRaw: String = MessageSort.dateNewest.rawValue,
        filterRaw: String = MessageFilter.all.rawValue,
        vipAddressesCSV: String = "",
        notificationPolicyRaw: String = "focusAware",
        accountsJSON: Data? = nil,
        foldersJSON: Data? = nil,
        ladderOrderJSON: Data? = nil
    ) {
        self.id = id
        self.sortRaw = sortRaw
        self.filterRaw = filterRaw
        self.vipAddressesCSV = vipAddressesCSV
        self.notificationPolicyRaw = notificationPolicyRaw
        self.accountsJSON = accountsJSON
        self.foldersJSON = foldersJSON
        self.ladderOrderJSON = ladderOrderJSON
    }
}
