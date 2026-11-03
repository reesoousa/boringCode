//
//  boringNotchApp.swift
//  boringNotchApp
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

@MainActor
enum LegacyAppBundleMigration {
    static let legacyBundleName = BoringNotchAppBundleNames.legacy
    static let currentBundleName = BoringNotchAppBundleNames.current
    static var isRelaunching = false

    enum MigrationError: Swift.Error {
        case destinationExists(URL)
    }

    static func destinationURL(for bundleURL: URL) -> URL? {
        guard bundleURL.lastPathComponent == legacyBundleName else { return nil }
        return bundleURL.deletingLastPathComponent()
            .appendingPathComponent(currentBundleName, isDirectory: true)
    }

    @discardableResult
    static func migrateIfNeeded(
        at bundleURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        guard let destinationURL = destinationURL(for: bundleURL) else { return nil }
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw MigrationError.destinationExists(destinationURL)
        }

        try fileManager.moveItem(at: bundleURL, to: destinationURL)
        return destinationURL
    }
}

@main
struct DynamicNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow

    private let sparkleUpdaterDelegate: BoringSparkleUpdaterDelegate
    let updaterController: SPUStandardUpdaterController

    init() {
        #if DEBUG
        OTPDetector.runSelfCheck()
        #endif
        let sparkleUpdaterDelegate = BoringSparkleUpdaterDelegate()
        self.sparkleUpdaterDelegate = sparkleUpdaterDelegate
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: sparkleUpdaterDelegate, userDriverDelegate: nil)
        SoftwareUpdateStore.updater = updaterController.updater

        // Initialize the settings window controller with the updater controller
        SettingsWindowController.shared.setUpdaterController(updaterController)

        let updaterController = self.updaterController
        Task { @MainActor in
            let sourceURL = Bundle.main.bundleURL
            if let destinationURL = LegacyAppBundleMigration.destinationURL(for: sourceURL) {
                let migrated = await XPCHelperClient.shared.migrateLegacyAppBundle(
                    from: sourceURL,
                    to: destinationURL
                )
                if migrated {
                    ApplicationRelauncher.restart(at: destinationURL) {
                        LegacyAppBundleMigration.isRelaunching = true
                    }
                    return
                }
                NSLog("Failed to migrate legacy Boring Notch app bundle at %@", sourceURL.path)
            }
            updaterController.startUpdater()
        }
    }

    var body: some Scene {
        MenuBarExtra("boringCode", image: "menubarIcon", isInserted: $showMenuBarIcon) {
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            CheckForUpdatesView(updater: updaterController.updater)
            Button("Restart Boring Notch") {
                ApplicationRelauncher.restart()
            }
            Button("Quit", role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

@MainActor
enum SoftwareUpdateStore {
    static var updater: SPUUpdater?
}

@MainActor
final class BoringSparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }

    @objc func feedURLString(for updater: SPUUpdater) -> String? {
        Defaults[.updateChannel].feedURLString
    }

    @objc func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Defaults[.updateChannel].allowedSparkleChannels
    }
}

/// App-lifecycle glue: shortcuts, onboarding, termination, observer wiring.
/// All notch-window / per-screen view-model / drag-detector lifecycle lives
/// in `NotchWindowManager` (see managers/NotchWindowManager.swift).
final class AppDelegate: NSObject, NSApplicationDelegate {
    let camera = CameraModel()
    var statusItem: NSStatusItem?
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    var quickShareService = QuickShareService.shared
    var closeNotchTask: Task<Void, Never>?
    private lazy var windowManager = NotchWindowManager(camera: camera)
    private var onboardingWindowController: NSWindowController?
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    private var observers: [Any] = []
    private var activeDisplayObserver: NSObjectProtocol?
    private var displayModeTask: Task<Void, Never>?
    private var observedDisplayMode: DisplayMode?

    /// Kept for existing internal readers; the state itself moved to the manager.
    var windows: [String: NSWindow] { windowManager.windows }
    var viewModels: [String: BoringViewModel] { windowManager.viewModels }
    var window: NSWindow? { windowManager.window }
    var vm: BoringViewModel { windowManager.primaryViewModel }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        SettingsWindowController.shared.showWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if LegacyAppBundleMigration.isRelaunching { return }

        // Flush debounced shelf persistence to avoid losing recent changes
        ShelfStateViewModel.shared.flushSync()

        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MainActor.assumeIsolated {
            MusicManager.shared.destroy()
            windowManager.cleanup()
        }
        BetterDisplayManager.shared.stopObserving()
        LunarManager.shared.stopListening()
        LunarManager.shared.configureLunarOSD(hide: false)
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()

        displayModeTask?.cancel()
        MainActor.assumeIsolated { setActiveDisplayObserver(enabled: false, reposition: false) }
    }

    @MainActor
    func onScreenLocked(_ notification: Notification) {
        windowManager.screenLocked()
    }

    @MainActor
    func onScreenUnlocked(_ notification: Notification) {
        windowManager.screenUnlocked()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Antes de abrir janelas e serviços, para não ficar com dois notches.
        // O app hospedeiro dos testes tem o mesmo bundle ID e não pode fechar o instalado.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            NSRunningApplication.terminateOlderInstances()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsWindowController.shared.setCamera(camera)
        migrateDisplayModeIfNeeded()
        // No app hospedeiro dos testes do Xcode, não mexe nos hooks nem no socket do app instalado.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            // Na primeira abertura o onboarding pergunta antes: os hooks dos agentes e a
            // busca na rede local (que faz o macOS pedir permissão) só começam no "sim"
            // de cada tela, ou ao terminar o onboarding.
            if !BoringViewCoordinator.shared.firstLaunch {
                startAgentAndNetworkServices()
            }
            WindowDragMonitor.shared.start()
            // Só olha o número de mudanças até ter "Sempre permitir": não mostra aviso nenhum sozinho.
            ClipboardHistory.shared.start()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.selectedScreenChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.adjustWindowPosition(changeAlpha: true)
                self?.windowManager.setupDragDetectors()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.notchHeightChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.adjustWindowPosition()
                self?.windowManager.setupDragDetectors()
            }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.expandedDragDetectionChanged, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windowManager.setupDragDetectors()
            }
        })

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) { [weak self] in
            guard let self = self else { return }
            if Defaults[.sneakPeekStyles] == .inline {
                let newStatus = !self.coordinator.expandingView.show
                self.coordinator.toggleExpandingView(status: newStatus, type: .music)
                KeyboardShortcuts.onKeyUp(for: .toggleSneakPeek) {
                    self.coordinator.toggleSneakPeek(
                        status: !self.coordinator.isAnySneakPeekShowing,
                        type: .music
                    )
                }
            } else {
                self.coordinator.toggleSneakPeek(
                    status: !self.coordinator.isAnySneakPeekShowing,
                    type: .music,
                    duration: 3.0
                )
            }
        }

        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            Task { [weak self] in
                guard let self = self else { return }

                let mouseLocation = NSEvent.mouseLocation

                var viewModel = self.vm

                if Defaults[.displayMode] == .allDisplays {
                    for screen in NSScreen.screens {
                        if screen.frame.contains(mouseLocation) {
                            if let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                                viewModel = screenViewModel
                                break
                            }
                        }
                    }
                }

                self.closeNotchTask?.cancel()
                self.closeNotchTask = nil

                switch viewModel.notchState {
                case .closed:
                    var didOpen = false
                    await MainActor.run {
                        didOpen = viewModel.open()
                    }
                    guard didOpen else { return }

                    let task = Task { [weak viewModel] in
                        do {
                            try await Task.sleep(for: .seconds(3))
                            await MainActor.run {
                                viewModel?.close()
                            }
                        } catch { }
                    }
                    self.closeNotchTask = task
                case .open:
                    await MainActor.run {
                        viewModel.close()
                    }
                }
            }
        }

        // boringCode: ⌃⌘V abre o notch direto no clipboard (de novo, fecha), como o Win+V.
        KeyboardShortcuts.onKeyDown(for: .openClipboard) { [weak self] in
            guard let self, Defaults[.clipboardEnabled] else { return }
            let mouseLocation = NSEvent.mouseLocation
            var viewModel = self.vm
            if Defaults[.displayMode] == .allDisplays,
               let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
               let uuid = screen.displayUUID, let screenViewModel = self.viewModels[uuid] {
                viewModel = screenViewModel
            }
            self.closeNotchTask?.cancel()
            self.closeNotchTask = nil

            if viewModel.notchState == .open && self.coordinator.currentView == .clipboard {
                viewModel.close()
                return
            }
            withAnimation(.smooth) { self.coordinator.currentView = .clipboard }
            if viewModel.notchState == .closed {
                _ = viewModel.open()
            }
        }

        // Sync notch height with real value on app launch if mode is matchRealNotchSize
        syncNotchHeightIfNeeded()

        windowManager.prepareInitialWindows()

        displayModeTask = Task { @MainActor [weak self] in
            for await mode in Defaults.updates(.displayMode, initial: true) {
                guard let self else { return }

                let previousMode = self.observedDisplayMode
                self.observedDisplayMode = mode

                if let previousMode, (previousMode == .allDisplays) != (mode == .allDisplays) {
                    self.windowManager.cleanupWindows(shouldInvert: true)
                }

                self.setActiveDisplayObserver(enabled: mode == .activeDisplay, reposition: false)
                self.windowManager.adjustWindowPosition(changeAlpha: true)
                self.windowManager.setupDragDetectors()
            }
        }

        if coordinator.firstLaunch {
            DispatchQueue.main.async {
                self.showOnboardingWindow()
            }
            playWelcomeSound()
        }

        // make sure OSD subsystems are in the right state now that initial
        // notch windows have been created/cleaned up
        coordinator.applyOSDSources()
    }

    /// Pode ser chamado mais de uma vez (cada serviço só liga uma vez e segue o próprio ajuste).
    func startAgentAndNetworkServices() {
        AgentSessionStore.shared.start()
        LocalSendService.shared.start()
    }

    private func migrateDisplayModeIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "displayMode") == nil else { return }

        let mode: DisplayMode
        if Defaults[.showOnAllDisplays] {
            mode = .allDisplays
        } else if Defaults[.followActiveDisplay] {
            mode = .activeDisplay
        } else if Defaults[.automaticallySwitchDisplay] {
            mode = .fallbackIfPreferredUnavailable
        } else {
            mode = .preferredDisplay
        }

        Defaults[.displayMode] = mode
    }

    private static let activeDisplayDidChangeNotification =
        Notification.Name("NSWorkspaceActiveDisplayDidChangeNotification")

    @MainActor
    private func setActiveDisplayObserver(enabled: Bool, reposition: Bool = true) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        if enabled {
            guard activeDisplayObserver == nil else { return }

            activeDisplayObserver = workspaceCenter.addObserver(
                forName: Self.activeDisplayDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.windowManager.adjustWindowPosition(changeAlpha: true)
                    self.windowManager.setupDragDetectors()
                }
            }
        } else if let observer = activeDisplayObserver {
            workspaceCenter.removeObserver(observer)
            activeDisplayObserver = nil
        }

        guard reposition else { return }

        windowManager.adjustWindowPosition(changeAlpha: true)
        windowManager.setupDragDetectors()
    }

    func playWelcomeSound() {
        let audioPlayer = AudioPlayer()
        audioPlayer.play(fileName: "boring", fileExtension: "m4a")
    }

    @objc func screenConfigurationDidChange() {
        windowManager.screenConfigurationDidChange()
    }

    @objc func togglePopover(_ sender: Any?) {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    @objc func showMenu() {
        statusItem?.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(self)
    }

    private func showOnboardingWindow(step: OnboardingStep = .welcome) {
        if onboardingWindowController == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 640),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.center()
            window.title = String(localized: "Onboarding")
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.level = .floating
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    step: step,
                    updater: SoftwareUpdateStore.updater,
                    onFinish: { [weak self] in
                        self?.startAgentAndNetworkServices()
                        window.orderOut(nil)
//                        NSApp.setActivationPolicy(.accessory)
                        window.close()
                        NSApp.deactivate()
                    },
                    onOpenSettings: { [weak self] in
                        self?.startAgentAndNetworkServices()
                        window.close()
                        SettingsWindowController.shared.showWindow()
                    }
                ))
            window.isRestorable = false
            window.identifier = NSUserInterfaceItemIdentifier("OnboardingWindow")

            onboardingWindowController = NSWindowController(window: window)
        }

//        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindowController?.window?.level = .floating
        onboardingWindowController?.window?.makeKeyAndOrderFront(nil)
        onboardingWindowController?.window?.orderFrontRegardless()
    }
}
