//
//  AgentLiveActivity.swift
//  boringCode
//
//  Notch fechado quando há agente e nenhuma música: informação dos dois lados,
//  no padrão do Open Island (github.com/Octane0411/open-vibe-island, GPL-3.0) —
//  status geral à esquerda, um quadradinho por sessão à direita — com a
//  geometria do NotificationLiveActivity do Boring Notch.
//

import Defaults
import SwiftUI

struct AgentLiveActivity: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var store = AgentSessionStore.shared
    let status: AgentSessionStatus
    /// Mostrando um aviso por baixo: o notch se alarga para o texto caber.
    var peeking = false

    private var itemSize: CGFloat {
        max(0, vm.effectiveClosedNotchHeight - 12)
    }

    var body: some View {
        HStack {
            AgentClosedMascot(status: status, height: itemSize)
                .frame(width: Self.slotWidth(itemSize), height: itemSize)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top
                    + (peeking ? 2 * Self.peekExtraWidth : 0))

            AgentSessionCells(sessions: store.sessions, size: itemSize)
                .frame(width: Self.slotWidth(itemSize), height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .animation(.smooth(duration: 0.25), value: status)
    }

    /// Cada lado tem 1,5× a altura: o mascote é mais largo que alto.
    static func slotWidth(_ itemSize: CGFloat) -> CGFloat { (itemSize * 1.5).rounded() }

    /// Quanto o notch fechado cresce de cada lado enquanto mostra um aviso.
    static let peekExtraWidth: CGFloat = 56
}

/// Mascote do notch fechado — a pose já diz o estado (acenando = precisa de você).
struct AgentClosedMascot: View {
    @ObservedObject private var store = AgentSessionStore.shared
    let status: AgentSessionStatus
    let height: CGFloat

    var body: some View {
        let session = store.closedIndicatorSession
        AgentMascot(
            agent: session?.agent ?? store.closedIndicatorAgent,
            status: status,
            motion: session?.motionKind.motion ?? .idle,
            statusChangedAt: session?.statusChangedAt ?? .distantPast
        )
        .frame(height: height * 0.8)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: status)
    }
}

/// Lado direito do notch fechado com música tocando: entra no lugar do mini espectro.
struct AgentClosedIndicator: View {
    let status: AgentSessionStatus
    let size: CGFloat

    var body: some View {
        // Um pouco mais largo que o slot (o espectro também não ocupa o quadrado inteiro).
        AgentClosedMascot(status: status, height: size)
            .frame(width: size * 1.35, height: size)
            .frame(width: size, height: size)
    }
}

/// Um quadradinho por sessão, colorido pelo status (grade balanceada, até 9; depois "+N").
struct AgentSessionCells: View {
    let sessions: [AgentSession]
    let size: CGFloat

    @State private var pulse = false

    private var rows: [[AgentSession?]] {
        let visible = sessions.count > 9 ? Array(sessions.prefix(8)) : sessions
        var cells: [AgentSession?] = visible
        if sessions.count > 9 { cells.append(nil) } // célula "+N"
        let rowCount = cells.count <= 3 ? 1 : (cells.count <= 6 ? 2 : 3)
        let perRow = Int((Double(cells.count) / Double(rowCount)).rounded(.up))
        return stride(from: 0, to: cells.count, by: max(perRow, 1)).map {
            Array(cells[$0..<min($0 + perRow, cells.count)])
        }
    }

    private var cellSize: CGFloat { rows.count >= 3 ? size * 0.28 : size * 0.38 }
    private var gap: CGFloat { rows.count >= 3 ? 1.5 : 2 }

    var body: some View {
        VStack(spacing: gap) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(rows[row].indices, id: \.self) { column in
                        cell(rows[row][column])
                    }
                }
            }
        }
        .onAppear { pulse = true }
        .accessibilityElement()
        .accessibilityLabel(Text("\(sessions.count) agent sessions"))
    }

    @ViewBuilder
    private func cell(_ session: AgentSession?) -> some View {
        let shape = RoundedRectangle(cornerRadius: rows.count >= 3 ? 1 : 1.5, style: .continuous)
        if let session {
            let waiting = session.needsAnswer || session.status == .waitingInput
            shape
                .fill(session.status == .running ? session.agent.tint : session.status.cellTint)
                .frame(width: cellSize, height: cellSize)
                .opacity(waiting ? (pulse ? 1 : 0.35) : 1)
                .animation(waiting ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default, value: pulse)
        } else {
            shape
                .fill(Color.white.opacity(0.14))
                .frame(width: cellSize, height: cellSize)
        }
    }
}

private extension AgentSessionStatus {
    var cellTint: Color {
        switch self {
        case .idle: Color.white.opacity(0.22)
        default: tint
        }
    }
}
