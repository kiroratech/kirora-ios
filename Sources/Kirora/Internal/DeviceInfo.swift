import Foundation

/// What the device says of itself, read when needed: the user may change language or time
/// zone while the app runs. Never a hardware or advertising id, or a device model.
struct DeviceInfo {
    var appVersion: () -> String? = { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    var appBuild: () -> String? = { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    var osVersion: () -> String? = { DeviceInfo.systemVersion() }
    /// The user's preferred language as BCP 47 (`en-GB`), as the platform gives it.
    var locale: () -> String? = { Locale.preferredLanguages.first }
    var timezone: () -> String? = { TimeZone.current.identifier }

    /// As `UIDevice.systemVersion` writes it (`17.4`, `17.4.1`), without needing the main
    /// thread.
    static func systemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// The four device fields a push registration carries, leaving out what the device
    /// can't read and never sending an empty string.
    func registrationDetails() -> [String: JSONValue] {
        var details: [String: JSONValue] = [:]
        for (key, value) in [
            ("appVersion", appVersion()), ("osVersion", osVersion()),
            ("locale", locale()), ("timezone", timezone()),
        ] {
            if let value, !value.isEmpty { details[key] = .string(value) }
        }
        return details
    }
}

// Closures read only immutable globals (`Bundle.main`, `ProcessInfo`, `Locale`).
extension DeviceInfo: @unchecked Sendable {}

/// `device.id`: a random id made on first use and kept in the app's own storage. It is
/// also the device's `externalInstallationId` for push.
struct DeviceId: Sendable {
    let store: KeyValueStore

    func value() -> String {
        if let stored = store.string(StorageKeys.deviceId) { return stored }
        let id = newId()
        store.set(id, for: StorageKeys.deviceId)
        return id
    }

    func remove() {
        store.set(nil, for: StorageKeys.deviceId)
    }
}
