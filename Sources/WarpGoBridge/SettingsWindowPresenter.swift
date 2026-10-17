import AppKit
import SwiftUI

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private weak var window: NSWindow?
    private var openAction: (() -> Void)?
    private var closeObserver: NSObjectProtocol?
    private var pendingPresentation = false
    private var presentationScheduled = false

    func configureOpenAction(_ action: @escaping () -> Void) {
        let needsOpen = openAction == nil && pendingPresentation
        openAction = action
        if needsOpen { action() }
        schedulePresentation()
    }

    func show(openWindow: @escaping () -> Void) {
        configureOpenAction(openWindow)
        show()
    }

    func show() {
        pendingPresentation = true
        openAction?()
        schedulePresentation()
    }

    func didBecomeActive() {
        schedulePresentation()
    }

    fileprivate func register(_ window: NSWindow) {
        if self.window !== window {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            self.window = window
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window === window else { return }
                    self.pendingPresentation = false
                }
            }
        }
        schedulePresentation()
    }

    private func schedulePresentation() {
        guard pendingPresentation, window != nil, !presentationScheduled else { return }
        presentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            guard self.pendingPresentation, let window = self.window else { return }
            NSApp.unhide(nil)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if NSApp.isActive { self.pendingPresentation = false }
        }
    }
}

@MainActor
struct SettingsWindowRegistration: NSViewRepresentable {
    private let presenter: SettingsWindowPresenter

    init(presenter: SettingsWindowPresenter? = nil) {
        self.presenter = presenter ?? .shared
    }

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.presenter = presenter
        return view
    }

    func updateNSView(_ nsView: RegistrationView, context: Context) {
        nsView.presenter = presenter
        if let window = nsView.window { presenter.register(window) }
    }

    final class RegistrationView: NSView {
        weak var presenter: SettingsWindowPresenter?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { presenter?.register(window) }
        }
    }
}
