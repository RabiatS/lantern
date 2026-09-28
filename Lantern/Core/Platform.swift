import Foundation

/// The words and numbers that differ between the phone and the Mac, in one
/// place, so the copy says "this Mac" on a Mac and the estimates use a
/// laptop's power draw rather than a phone's.
nonisolated enum Platform {
    #if os(macOS)
    /// "phone" or "Mac", for sentences like "nothing leaves this Mac".
    static let device = "Mac"
    /// The product name, for "This Mac" on the device card.
    static let product = "Mac"
    static let symbol = "laptopcomputer"
    /// Watts an Apple silicon Mac draws while its GPU writes a reply. An M-series
    /// laptop under sustained GPU load sits around 15 to 30 watts; 20 is used.
    static let wattsWhileGenerating = 20.0
    /// Where benchmark and diagnostic files land.
    static let filesPlace = "Lantern's Documents folder on this Mac"
    /// No mobile data on a Mac, so no Wi-Fi-only switch.
    static let hasCellular = false
    #else
    /// iPad or iPhone, read from the hardware model rather than assumed.
    static let isPad = DeviceCapability.hardwareModel().hasPrefix("iPad")
    static let device = isPad ? "iPad" : "phone"
    static let product = isPad ? "iPad" : "iPhone"
    static let symbol = isPad ? "ipad" : "iphone"
    /// A phone SoC under sustained GPU load sits around four to eight watts; six is used.
    static let wattsWhileGenerating = 6.0
    static let filesPlace = "the Files app"
    /// Wi-Fi-only iPads have no mobile data either, but the switch is harmless there.
    static let hasCellular = true
    #endif
}

nonisolated extension Platform {
    /// What Apple Intelligence needs, in the words of this platform.
    static var appleRequirement: String {
        #if os(macOS)
        "An Apple silicon Mac"
        #else
        "iPhone 15 Pro or later"
        #endif
    }
}
