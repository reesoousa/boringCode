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
//  terminar. Parado (Reduzir movimento), fica na pose do estado. A animação roda no
//  Core Animation (AgentMascotLayer): custo zero para o app enquanto o mascote anda.
//

import AppKit
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

    static let columns: CGFloat = 18
    static let rows: CGFloat = 5
    /// Altura do pixel em relação à largura (pixel de terminal).
    static let pixelAspect: CGFloat = 2
    static let aspectRatio = columns / (rows * pixelAspect)

    var body: some View {
        AgentMascotLayer(config: .init(
            agent: agent,
            status: status,
            motion: status == .running ? motion : .idle,
            statusChangedAt: statusChangedAt,
            seed: seed,
            animated: !reduceMotion
        ))
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Animação no Core Animation

/// O mascote vive numa camada do Core Animation: os quadros de cada estado são desenhados uma
/// vez (imagens de 18×10 px) e o servidor de renderização os troca sozinho, com os deslocamentos
/// (passinho, respiração, pulinho) interpolados na taxa da tela. O app não trabalha enquanto o
/// mascote anda — antes, cada quadro redesenhava a janela do notch (≈3% de CPU num M4 Pro).
private struct AgentMascotLayer: NSViewRepresentable {
    struct Config: Equatable {
        let agent: AgentKind
        let status: AgentSessionStatus?
        let motion: AgentMascotMotion
        let statusChangedAt: Date
        let seed: Double
        let animated: Bool
    }

    let config: Config

    func makeNSView(context: Context) -> MascotView { MascotView() }

    func updateNSView(_ view: MascotView, context: Context) { view.configure(config) }

    final class MascotView: NSView {
        private let sprite = CALayer()
        private var config: Config?
        private var builtSize: CGSize = .zero

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            sprite.magnificationFilter = .nearest
            sprite.minificationFilter = .nearest
            sprite.contentsGravity = .resize
            sprite.anchorPoint = CGPoint(x: 0.5, y: 0)  // respira a partir dos pés
            layer?.addSublayer(sprite)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

        func configure(_ new: Config) {
            guard new != config else { return }
            let statusChanged = config != nil && config?.status != new.status
            config = new
            rebuild(intro: statusChanged)
        }

        override func layout() {
            super.layout()
            guard bounds.size != builtSize else { return }
            rebuild(intro: false)
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            builtSize = .zero
            needsLayout = true
        }

        /// Pixel inteiro na tela (sem borrão), centralizado no espaço disponível.
        private func spriteFrame() -> (frame: CGRect, unit: CGFloat) {
            let scale = window?.backingScaleFactor ?? 2
            let raw = min(bounds.width / AgentMascot.columns, bounds.height / (AgentMascot.rows * AgentMascot.pixelAspect))
            let u = max(1 / scale, (raw * scale).rounded(.down) / scale)
            let size = CGSize(width: u * AgentMascot.columns, height: u * AgentMascot.rows * AgentMascot.pixelAspect)
            let x = ((bounds.width - size.width) / 2 * scale).rounded() / scale
            let y = ((bounds.height - size.height) / 2 * scale).rounded() / scale
            return (CGRect(origin: CGPoint(x: x, y: y), size: size), u)
        }

        private func rebuild(intro: Bool) {
            guard let config, bounds.width > 0, bounds.height > 0 else { return }
            builtSize = bounds.size
            let (frame, unit) = spriteFrame()

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.removeAllAnimations()
            sprite.bounds = CGRect(origin: .zero, size: frame.size)
            sprite.position = CGPoint(x: frame.midX, y: frame.minY)
            sprite.transform = CATransform3DIdentity

            let tint = NSColor(config.agent.tint)
            // Reduzir movimento: só a pose do estado, parada.
            guard config.animated else {
                let pose = AgentMascotPose.make(agent: config.agent, status: config.status, motion: config.motion, time: 0, sinceChange: 10)
                sprite.contents = AgentMascotFrames.image(pose.pixels, tint: tint)
                CATransaction.commit()
                return
            }

            let now = Date()
            let sinceChange = now.timeIntervalSince(config.statusChangedAt)
            let introLength = 0.9
            var loopBegin: CFTimeInterval = 0

            // Pulinho/tremor logo depois de mudar de estado: uma passada única antes do ciclo.
            if intro || sinceChange < introLength {
                let start = max(0, sinceChange)
                if start < introLength {
                    let samples = AgentMascotFrames.samples(config, unit: unit, from: start, to: introLength, absolute: false, tint: tint)
                    add(samples, duration: introLength - start, repeats: false, beginTime: 0)
                    loopBegin = introLength - start
                }
            }

            let length = AgentMascotFrames.loopLength(config)
            let samples = AgentMascotFrames.samples(config, unit: unit, from: 0, to: length, absolute: true, tint: tint)
            sprite.contents = samples.images.first
            add(samples, duration: length, repeats: true, beginTime: loopBegin)
            CATransaction.commit()
        }

        private func add(_ samples: AgentMascotFrames.Samples, duration: Double, repeats: Bool, beginTime: CFTimeInterval) {
            let begin = beginTime > 0 ? sprite.convertTime(CACurrentMediaTime(), from: nil) + beginTime : 0
            let suffix = repeats ? "loop" : "intro"

            let contents = CAKeyframeAnimation(keyPath: "contents")
            contents.values = samples.images
            contents.keyTimes = samples.keyTimes as [NSNumber]
            contents.calculationMode = .discrete
            contents.duration = duration

            let transform = CAKeyframeAnimation(keyPath: "transform")
            transform.values = samples.transforms.map { NSValue(caTransform3D: $0) }
            transform.keyTimes = samples.transformTimes as [NSNumber]
            transform.calculationMode = .linear
            transform.duration = duration

            for animation in [contents, transform] {
                animation.repeatCount = repeats ? .infinity : 1
                animation.beginTime = begin
                animation.isRemovedOnCompletion = !repeats
                animation.fillMode = repeats ? .removed : .forwards
                sprite.add(animation, forKey: "\(animation.keyPath ?? "")-\(suffix)")
            }
        }
    }
}

/// Quadros pré-desenhados do mascote.
private enum AgentMascotFrames {
    struct Samples {
        var images: [CGImage] = []
        var keyTimes: [Double] = []
        var transforms: [CATransform3D] = []
        var transformTimes: [Double] = []
    }

    /// Duração do ciclo de cada estado (cobre os passos e pelo menos uma piscada).
    static func loopLength(_ config: AgentMascotLayer.Config) -> Double {
        switch config.status {
        case .running?:
            switch config.motion {
            case .walking: 4.2      // 7 passos de 0,6 s
            case .typing: 4.08      // 12 batidas de 0,34 s
            case .scanning: 5.4     // 3 varridas de 1,8 s
            case .thinking, .idle: 6.4
            }
        case .waitingApproval?: 3.8  // 5 acenos de 0,76 s
        case .waitingInput?: 10
        default: 8.6                 // duas piscadas de 4,3 s; olhadinha para os lados no meio
        }
    }

    /// Amostra o ciclo: imagens só quando a pose muda; deslocamento a 30 por segundo
    /// (o Core Animation interpola entre eles na taxa da tela).
    static func samples(_ config: AgentMascotLayer.Config, unit: CGFloat, from start: Double, to end: Double,
                        absolute: Bool, tint: NSColor) -> Samples {
        var result = Samples()
        var lastKey: [Int] = []
        let length = end - start
        let step = 1.0 / 30
        var t = start
        while t <= end + 0.0001 {
            let time = absolute ? t + config.seed : 10_000 + config.seed + t
            let sinceChange = absolute ? 10 : t
            let pose = AgentMascotPose.make(agent: config.agent, status: config.status, motion: config.motion,
                                            time: time, sinceChange: sinceChange)
            let progress = length > 0 ? min(1, (t - start) / length) : 0
            let key = pose.pixels.map { $0.y * 32 + $0.x }
            if key != lastKey, t < end - 0.0001 || result.images.isEmpty {
                result.images.append(image(pose.pixels, tint: tint))
                result.keyTimes.append(progress)
                lastKey = key
            }
            // Pose diz "para cima" com dy negativo (tela); a camada tem y para cima.
            var transform = CATransform3DMakeTranslation(pose.dx * unit, -pose.dy * unit * AgentMascot.pixelAspect, 0)
            transform = CATransform3DScale(transform, 1, pose.breath, 1)
            result.transforms.append(transform)
            result.transformTimes.append(progress)
            t += step
        }
        if result.keyTimes.last.map({ $0 < 1 }) ?? true, let last = result.images.last {
            // keyTimes de "discrete" precisam terminar em 1.
            result.images.append(last)
            result.keyTimes.append(1)
        }
        return result
    }

    private static let cache = NSCache<NSString, CGImage>()

    /// A pose como imagem de 18×10 px (cada pixel da grade = 1×2 px), na cor do agente.
    static func image(_ pixels: [(x: Int, y: Int)], tint: NSColor) -> CGImage {
        let rgb = tint.usingColorSpace(.sRGB) ?? tint
        let key = "\(rgb.redComponent),\(rgb.greenComponent),\(rgb.blueComponent):"
            + pixels.map { "\($0.x).\($0.y)" }.joined(separator: ",") as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let width = Int(AgentMascot.columns), height = Int(AgentMascot.rows * AgentMascot.pixelAspect)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(rgb.cgColor)
        let rowHeight = Int(AgentMascot.pixelAspect)
        for pixel in pixels {
            // CGContext tem origem embaixo; a grade é de cima para baixo.
            context.fill(CGRect(x: pixel.x, y: height - (pixel.y + 1) * rowHeight, width: 1, height: rowHeight))
        }
        let image = context.makeImage()!
        cache.setObject(image, forKey: key)
        return image
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
                .agentPulse(status == .waitingApproval, minimum: 0.55, duration: 0.8)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        }
    }
}
