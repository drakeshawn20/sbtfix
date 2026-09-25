import AppKit
import SwiftUI
import SonyProtocol

/// `sbtfix --screenshots <dir>` renders the menu panel in each state to PNGs and exits.
/// Used to produce the images in docs/screenshots. Offscreen captures draw "on" switches in
/// their inactive (gray) style, so the sample states keep switches off.
enum Screenshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let earbuds = Batteries(left: BatteryLevel(level: 80, charging: false),
                                right: BatteryLevel(level: 76, charging: false),
                                caseBattery: BatteryLevel(level: 45, charging: true))
        let shots: [(String, HeadphoneController)] = [
            ("noise-cancelling", .preview(status: .connected)),
            ("ambient", .preview(status: .connected,
                                 ambient: AmbientState(mode: .ambient, focusOnVoice: false, level: 14))),
            ("off", .preview(status: .connected, ambient: AmbientState(mode: .off, focusOnVoice: false, level: 20))),
            ("wind-xm4", .preview(status: .connected, name: "WH-1000XM4",
                                  ambient: AmbientState(mode: .windNoiseReduction, focusOnVoice: false, level: 20))),
            ("earbuds", .preview(status: .connected, name: "WF-1000XM5", batteries: earbuds)),
            ("waiting", .preview(status: .searching, batteries: Batteries())),
            ("connecting", .preview(status: .connecting, batteries: Batteries())),
            ("bluetooth-off", .preview(status: .failed("Bluetooth is turned off"), batteries: Batteries())),
        ]
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            for (name, controller) in shots {
                let url = dir.appendingPathComponent("\(name)-\(suffix).png")
                snapshot(ControlPanel(controller: controller), appearance: appearance, to: url)
            }
        }
    }

    private static func snapshot<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        // Mimic the menu-bar popover: rounded panel on the system window background.
        let panel = NSView(frame: hosting.frame)
        panel.appearance = hosting.appearance
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.masksToBounds = true
        panel.addSubview(hosting)

        let window = NSWindow(contentRect: panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = panel
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        panel.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        guard let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { return }
        rep.size = panel.bounds.size
        panel.cacheDisplay(in: panel.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
