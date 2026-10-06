//
//  AgentPulse.swift
//  boringCode
//
//  Pulso de opacidade e faixa de brilho feitos pelo Core Animation (no servidor de
//  renderização), não pelo SwiftUI. Uma animação `.repeatForever` do SwiftUI recalcula a janela
//  do notch a cada quadro da tela (até 120 Hz); esta não custa nada ao app.
//

import AppKit
import SwiftUI

extension View {
    /// Pulsa a opacidade (1 ↔ `minimum`) enquanto `active`. Parado com Reduzir movimento.
    func agentPulse(_ active: Bool, minimum: Float = 0.35, duration: CFTimeInterval = 0.7) -> some View {
        modifier(AgentPulseModifier(active: active, minimum: minimum, duration: duration))
    }
}

private struct AgentPulseModifier: ViewModifier {
    let active: Bool
    let minimum: Float
    let duration: CFTimeInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if active && !reduceMotion {
            // Um véu preto no formato do conteúdo vai e volta: no fundo preto do notch é o mesmo
            // que a opacidade cair, e a cor do conteúdo continua a dele.
            content
                .overlay { PulseLayerView(minimum: minimum, duration: duration).mask(content).allowsHitTesting(false) }
        } else {
            content
        }
    }
}

private struct PulseLayerView: NSViewRepresentable {
    let minimum: Float
    let duration: CFTimeInterval

    func makeNSView(context: Context) -> PulseHostView {
        PulseHostView(minimum: minimum, duration: duration)
    }

    func updateNSView(_ nsView: PulseHostView, context: Context) {}

    final class PulseHostView: NSView {
        private let minimum: Float
        private let duration: CFTimeInterval

        init(minimum: Float, duration: CFTimeInterval) {
            self.minimum = minimum
            self.duration = duration
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.opacity = 0
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let layer, layer.animation(forKey: "pulse") == nil else { return }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = 0
            animation.toValue = 1 - minimum
            animation.duration = duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: "pulse")
        }
    }
}

/// Faixa branca que atravessa a área da esquerda para a direita a cada 2,2 s (o brilho do
/// passo atual). Usar como `.overlay { AgentShimmerBand().mask(texto) }`.
struct AgentShimmerBand: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerHostView { ShimmerHostView() }
    func updateNSView(_ nsView: ShimmerHostView, context: Context) {}

    final class ShimmerHostView: NSView {
        private let gradient = CAGradientLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            gradient.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.cgColor,
                               NSColor.white.withAlphaComponent(0).cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.locations = [-0.6, -0.3, 0]
            layer?.addSublayer(gradient)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.frame = bounds
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, gradient.animation(forKey: "shimmer") == nil else { return }
            let animation = CABasicAnimation(keyPath: "locations")
            animation.fromValue = [-0.6, -0.3, 0]
            animation.toValue = [1, 1.3, 1.6]
            animation.duration = 2.2
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            gradient.add(animation, forKey: "shimmer")
        }
    }
}
