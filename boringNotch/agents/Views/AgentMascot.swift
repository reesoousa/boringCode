//
//  AgentMascot.swift
//  boringCode
//
//  O mascote de cada agente desenhado em pixels, como no terminal: o Clawd
//  (o caranguejinho do Claude Code, mesma grade da tela de boas-vindas
//  " ▐▛███▜▌ / ▝▜█████▛▘ / ▘▘ ▝▝") e um bloquinho de terminal ">_" para o Codex.
//  Como no terminal (meio bloco = meia célula), cada pixel é duas vezes mais alto que largo.
//  Cada estado tem sua pose: anda quando roda comandos, digita quando edita,
//  passa os olhos quando lê, acena quando precisa de você e dá um pulinho ao
//  terminar. Parado (Reduzir movimento), fica na pose do estado.
//

import SwiftUI

/// Como o mascote se mexe enquanto o agente trabalha.
enum AgentMascotMotion: Equatable {
    case idle
    case thinking
    case scanning
    case typing
    case walking
}

struct AgentMascot: View {
    let agent: AgentKind
    /// nil = sessão parada (respira e pisca).
    var status: AgentSessionStatus?
    var motion: AgentMascotMotion = .idle
    /// Quando o status mudou — o pulinho do "terminou" e o tremor do erro partem daqui.
    var statusChangedAt: Date = .distantPast
    /// Defasagem para vários mascotes não piscarem juntos.
    var seed: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    static let columns: CGFloat = 18
    static let rows: CGFloat = 5
    /// Altura do pixel em relação à largura (pixel de terminal).
    static let pixelAspect: CGFloat = 2
    static let aspectRatio = columns / (rows * pixelAspect)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let pose = AgentMascotPose.make(
                agent: agent,
                status: status,
                motion: motion,
                time: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate + seed,
                sinceChange: reduceMotion ? 10 : context.date.timeIntervalSince(statusChangedAt)
            )
            Canvas { canvas, size in
                draw(pose, in: &canvas, size: size)
            }
            .scaleEffect(x: 1, y: pose.breath, anchor: .bottom)
            .visualEffect { [dx = pose.dx, dy = pose.dy] content, proxy in
                let unit = min(proxy.size.width / Self.columns, proxy.size.height / (Self.rows * Self.pixelAspect))
                return content.offset(x: dx * unit, y: dy * unit * Self.pixelAspect)
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func draw(_ pose: AgentMascotPose, in canvas: inout GraphicsContext, size: CGSize) {
        // Pixel inteiro na tela (sem borrão nas bordas), centralizado no espaço disponível.
        let raw = min(size.width / Self.columns, size.height / (Self.rows * Self.pixelAspect))
        let u = max(1 / displayScale, (raw * displayScale).rounded(.down) / displayScale)
        let v = u * Self.pixelAspect
        let originX = ((size.width - u * Self.columns) / 2 * displayScale).rounded() / displayScale
        let originY = ((size.height - v * Self.rows) / 2 * displayScale).rounded() / displayScale

        var path = Path()
        for pixel in pose.pixels {
            path.addRect(CGRect(x: originX + CGFloat(pixel.x) * u, y: originY + CGFloat(pixel.y) * v, width: u, height: v))
        }
        canvas.fill(path, with: .color(agent.tint))
    }
}

// MARK: - Poses

struct AgentMascotPose {
    var pixels: [(x: Int, y: Int)] = []
    /// Deslocamento em pixels do mascote (pulinho, tremor, balanço).
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    /// Respiração: escala vertical sutil, ancorada nos pés.
    var breath: CGFloat = 1

    enum Eyes { case center, left, right, closed }
    enum Arms { case side, up, wave, oneUp, down, typeLeft, typeRight }
    enum Legs { case stand, spread }

    static func make(agent: AgentKind, status: AgentSessionStatus?, motion: AgentMascotMotion, time t: Double, sinceChange: Double) -> AgentMascotPose {
        var eyes = Eyes.center
        var arms = Arms.side
        var legs = Legs.stand
        var pose = AgentMascotPose()

        // Piscadas: uma a cada ~4 s, e uma dupla de vez em quando.
        let blinking = t.truncatingRemainder(dividingBy: 4.3) < 0.12
            || (t.truncatingRemainder(dividingBy: 11.7) > 0.3 && t.truncatingRemainder(dividingBy: 11.7) < 0.42)
        let breathe = { (period: Double, depth: Double) in CGFloat(1 + depth * (0.5 + 0.5 * sin(t / period * 2 * .pi))) }

        switch status {
        case .running?:
            switch motion {
            case .walking:
                // Passinhos de caranguejo, com o corpo subindo meio pixel a cada passo.
                let step = Int(t / 0.3) % 2 == 0
                legs = step ? .spread : .stand
                pose.dy = step ? -0.25 : 0
            case .typing:
                arms = Int(t / 0.17) % 2 == 0 ? .typeLeft : .typeRight
            case .scanning:
                // Olhos passando pela linha: esquerda → centro → direita → centro.
                eyes = [.left, .center, .right, .center][Int(t / 0.45) % 4]
            case .thinking, .idle:
                eyes = t.truncatingRemainder(dividingBy: 3.2) < 1.6 ? .left : .right
                pose.dx = 0.5 * sin(t / 3.2 * 2 * .pi)
                pose.breath = breathe(2.4, 0.03)
            }
        case .waitingApproval?:
            // Acenando: precisa de você.
            arms = Int(t / 0.38) % 2 == 0 ? .up : .wave
            pose.dy = sinceChange < 0.45 ? -0.8 * sin(.pi * sinceChange / 0.45) : 0
        case .waitingInput?:
            arms = .oneUp
            eyes = t.truncatingRemainder(dividingBy: 5) < 2.5 ? .center : .right
        case .done?:
            if sinceChange < 0.9 {
                // Pulinho de comemoração, braços para cima.
                arms = .up
                pose.dy = sinceChange < 0.5 ? -1.1 * sin(.pi * sinceChange / 0.5) : 0
            }
            pose.breath = breathe(3.6, 0.025)
        case .error?:
            arms = .down
            if sinceChange < 0.5 {
                pose.dx = 0.9 * sin(sinceChange * 42) * (1 - sinceChange / 0.5)
            }
        case .idle?, nil:
            pose.breath = breathe(3.6, 0.025)
            // De vez em quando olha para os lados.
            let glance = t.truncatingRemainder(dividingBy: 9)
            if glance > 6.4 && glance < 7.3 { eyes = .left } else if glance >= 7.3 && glance < 8.2 { eyes = .right }
        }
        if blinking && eyes != .closed { eyes = .closed }

        switch agent {
        case .claude: pose.pixels = clawd(eyes: eyes, arms: arms, legs: legs)
        case .codex: pose.pixels = codexBlock(status: status, time: t, blink: blinking)
        }
        return pose
    }

    /// Clawd na grade 18×5 da tela de boas-vindas: corpo nas linhas 0–3 (olhos na 1,
    /// braços na 2), patas na 4. Braço erguido sobe até a linha 0, ao lado da cabeça.
    private static func clawd(eyes: Eyes, arms: Arms, legs: Legs) -> [(x: Int, y: Int)] {
        var pixels: [(x: Int, y: Int)] = []
        let eyeColumns: [Int] = switch eyes {
        case .center: [5, 12]
        case .left: [4, 11]
        case .right: [6, 13]
        case .closed: []
        }
        for y in 0...3 {
            for x in 3...14 where !(y == 1 && eyeColumns.contains(x)) {
                pixels.append((x, y))
            }
        }

        func left(_ cells: [(Int, Int)]) { pixels += cells.map { (x: $0.0, y: $0.1) } }
        func right(_ cells: [(Int, Int)]) { pixels += cells.map { (x: 17 - $0.0, y: $0.1) } }
        let side = [(1, 2), (2, 2)]
        let raised = [(1, 0), (1, 1), (2, 1)]
        let waving = [(0, 0), (1, 0), (1, 1), (2, 1)]
        let lowered = [(1, 3), (2, 3)]
        switch arms {
        case .side: left(side); right(side)
        case .up: left(raised); right(raised)
        case .wave: left(waving); right(waving)
        case .oneUp: left(raised); right(side)
        case .down: left(lowered); right(lowered)
        case .typeLeft: left(lowered); right(side)
        case .typeRight: left(side); right(lowered)
        }

        let feet: [Int] = legs == .stand ? [4, 6, 11, 13] : [3, 5, 12, 14]
        pixels += feet.map { (x: $0, y: 4) }
        return pixels
    }

    /// Codex: bloquinho de terminal com ">_" vazado; o cursor pisca enquanto trabalha.
    private static func codexBlock(status: AgentSessionStatus?, time t: Double, blink: Bool) -> [(x: Int, y: Int)] {
        var holes: Set<Int> = [1 * 18 + 4, 2 * 18 + 5, 3 * 18 + 4]  // ">"
        let cursorOn: Bool = switch status {
        case .running?, .waitingApproval?, .waitingInput?: Int(t / 0.5) % 2 == 0
        default: !blink
        }
        if cursorOn { holes.formUnion([3 * 18 + 7, 3 * 18 + 8, 3 * 18 + 9]) }  // "_"
        var pixels: [(x: Int, y: Int)] = []
        for y in 0...4 {
            let range = (y == 0 || y == 4) ? 2...15 : 1...16
            for x in range where !holes.contains(y * 18 + x) {
                pixels.append((x, y))
            }
        }
        return pixels
    }
}

// MARK: - Selo de status

/// Bolinha no canto do mascote: ! aprovação, ? pergunta, ✓ terminou, ✕ erro.
struct AgentMascotBadge: View {
    let status: AgentSessionStatus
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String? {
        switch status {
        case .waitingApproval: "exclamationmark"
        case .waitingInput: "questionmark"
        case .done: "checkmark"
        case .error: "xmark"
        case .running, .idle: nil
        }
    }

    var body: some View {
        if let symbol {
            Circle()
                .fill(status.tint)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.55, weight: .heavy))
                        .foregroundStyle(.black)
                        .contentTransition(.symbolEffect(.replace))
                }
                .padding(size * 0.12)
                .background(Circle().fill(.black))
                .frame(width: size, height: size)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .waitingApproval && !reduceMotion)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }
}
