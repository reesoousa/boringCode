//
//  WindowDragMonitor.swift
//  boringCode
//
//  Percebe quando você arrasta a janela de outro app e a leva até o notch: aí o
//  notch abre com os layouts e, ao soltar numa zona, a janela se encaixa.
//
//  Como sabe que é uma janela (e não um texto ou arquivo sendo arrastado): no
//  clique guarda a janela sob o ponteiro e a posição dela; se, arrastando, ela
//  anda do mesmo tamanho, é a janela que está vindo junto. Só olha a lista de
//  janelas no clique e nos primeiros movimentos — depois, só a posição do mouse.
//
//  Durante o arraste o mouse pertence ao outro app, então o notch não recebe
//  hover: o acerto das zonas é feito aqui, com a posição global do ponteiro e os
//  retângulos que as miniaturas registram (em coordenadas de tela).
//

import AppKit
import Combine
import Defaults

@MainActor
final class WindowDragMonitor: ObservableObject {
    static let shared = WindowDragMonitor()

    struct DraggedWindow: Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        let appName: String
    }

    /// Janela confirmada em arraste (nil = nada sendo arrastado).
    @Published private(set) var draggedWindow: DraggedWindow?
    /// Tela cujo notch mostra os layouts agora.
    @Published private(set) var pickerScreenUUID: String?
    /// Zona sob o ponteiro.
    @Published private(set) var hoveredTarget: SnapTarget? {
        didSet { if hoveredTarget != oldValue { updatePreview() } }
    }
    /// Logo depois de encaixar o ponteiro continua no notch: segura a abertura por hover
    /// até ele sair dali (senão o notch reabria sozinho em cima da janela recém-encaixada).
    @Published private(set) var holdsHoverOpen = false
    /// O helper tem a permissão de Acessibilidade? Sem ela não dá para mexer em janelas
    /// de outros apps: o notch avisa e, ao soltar, abre o pedido do sistema.
    @Published private(set) var canMoveWindows = true

    private struct Candidate {
        let windowID: CGWindowID
        let pid: pid_t
        let appName: String
        let startBounds: CGRect
        let downPoint: CGPoint
        var lastCheck: CFTimeInterval = 0
    }

    private var monitors: [Any] = []
    private var enabledCancellable: AnyCancellable?
    private var authorizationObserver: Any?
    private var candidate: Candidate?
    private var activation: (screenUUID: String, task: Task<Void, Never>)?
    private struct WeakView { weak var view: NSView? }
    /// Miniatura de cada layout no notch, registrada pela view.
    private var regionViews: [String: WeakView] = [:]
    private var holdReleaseTask: Task<Void, Never>?

    /// Quanto o ponteiro precisa ficar perto do notch antes de abrir (evita abrir de passagem).
    private let activationDelay: Duration = .milliseconds(110)
    /// Perto do notch fechado: até 150 pt para os lados e 90 pt para baixo do topo.
    private let activationOutset = CGSize(width: 150, height: 90)
    /// Com os layouts abertos, a área que os mantém abertos é o notch aberto com folga.
    private let retainOutset = CGSize(width: 50, height: 60)
    /// Folga para acertar uma zona com o ponteiro um pouco fora dela.
    private let hitTolerance: CGFloat = 12

    private init() {}

    // MARK: - Ligar e desligar

    func start() {
        enabledCancellable = Defaults.publisher(.windowSnapEnabled)
            .sink { [weak self] change in
                Task { @MainActor in self?.setMonitoring(change.newValue) }
            }
        authorizationObserver = NotificationCenter.default.addObserver(
            forName: .accessibilityAuthorizationChanged, object: nil, queue: .main
        ) { [weak self] notification in
            guard let granted = notification.userInfo?["granted"] as? Bool else { return }
            MainActor.assumeIsolated { self?.canMoveWindows = granted }
        }
    }

    private func refreshAuthorization() {
        Task { @MainActor in
            canMoveWindows = await XPCHelperClient.shared.isAccessibilityAuthorized()
        }
    }

    private func setMonitoring(_ enabled: Bool) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        reset()
        guard enabled else { return }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(monitor)
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: mouseDown()
        case .leftMouseDragged: mouseDragged()
        case .leftMouseUp: mouseUp()
        default: break
        }
    }

    // MARK: - Eventos

    private func mouseDown() {
        reset()
        candidate = Self.windowUnderPointer()
    }

    private func mouseDragged() {
        let pointer = NSEvent.mouseLocation
        if draggedWindow == nil {
            confirmDragIfWindowMoved(pointer: pointer)
            guard draggedWindow != nil else { return }
        }
        track(pointer)
    }

    private func mouseUp() {
        defer { reset() }
        guard let window = draggedWindow, let target = hoveredTarget,
              let uuid = pickerScreenUUID, let screen = NSScreen.screen(withUUID: uuid) else { return }

        holdHoverOpen()
        guard canMoveWindows else {
            // Mostra o pedido do sistema (com o botão para abrir os Ajustes).
            XPCHelperClient.shared.requestAccessibilityAuthorization()
            return
        }
        // A prévia fica onde a janela vai chegar e some quando ela chega.
        WindowSnapPreview.shared.keepVisibleUntilSnapped()
        WindowSnapper.snap(window, to: target.zone, on: screen) {
            WindowSnapPreview.shared.hide()
        }
    }

    // MARK: - Arraste

    private func confirmDragIfWindowMoved(pointer: CGPoint) {
        guard var candidate else { return }
        let now = CACurrentMediaTime()
        guard now - candidate.lastCheck > 0.035 else { return }
        candidate.lastCheck = now
        self.candidate = candidate

        guard let bounds = Self.bounds(of: candidate.windowID) else {
            self.candidate = nil
            return
        }
        let start = candidate.startBounds
        let sameSize = abs(bounds.width - start.width) < 1 && abs(bounds.height - start.height) < 1
        let moved = hypot(bounds.minX - start.minX, bounds.minY - start.minY) >= 3

        if moved && sameSize {
            draggedWindow = DraggedWindow(windowID: candidate.windowID, pid: candidate.pid, appName: candidate.appName)
            self.candidate = nil
        } else if !sameSize || hypot(pointer.x - candidate.downPoint.x, pointer.y - candidate.downPoint.y) > 120 {
            // Redimensionando, ou o ponteiro andou e a janela não: é outro tipo de arraste.
            self.candidate = nil
        }
    }

    private func track(_ pointer: CGPoint) {
        if let uuid = pickerScreenUUID {
            if let screen = NSScreen.screen(withUUID: uuid), retainArea(on: screen).contains(pointer) {
                hoveredTarget = hitTest(pointer)
            } else {
                closePicker()
            }
            return
        }

        guard let screen = notchScreens().first(where: { activationArea(on: $0).contains(pointer) }),
              let uuid = screen.displayUUID else {
            cancelActivation()
            return
        }
        guard activation?.screenUUID != uuid else { return }
        cancelActivation()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.activationDelay)
            guard !Task.isCancelled, self.draggedWindow != nil,
                  NSEvent.pressedMouseButtons & 1 != 0,
                  self.activationArea(on: screen).contains(NSEvent.mouseLocation) else { return }
            self.activation = nil
            self.pickerScreenUUID = uuid
            self.refreshAuthorization()
        }
        activation = (uuid, task)
    }

    private func cancelActivation() {
        activation?.task.cancel()
        activation = nil
    }

    private func closePicker() {
        cancelActivation()
        hoveredTarget = nil
        pickerScreenUUID = nil
    }

    private func reset() {
        candidate = nil
        draggedWindow = nil
        closePicker()
    }

    // MARK: - Zonas

    /// As miniaturas dos layouts se registram enquanto estão no notch.
    func registerRegion(_ view: NSView, for layoutID: String) {
        regionViews[layoutID] = WeakView(view: view)
    }

    func unregisterRegion(_ view: NSView, for layoutID: String) {
        if regionViews[layoutID]?.view === view { regionViews[layoutID] = nil }
    }

    /// Onde a miniatura está agora, em coordenadas de tela do Cocoa.
    private func region(for layoutID: String) -> CGRect? {
        guard let view = regionViews[layoutID]?.view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    private func hitTest(_ point: CGPoint) -> SnapTarget? {
        var best: (target: SnapTarget, distance: CGFloat)?
        for layout in SnapLayout.all {
            guard let card = region(for: layout.id) else { continue }
            for zone in layout.zones {
                // Zona em frações com origem em cima; a tela do Cocoa tem origem embaixo.
                let rect = CGRect(
                    x: card.minX + card.width * zone.rect.minX,
                    y: card.maxY - card.height * zone.rect.maxY,
                    width: card.width * zone.rect.width,
                    height: card.height * zone.rect.height
                )
                let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
                let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
                let distance = hypot(dx, dy)
                if distance == 0 { return SnapTarget(layoutID: layout.id, zone: zone) }
                if distance <= hitTolerance, distance < (best?.distance ?? .infinity) {
                    best = (SnapTarget(layoutID: layout.id, zone: zone), distance)
                }
            }
        }
        return best?.target
    }

    // MARK: - Prévia e hover

    private func updatePreview() {
        guard let target = hoveredTarget, let window = draggedWindow,
              let uuid = pickerScreenUUID, let screen = NSScreen.screen(withUUID: uuid) else {
            WindowSnapPreview.shared.hide()
            return
        }
        WindowSnapPreview.shared.show(
            WindowSnapper.targetFrame(for: target.zone, on: screen),
            on: screen,
            below: window.windowID
        )
    }

    private func holdHoverOpen() {
        holdsHoverOpen = true
        holdReleaseTask?.cancel()
        // Rede de segurança: se o ponteiro nunca sair, libera sozinho.
        holdReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.holdsHoverOpen = false
        }
    }

    /// O ponteiro saiu do notch: o hover volta ao normal.
    func pointerLeftNotch() {
        holdReleaseTask?.cancel()
        holdsHoverOpen = false
    }

    // MARK: - Geometria

    /// Telas que têm a janela do notch.
    private func notchScreens() -> [NSScreen] {
        if Defaults[.displayMode] == .allDisplays { return NSScreen.screens }
        let selected = NSScreen.screen(withUUID: BoringViewCoordinator.shared.selectedScreenUUID) ?? NSScreen.main
        return selected.map { [$0] } ?? []
    }

    private func activationArea(on screen: NSScreen) -> CGRect {
        let notch = getClosedNotchSize(screenUUID: screen.displayUUID)
        let width = notch.width + activationOutset.width * 2
        return CGRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - max(notch.height, 24) - activationOutset.height,
            width: width,
            height: max(notch.height, 24) + activationOutset.height + 1
        )
    }

    private func retainArea(on screen: NSScreen) -> CGRect {
        let width = openNotchSize.width + retainOutset.width * 2
        let height = openNotchSize.height + retainOutset.height
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height + 1)
    }

    // MARK: - Lista de janelas (CoreGraphics)

    /// A janela comum (camada 0) que está sob o ponteiro, se for de outro app.
    private static func windowUnderPointer() -> Candidate? {
        let pointer = NSEvent.mouseLocation
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        // CoreGraphics conta y de cima para baixo a partir da tela principal.
        let cgPoint = CGPoint(x: pointer.x, y: primaryMaxY - pointer.y)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.contains(cgPoint) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            // Só janelas comuns. Camadas de cima (Dock, que tem uma invisível do tamanho da
            // tela, menus, painéis) ficam de fora; se o clique foi num menu, a janela de
            // baixo vira candidata mas não anda, então nunca é confirmada.
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let name = info[kCGWindowOwnerName as String] as? String
                ?? NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
            return Candidate(windowID: id, pid: pid, appName: name, startBounds: bounds, downPoint: pointer)
        }
        return nil
    }

    private static func bounds(of windowID: CGWindowID) -> CGRect? {
        // A função quer um CFArray de CGWindowID "crus" (não NSNumber).
        var raw: UnsafeRawPointer? = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let ids = CFArrayCreate(kCFAllocatorDefault, &raw, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let boundsDict = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: boundsDict)
    }
}
