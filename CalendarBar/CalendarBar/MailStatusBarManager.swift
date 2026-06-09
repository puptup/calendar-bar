import AppKit
import SwiftUI

@MainActor
final class MailStatusBarManager: NSObject, NSPopoverDelegate {
    static let shared = MailStatusBarManager()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var popoverSizeObserver: NSObjectProtocol?
    private var lastPopoverSize = NSSize(width: MailPopoverMetrics.listWidth, height: MailPopoverMetrics.height)

    private override init() {
        super.init()
        popoverSizeObserver = NotificationCenter.default.addObserver(
            forName: .mailPopoverSizeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let width = notification.userInfo?["width"] as? CGFloat,
                  let height = notification.userInfo?["height"] as? CGFloat else { return }
            Task { @MainActor in
                self?.updatePopoverSize(width: width, height: height)
            }
        }
    }

    deinit {
        if let popoverSizeObserver {
            NotificationCenter.default.removeObserver(popoverSizeObserver)
        }
    }

    func install() {
        guard statusItem == nil else {
            updateIcon()
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateIcon()
    }

    func uninstall() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        }
        popover = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        lastPopoverSize = NSSize(width: MailPopoverMetrics.listWidth, height: MailPopoverMetrics.height)
    }

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let store = SettingsStore.shared
        let imageName = store.isLoggedIn ? "envelope" : "envelope.badge"
        button.image = menuBarImage(named: imageName)
        button.imagePosition = .imageLeading
    }

    func updateTitle(_ title: String) {
        guard let button = statusItem?.button else { return }
        button.title = title.isEmpty ? "" : " \(title)"
    }

    private func menuBarImage(named symbolName: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CalendarBar Mail")?
            .withSymbolConfiguration(config) else { return nil }
        image.isTemplate = true
        return image
    }

    @objc private func togglePanel(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }

        showPanel(relativeTo: button)
    }

    func showPanel() {
        guard let button = statusItem?.button else { return }
        showPanel(relativeTo: button)
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        let popover = ensurePopover()
        if popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidShow(_ notification: Notification) {
        SettingsStore.shared.refreshLaunchAtLoginStatus()
    }

    private func ensurePopover() -> NSPopover {
        if let popover { return popover }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: MailPopoverMetrics.listWidth, height: MailPopoverMetrics.height)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = makePopoverViewController()
        self.popover = popover
        return popover
    }

    private func makePopoverViewController() -> NSViewController {
        let hostingController = NSHostingController(rootView: MailContentView())
        hostingController.view.frame = NSRect(
            x: 0,
            y: 0,
            width: MailPopoverMetrics.listWidth,
            height: MailPopoverMetrics.height
        )
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView(frame: hostingController.view.frame)
            glassView.cornerRadius = 16
            glassView.style = .regular
            glassView.contentView = hostingController.view

            let controller = NSViewController()
            controller.view = glassView
            return controller
        }

        let effectView = NSVisualEffectView(frame: hostingController.view.frame)
        effectView.material = .popover
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        hostingController.view.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingController.view)

        let controller = NSViewController()
        controller.view = effectView
        return controller
    }

    private func updatePopoverSize(width: CGFloat, height: CGFloat) {
        guard let popover else { return }
        let size = NSSize(width: width, height: height)
        guard size != lastPopoverSize else { return }
        lastPopoverSize = size
        popover.contentSize = size

        guard let containerView = popover.contentViewController?.view else { return }
        containerView.frame.size = size

        if #available(macOS 26.0, *), let glassView = containerView as? NSGlassEffectView {
            glassView.frame.size = size
            glassView.contentView?.frame = glassView.bounds
        } else if let effectView = containerView as? NSVisualEffectView {
            effectView.frame.size = size
            effectView.subviews.first?.frame = effectView.bounds
        }
    }
}
