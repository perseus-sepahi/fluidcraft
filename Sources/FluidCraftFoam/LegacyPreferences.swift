import Foundation

/// Carries preferences over from before the app was renamed from Curlew: the old bundle
/// identifier's defaults (`curlew.*` keys) become this app's `fluidcraft.*` keys, once.
/// Window sizes and other system-written entries are left behind.
public enum LegacyPreferences {
    public static let oldDomain = "com.williamsepahi.curlew"
    public static let doneKey = "fluidcraft.migratedFromCurlew"

    public static func migrate(into defaults: UserDefaults = .standard, from domain: String = oldDomain) {
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: domain) else { return }
        for (key, value) in old where key.hasPrefix("curlew.") {
            let newKey = "fluidcraft." + key.dropFirst("curlew.".count)
            if defaults.object(forKey: newKey) == nil { defaults.set(value, forKey: newKey) }
        }
    }
}
