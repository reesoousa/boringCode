//
//  AgentsTabView.swift
//  boringCode
//
//  Aba "Agentes" do notch aberto. Um cartão grande com a sessão em foco (o
//  mascote à esquerda, os passos do turno à direita) e, havendo outras, uma
//  coluna com elas. Quando algo pede você, o cartão vira o pedido: aprovar um
//  comando, responder uma pergunta, ler o resumo do que o agente fez ou o erro.
//  Layout em cartão inspirado no Coucou (github.com/Louis-CFM/coucou), MIT.
//

import Defaults
import SwiftUI

struct AgentsTabView: View {
    @ObservedObject private var store = AgentSessionStore.shared

    /// Ordem fixa (a mais antiga em cima): as sessões não pulam de lugar enquanto trabalham.
    private var listedSessions: [AgentSession] {
        store.sessions.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
    }

    /// Quem aparece no cartão grande: um pedido esperando você; senão a escolhida na lista;
    /// senão a mais urgente/recente.
    private var focused: AgentSession? {
        if let waiting = store.sessions.first(where: \.needsAnswer) { return waiting }
        if let id = store.selectedSessionID, let selected = store.sessions.first(where: { $0.id == id }) {
            return selected
        }
        return store.sessions.max { lhs, rhs in
            lhs.status.priority == rhs.status.priority ? lhs.updatedAt < rhs.updatedAt : lhs.status.priority < rhs.status.priority
        }
    }

    var body: some View {
        Group {
            if let focused {
                let listed = listedSessions
                HStack(alignment: .top, spacing: 8) {
                    AgentFocusCard(session: focused)
                    if listed.count > 1 {
                        AgentSessionList(sessions: listed, focusedID: focused.id) { session in
                            withAnimation(.smooth(duration: 0.35)) { store.selectedSessionID = session.id }
                        }
                        .frame(width: 176)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: listed.count > 1)
                .animation(.smooth(duration: 0.35), value: focused.id)
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.smooth(duration: 0.3), value: store.sessions.isEmpty)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            AgentMascot(agent: .claude, status: nil)
                .frame(width: 54, height: 30)
                .padding(.bottom, 2)

            Text("No active agent sessions")
                .foregroundStyle(.gray)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.medium)

            if AgentKind.allCases.contains(where: { store.hookState(for: $0) == .installed }) {
                Text("Start Claude Code or Codex — in the terminal, VS Code or their apps.")
                    .font(.caption)
                    .foregroundStyle(.gray.opacity(0.8))
            } else if AgentKind.allCases.allSatisfy({ store.hookState(for: $0) == .agentNotFound }) {
                Text("Claude Code and Codex aren't installed on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.gray.opacity(0.8))
            } else {
                Button("Connect agents") { store.installHooksIfNeeded() }
                    .buttonStyle(AgentPillButtonStyle(prominent: false))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cartão da sessão em foco

private struct AgentFocusCard: View {
    let session: AgentSession
    @ObservedObject private var store = AgentSessionStore.shared

    enum Mode: Equatable {
        case steps
        case approval
        case question
        case done
        case error
    }

    private var mode: Mode {
        if session.pendingPermission != nil { return .approval }
        if session.pendingQuestion != nil { return .question }
        if session.status == .error, !session.outcomeAcknowledged { return .error }
        if session.status == .done, !session.outcomeAcknowledged, session.lastMessage != nil { return .done }
        return .steps
    }

    /// Brilho colorido que sobe da base do cartão, pela situação.
    private var wash: Color {
        switch mode {
        case .approval: AgentSessionStatus.waitingApproval.tint.opacity(0.32)
        case .question: AgentSessionStatus.waitingInput.tint.opacity(0.3)
        case .done: AgentSessionStatus.done.tint.opacity(0.26)
        case .error: AgentSessionStatus.error.tint.opacity(0.32)
        case .steps: session.status == .running ? session.agent.tint.opacity(0.14) : .clear
        }
    }

    private var subtitle: String {
        switch mode {
        case .approval: session.pendingPermission?.headline(agent: session.agent) ?? ""
        case .question: String(localized: "\(session.agent.displayName) has a question", comment: "Agent question headline")
        case .done: String(localized: "\(session.agent.displayName) finished", comment: "Agent finished its turn")
        case .error: String(localized: "Stopped with an error", comment: "Agent turn failed")
        case .steps: session.hostLabel
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            mascot
            VStack(alignment: .leading, spacing: 7) {
                header
                content
                    .id(mode)
                    .transition(.blurReplace.combined(with: .opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(.smooth(duration: 0.35), value: mode)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            Button("Go to \(session.host.displayName)") { store.focus(session) }
            if !session.status.isActive {
                Button("Remove from list") { store.dismiss(session.id) }
            }
        }
        .id(session.id)
        .transition(.blurReplace)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RadialGradient(
                    colors: [wash, .clear],
                    center: UnitPoint(x: 0.5, y: 1.35),
                    startRadius: 0,
                    endRadius: 300
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.smooth(duration: 0.5), value: mode)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
            )
    }

    private var mascot: some View {
        AgentMascot(
            agent: session.agent,
            status: session.status,
            motion: session.motionKind.motion,
            statusChangedAt: session.statusChangedAt,
            seed: Double(abs(session.id.hashValue % 97))
        )
        .frame(width: 63, height: 35)
        .overlay(alignment: .topLeading) {
            AgentMascotBadge(status: session.status, size: 17)
                .offset(x: -8, y: -12)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.65), value: session.status)
        .frame(width: 66)
        .onTapGesture { store.focus(session) }
        .help(Text("Go to \(session.host.displayName)"))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(session.projectName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .contentTransition(.opacity)
            if session.subagents > 0 {
                Label("\(session.subagents)", systemImage: "person.2.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.gray)
                    .fixedSize()
                    .help(Text("Subagents running"))
            }
            Spacer(minLength: 6)
            trailingInfo
            // Nos cartões de pedido os botões já levam ao terminal; aqui só nos passos.
            if mode == .steps {
                AgentIconButton(symbol: "arrow.up.forward", help: Text("Go to \(session.host.displayName)")) {
                    store.focus(session)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var trailingInfo: some View {
        if mode == .approval, session.pendingPermissions.count > 1 {
            Text("\(session.pendingPermissions.count - 1) more")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.gray)
                .fixedSize()
        } else if session.status == .running, let start = session.turnStartedAt {
            Text(start, style: .timer)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.gray)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .steps:
            AgentStepsView(session: session)
        case .approval:
            if let permission = session.pendingPermission {
                AgentApprovalContent(session: session, permission: permission)
            }
        case .question:
            if let question = session.pendingQuestion {
                AgentQuestionCard(sessionID: session.id, pending: question, embedded: true)
            }
        case .done:
            outcome(
                text: session.lastMessage ?? "",
                color: .white,
                weight: .medium
            )
        case .error:
            outcome(
                text: session.errorMessage ?? String(localized: "API request failed"),
                color: Color(red: 1, green: 0.58, blue: 0.6),
                weight: .regular
            )
        }
    }

    private func outcome(text: String, color: Color, weight: Font.Weight) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 13, weight: weight))
                .foregroundStyle(color)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Open \(session.host.displayName)") { store.focus(session) }
                    .buttonStyle(AgentPillButtonStyle(prominent: true))
                Button("OK") {
                    withAnimation(.smooth(duration: 0.35)) { store.acknowledgeOutcome(session.id) }
                }
                .buttonStyle(AgentPillButtonStyle(prominent: false))
            }
        }
    }
}

// MARK: - Passos

/// Os últimos passos do turno: o atual brilhando, os anteriores esmaecendo para cima.
private struct AgentStepsView: View {
    let session: AgentSession

    private struct Row: Identifiable, Equatable {
        let id: String
        let symbol: String
        let verb: String
        let target: String?
        let monospaced: Bool
        let state: AgentStepState
        let added: Int?
        let removed: Int?
        let help: String
    }

    private var rows: [Row] {
        var rows = session.steps.suffix(3).map { step in
            Row(
                id: step.id,
                symbol: step.kind.symbol,
                verb: step.kind.verb,
                target: step.target,
                monospaced: step.targetIsCode,
                state: step.state,
                added: step.added,
                removed: step.removed,
                help: step.toolName
            )
        }
        // Entre uma ferramenta e outra o agente está pensando: mostra isso em vez de nada.
        if session.status == .running, session.currentStep == nil {
            rows.append(Row(id: "thinking-\(session.steps.count)", symbol: AgentStepKind.thinking.symbol,
                            verb: AgentStepKind.thinking.verb, target: nil, monospaced: false,
                            state: .running, added: nil, removed: nil, help: ""))
            if rows.count > 3 { rows.removeFirst() }
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let prompt = session.lastPrompt, !prompt.isEmpty {
                Text("“\(prompt)”")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.bottom, 1)
            }
            if rows.isEmpty {
                Text(session.status == .done ? AgentSessionStatus.done.label : String(localized: "Waiting for your next prompt"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.gray)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        AgentStepRow(row: .init(
                            symbol: row.symbol, verb: row.verb, target: row.target, monospaced: row.monospaced,
                            state: row.state, added: row.added, removed: row.removed,
                            isCurrent: row.id == rows.last?.id && row.state == .running
                        ))
                        .help(row.help)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                    }
                }
                .animation(.smooth(duration: 0.4), value: rows)
            }
        }
        .clipped()
    }
}

private struct AgentStepRow: View {
    struct Model: Equatable {
        let symbol: String
        let verb: String
        let target: String?
        let monospaced: Bool
        let state: AgentStepState
        let added: Int?
        let removed: Int?
        let isCurrent: Bool
    }

    let row: Model

    private var icon: String {
        switch row.state {
        case .running: row.symbol
        case .done: "checkmark"
        case .failed: "xmark"
        }
    }

    private var iconColor: Color {
        switch row.state {
        case .running: .white
        case .done: .gray
        case .failed: AgentSessionStatus.error.tint
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: row.state == .running ? 10.5 : 9, weight: .semibold))
                .foregroundStyle(iconColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: row.isCurrent)
                .frame(width: 14)
            AgentShimmerText(text: row.verb, active: row.isCurrent)
                .font(.system(size: 12.5, weight: .medium))
                .fixedSize()
            if let target = row.target {
                Text(target)
                    .font(.system(size: 12, design: row.monospaced ? .monospaced : .default))
                    .foregroundStyle(row.isCurrent ? Color.white.opacity(0.75) : .gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let added = row.added, added > 0 {
                Text("+\(added)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.29, green: 0.85, blue: 0.47))
                    .fixedSize()
            }
            if let removed = row.removed, removed > 0 {
                Text("−\(removed)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.96, green: 0.38, blue: 0.43))
                    .fixedSize()
            }
        }
        .opacity(row.isCurrent ? 1 : (row.state == .failed ? 0.8 : 0.55))
        .frame(height: 17)
    }
}

/// Texto do passo atual com um brilho passando, como o "pensando" do Claude.
struct AgentShimmerText: View {
    let text: String
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                let period = 2.2
                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let center = -0.3 + 1.6 * phase
                Text(text)
                    .foregroundStyle(LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.6), location: center - 0.3),
                            .init(color: .white, location: center),
                            .init(color: .white.opacity(0.6), location: center + 0.3),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
            }
        } else {
            Text(text).foregroundStyle(active ? .white : .gray)
        }
    }
}

// MARK: - Aprovação

private struct AgentApprovalContent: View {
    let session: AgentSession
    let permission: AgentPermissionRequest
    @ObservedObject private var store = AgentSessionStore.shared
    /// Os botões só valem um instante depois que o pedido aparece: um clique que já
    /// vinha para outra coisa não aprova um pedido que acabou de trocar.
    @State private var armed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = permission.note, permission.kind != .planning {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .lineLimit(1)
                    .padding(.top, -1)
            }
            detailBox
            HStack(spacing: 8) {
                if permission.kind == .planning {
                    Button("Keep planning") { store.deny(session.id, permissionID: permission.id) }
                        .buttonStyle(AgentPillButtonStyle(prominent: false))
                    Button("Approve plan") { store.approve(session.id, permissionID: permission.id) }
                        .buttonStyle(AgentPillButtonStyle(prominent: true))
                } else {
                    Button("Deny") { store.deny(session.id, permissionID: permission.id) }
                        .buttonStyle(AgentPillButtonStyle(prominent: false))
                    if permission.canAlwaysAllow {
                        Button("Always allow") { store.approveAlways(session.id, permissionID: permission.id) }
                            .buttonStyle(AgentPillButtonStyle(prominent: false))
                            .help(Text("Allow now and save the rule: \(permission.alwaysAllowRules.joined(separator: ", "))"))
                    }
                    Button("Allow") { store.approve(session.id, permissionID: permission.id) }
                        .buttonStyle(AgentPillButtonStyle(prominent: true))
                }
            }
            .disabled(!armed)
        }
        .task(id: permission.id) {
            armed = false
            try? await Task.sleep(for: .milliseconds(450))
            armed = true
        }
    }

    /// O texto passa de duas linhas na caixa (estimativa pelo tamanho).
    private var overflows: Bool {
        guard let detail = permission.detail else { return false }
        return detail.filter(\.isNewline).count >= 2 || detail.count > 90
    }

    @ViewBuilder
    private var detailBox: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Group {
            if let detail = permission.detail, !detail.isEmpty {
                // O comando aparece inteiro (rolando se for grande): nada fica escondido do que você aprova.
                ScrollView(.vertical) {
                    Text(detail)
                        .font(.system(size: 12, design: permission.kind == .planning ? .default : .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .scrollIndicators(.visible)
                .frame(maxHeight: 31)
                .fixedSize(horizontal: false, vertical: true)
                // Comando maior que duas linhas: esmaece embaixo para mostrar que continua (rola).
                .mask(
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: overflows ? 0.6 : 1),
                                .init(color: .black.opacity(overflows ? 0.25 : 1), location: 1)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .help(detail)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: permission.kind.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.gray)
                    Text(permission.target ?? permission.toolName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .help(permission.target ?? permission.toolName)
                    if let added = permission.added, added > 0 {
                        Text("+\(added)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 0.29, green: 0.85, blue: 0.47))
                    }
                    if let removed = permission.removed, removed > 0 {
                        Text("−\(removed)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 0.96, green: 0.38, blue: 0.43))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(shape.fill(Color.white.opacity(0.07)))
        .overlay(shape.strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
        .help(permission.toolName)
    }
}

// MARK: - Outras sessões

private struct AgentSessionList: View {
    let sessions: [AgentSession]
    let focusedID: String
    let onSelect: (AgentSession) -> Void
    @Namespace private var selection

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                ForEach(sessions) { session in
                    AgentSessionPill(session: session, isFocused: session.id == focusedID, selection: selection) {
                        onSelect(session)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.35), value: sessions.map(\.id))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: focusedID)
        }
        .scrollIndicators(.never)
    }
}

private struct AgentSessionPill: View {
    let session: AgentSession
    /// É a que está no cartão grande: fica destacada.
    let isFocused: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @ObservedObject private var store = AgentSessionStore.shared
    @State private var isHovering = false

    private var line: String {
        if session.needsAnswer { return String(localized: "Needs you", comment: "Agent session waiting for the user") }
        if session.status == .running, let step = session.currentStep {
            // Com a descrição do agente ("Roda os testes"), ela já diz tudo.
            if AgentStepParser.shellTools.contains(step.toolName), !step.targetIsCode, let target = step.target {
                return target
            }
            return [step.kind.verb, step.target].compactMap { $0 }.joined(separator: " ")
        }
        if session.status == .running { return AgentStepKind.thinking.verb }
        return session.status.label
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AgentMascot(
                    agent: session.agent,
                    status: session.status,
                    motion: session.motionKind.motion,
                    statusChangedAt: session.statusChangedAt,
                    seed: Double(abs(session.id.hashValue % 89))
                )
                .frame(width: 27, height: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(line)
                        .font(.system(size: 10))
                        .foregroundStyle(session.needsAnswer ? session.status.tint : .gray)
                        .contentTransition(.opacity)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if session.needsAnswer || session.status == .error {
                    Circle()
                        .fill(session.status.tint)
                        .frame(width: 6, height: 6)
                        .phaseAnimator([1.0, 0.35]) { dot, phase in
                            dot.opacity(session.status == .error ? 1 : phase)
                        } animation: { _ in .easeInOut(duration: 0.7) }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.09 : 0.04))
            )
            .background {
                // Destaque desliza até a sessão escolhida.
                if isFocused {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "focused", in: selection)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(AgentPressStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.2)) { isHovering = hovering }
        }
        .animation(.smooth(duration: 0.3), value: line)
        .contextMenu {
            Button("Go to \(session.host.displayName)") { store.focus(session) }
            if !session.status.isActive {
                Button("Remove from list") { store.dismiss(session.id) }
            }
        }
    }
}

// MARK: - Botões

/// Botão em cápsula do notch: branco (principal) ou translúcido.
struct AgentPillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .foregroundStyle(prominent ? .black : .white)
                .background(
                    Capsule().fill(prominent
                        ? Color.white.opacity(isHovering ? 0.88 : 1)
                        : Color.white.opacity(isHovering ? 0.16 : 0.1))
                )
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
                .onHover { hovering in
                    withAnimation(.smooth(duration: 0.15)) { isHovering = hovering }
                }
                .fixedSize()
        }
    }
}

/// Aperto sutil para áreas clicáveis grandes.
struct AgentPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Botão redondo pequeno só com ícone (ir para o terminal).
private struct AgentIconButton: View {
    let symbol: String
    let help: Text
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.7))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(isHovering ? 0.16 : 0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(AgentPressStyle())
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.15)) { isHovering = hovering }
        }
        .help(help)
    }
}
