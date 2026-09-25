import Foundation

/// What a model supports, keyed by its Bluetooth name. Derived from Gadgetbridge's device
/// coordinators. Anything not listed gets a permissive default, and the app hides features
/// the device never answers for (e.g. Speak-to-Chat).
public struct DeviceProfile: Equatable {
    public var hasAmbientControl = true
    public var hasNoiseCancelling = true
    public var hasWindNoiseReduction = false
    public var isEarbuds = false

    public init() {}

    public static func forName(_ name: String) -> DeviceProfile {
        var p = DeviceProfile()
        p.isEarbuds = name.contains("WF-") || name.contains("LinkBuds")

        // Order matters: "LinkBuds S" must match before "LinkBuds".
        if ["WH-1000XM2", "WH-1000XM3", "WH-1000XM4", "WF-1000XM3", "WF-1000XM4", "WI-SP600N"]
            .contains(where: name.contains) {
            p.hasWindNoiseReduction = true
        } else if name.contains("WF-C510") {
            p.hasNoiseCancelling = false
        } else if ["WF-C500", "WI-C100"].contains(where: name.contains)
                    || (name.contains("LinkBuds") && !name.contains("LinkBuds S")) {
            p.hasAmbientControl = false
        }
        return p
    }

    /// Returns true for names that look like Sony audio devices. "LE_" entries are the
    /// LE Audio twins of newer models; they don't carry the control service.
    public static func isSony(name: String) -> Bool {
        !name.hasPrefix("LE_") && ["WH-", "WF-", "WI-", "LinkBuds", "ULT WEAR", "Sony ULT"].contains(where: name.contains)
    }

    /// The ambient modes to offer, given what the device has reported about itself.
    public func modes(layout: AmbientLayout?) -> [AmbientMode] {
        guard hasAmbientControl else { return [] }
        var modes: [AmbientMode] = []
        if hasNoiseCancelling { modes.append(.noiseCancelling) }
        if hasWindNoiseReduction || layout?.supportsWind == true { modes.append(.windNoiseReduction) }
        modes += [.ambient, .off]
        return modes
    }

    public var batteryKinds: [BatteryKind] {
        isEarbuds ? [.dual, .dualAlt, .caseBattery] : [.single]
    }
}
