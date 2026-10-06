//
//  AgentSessionStore.swift
//  boringCode
//
//  Estado das sessões do Claude Code: recebe eventos dos hooks, deriva o
//  status de cada sessão e segura os pedidos de permissão até você responder.
//  Máquina de estados inspirada no reducer do Open Island
//  (github.com/Octane0411/open-vibe-island), GPL-3.0.
//

import AppKit
import Combine
import Defaults
import Foundation
import os

@MainActor
final class AgentSessionStore: ObservableObject {
    static let shared = AgentSessionStore()

    /// Mais recentes primeiro.
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var hookStates: [AgentKind: AgentHookInstaller.State] = [:]
    /// Muda a cada novo pedido de permissão — o notch observa para se expandir.
    @Published private(set) var expandRequest: UUID?
    /// Última vez que uma sessão terminou (Stop) — o indicador mostra um ✓ rápido.
    @Published private(set) var lastCompletion: Date?

    private let server = AgentHookServer()
    private var pendingConnections: [UUID: AgentHookConnection] = [:]
    private var housekeeping: Timer?
    private var enabledCancellable: AnyCancellable?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "boringcode", category: "AgentSessionStore")

    /// Por quanto tempo o ✓ de "concluído" (e o aviso com o resumo) fica no notch fechado.
    static let completionFlashDuration: TimeInterval = 6

    private init() {
        server.onRequest = { [weak self] request, connection in
            Task { @MainActor in self?.handle(request, connection: connection) }
        }
    }

    // MARK: - Ciclo de vida

    func start() {
        guard enabledCancellable == nil else { return }  // o onboarding pode ligar antes do fim
        enabledCancellable = Defaults.publisher(.agentsEnabled)
            .sink { [weak self] change in
                Task { @MainActor in self?.applyEnabled(change.newValue) }
            }
    }

    private func applyEnabled(_ enabled: Bool) {
        if enabled {
            server.start()
            installHooksIfNeeded()
            housekeeping?.invalidate()
            housekeeping = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    // Se outra instância segurava o socket e fechou, assume a escuta.
                    if self?.server.isRunning == false { self?.server.start() }
                    self?.pruneSessions()
                }
            }
        } else {
            housekeeping?.invalidate()
            housekeeping = nil
            resolveAllPending()
            server.stop()
            sessions = []
            refreshHookState()
            if BoringViewCoordinator.shared.currentView == .agents {
                BoringViewCoordinator.shared.currentView = .home
            }
        }
    }

    func hookState(for agent: AgentKind) -> AgentHookInstaller.State {
        hookStates[agent] ?? .notInstalled
    }

    /// Instala nos agentes presentes no Mac (e repara instalações incompletas).
    func installHooksIfNeeded() {
        do { try AgentHookInstaller.writeHookScript() } catch {
            log.error("falha ao escrever o script de hook: \(error.localizedDescription)")
        }
        for installer in AgentHookInstaller.all {
            switch installer.currentState() {
            case .notInstalled, .outdated:
                do { try installer.install() } catch {
                    log.error("falha ao instalar hooks (\(installer.agent.rawValue)): \(error.localizedDescription)")
                }
            default: break
            }
        }
        refreshHookState()
    }

    func reinstallHooks(for agent: AgentKind) {
        do { try AgentHookInstaller.installer(for: agent).install() } catch {
            log.error("falha ao reinstalar hooks: \(error.localizedDescription)")
        }
        refreshHookState()
    }

    func uninstallHooks(for agent: AgentKind) {
        do { try AgentHookInstaller.installer(for: agent).uninstall() } catch {
            log.error("falha ao remover hooks: \(error.localizedDescription)")
        }
        refreshHookState()
    }

    func refreshHookState() {
        var states: [AgentKind: AgentHookInstaller.State] = [:]
        for installer in AgentHookInstaller.all { states[installer.agent] = installer.currentState() }
        hookStates = states
    }

    // MARK: - Consultas para a UI

    var activeSessions: [AgentSession] { sessions.filter { $0.status.isActive } }

    /// Aprovações + perguntas esperando resposta no notch.
    var pendingApprovalCount: Int {
        sessions.reduce(0) { $0 + $1.pendingPermissions.count + ($1.pendingQuestion == nil ? 0 : 1) }
    }

    /// De qual agente é a sessão mais prioritária (cor do ✻ no notch fechado).
    var closedIndicatorAgent: AgentKind {
        activeSessions.max(by: { $0.status.priority < $1.status.priority })?.agent ?? sessions.first?.agent ?? .claude
    }

    /// Sessão que o notch fechado representa (a mais urgente; senão a mais recente).
    var closedIndicatorSession: AgentSession? {
        activeSessions.max(by: { $0.status.priority < $1.status.priority }) ?? sessions.first
    }

    /// Aviso que cresce por baixo do notch fechado quando algo importante acontece:
    /// pedido de aprovação, pergunta, fim do turno (com o resumo) ou erro.
    var closedPeek: AgentPeek? {
        if let session = sessions.first(where: \.needsAnswer) {
            if let permission = session.pendingPermission {
                return AgentPeek(
                    id: permission.id.uuidString, kind: .approval, sessionID: session.id, agent: session.agent,
                    title: permission.headline(agent: session.agent),
                    detail: permission.detail?.singleLine ?? permission.target ?? permission.summary
                )
            }
            if let question = session.pendingQuestion {
                return AgentPeek(
                    id: question.id.uuidString, kind: .question, sessionID: session.id, agent: session.agent,
                    title: String(localized: "\(session.agent.displayName) has a question", comment: "Agent question headline"),
                    detail: question.questions.first?.question.singleLine
                )
            }
        }
        guard let lastCompletion, Date().timeIntervalSince(lastCompletion) < Self.completionFlashDuration,
              let session = sessions.first(where: { ($0.status == .done || $0.status == .error) && $0.updatedAt >= lastCompletion })
        else { return nil }
        if session.status == .error {
            return AgentPeek(
                id: "error-\(session.id)-\(lastCompletion.timeIntervalSince1970)", kind: .error, sessionID: session.id,
                agent: session.agent,
                title: String(localized: "\(session.projectName) stopped", comment: "Agent session ended with an error"),
                detail: session.errorMessage
            )
        }
        return AgentPeek(
            id: "done-\(session.id)-\(lastCompletion.timeIntervalSince1970)", kind: .done, sessionID: session.id,
            agent: session.agent,
            title: String(localized: "\(session.projectName) is done", comment: "Agent finished its turn"),
            detail: session.lastMessage
        )
    }

    /// O que o indicador do notch fechado deve mostrar (nil = nada, volta o espectro).
    var closedIndicatorStatus: AgentSessionStatus? {
        if let top = activeSessions.max(by: { $0.status.priority < $1.status.priority }) {
            return top.status
        }
        if let lastCompletion, Date().timeIntervalSince(lastCompletion) < Self.completionFlashDuration {
            return sessions.contains { $0.status == .error && $0.updatedAt >= lastCompletion } ? .error : .done
        }
        return nil
    }

    // MARK: - Ações

    func approve(_ sessionID: String) { resolveFirstPermission(of: sessionID, allow: true) }

    func deny(_ sessionID: String) { resolveFirstPermission(of: sessionID, allow: false) }

    /// Permite e pede ao Claude Code para lembrar a regra (as sugestões do próprio pedido).
    func approveAlways(_ sessionID: String) { resolveFirstPermission(of: sessionID, allow: true, always: true) }

    /// "OK" no cartão de terminou/erro: a aba volta a mostrar os passos.
    func acknowledgeOutcome(_ sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].outcomeAcknowledged = true
    }

    /// Responde o AskUserQuestion: `answers` = texto da pergunta → rótulo(s) escolhido(s).
    func answer(_ sessionID: String, answers: [String: String]) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let question = sessions[index].pendingQuestion else { return }
        var input = (try? JSONSerialization.jsonObject(with: question.toolInput) as? [String: Any]) ?? [:]
        input["answers"] = answers
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow", "updatedInput": input],
            ]
        ]
        let body = try? JSONSerialization.data(withJSONObject: output)
        pendingConnections.removeValue(forKey: question.id)?.respond(body)
        sessions[index].pendingQuestion = nil
        sessions[index].status = .running
        sessions[index].activity = nil
        sessions[index].updatedAt = Date()
    }

    /// Solta a pergunta para o diálogo do próprio Claude e leva você até ele.
    func answerInTerminal(_ sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let question = sessions[index].pendingQuestion {
            pendingConnections.removeValue(forKey: question.id)?.respond(nil)
            sessions[index].pendingQuestion = nil
        }
        focus(sessions[index])
    }

    func focus(_ session: AgentSession) {
        AgentTerminalFocus.focus(session)
    }

    func dismiss(_ sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }), !session.status.isActive else { return }
        sessions.removeAll { $0.id == sessionID }
    }

    #if DEBUG
    /// Só para testes/capturas: troca as sessões sem passar pelos hooks.
    func replaceSessionsForPreview(_ sessions: [AgentSession], lastCompletion: Date? = nil) {
        self.sessions = sessions
        self.lastCompletion = lastCompletion
    }
    #endif

    // MARK: - Eventos

    private func handle(_ request: AgentHookConnection.Request, connection: AgentHookConnection) {
        guard Defaults[.agentsEnabled],
              let payload = try? JSONDecoder().decode(ClaudeHookPayload.self, from: request.body) else {
            connection.respond(nil)
            return
        }

        let agent = AgentKind(pathComponent: request.agent)
        // O app do Codex dispara hooks internos (ex.: gerar título) sem transcript — não são sessões.
        if agent == .codex, (payload.transcriptPath ?? "").isEmpty {
            connection.respond(nil)
            return
        }

        let now = Date()
        var session = sessions.first(where: { $0.id == payload.sessionID }) ?? AgentSession(
            id: payload.sessionID,
            agent: agent,
            cwd: payload.cwd ?? "",
            status: .idle,
            host: .unknown,
            startedAt: now,
            updatedAt: now
        )
        if let cwd = payload.cwd, !cwd.isEmpty { session.cwd = cwd }
        session.updatedAt = now
        applyContext(request.headers, to: &session)

        var holdConnection = false

        switch payload.hookEventName {
        case "SessionStart":
            session.status = .idle
            session.activity = nil
        case "UserPromptSubmit":
            session.status = .running
            session.lastPrompt = payload.prompt?.singleLine
            session.activity = nil
            session.errorMessage = nil
            session.steps = []
            session.lastMessage = nil
            session.turnStartedAt = now
            session.outcomeAcknowledged = false
        case "PreToolUse":
            if !session.pendingPermissions.isEmpty {
                session.status = .waitingApproval
            } else if session.pendingQuestion != nil {
                session.status = .waitingInput
            } else {
                session.status = .running
            }
            session.activity = payload.toolSummary
            if session.turnStartedAt == nil { session.turnStartedAt = now }
            finishSteps(of: &session, kind: .compacting)
            if let toolName = payload.toolName {
                let id = payload.toolUseID ?? UUID().uuidString
                if !session.steps.contains(where: { $0.id == id }) {
                    session.steps.append(AgentStepParser.step(id: id, toolName: toolName, input: payload.toolInput, at: now))
                    if session.steps.count > AgentSession.maxSteps {
                        session.steps.removeFirst(session.steps.count - AgentSession.maxSteps)
                    }
                }
            }
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            // A ferramenta rodou (ou foi negada): qualquer pedido pendente dela já foi decidido.
            dropPermissions(of: &session)
            session.status = .running
            markStep(of: &session, payload: payload, state: payload.hookEventName == "PostToolUse" ? .done : .failed)
        case "PermissionRequest":
            if payload.toolName == "AskUserQuestion",
               let toolInput = Self.rawToolInput(request.body),
               let question = AgentPendingQuestion(id: UUID(), toolInputJSON: toolInput, receivedAt: now) {
                // Pergunta respondível no notch; a conexão fica aberta até você responder.
                if let previous = session.pendingQuestion {
                    pendingConnections.removeValue(forKey: previous.id)?.respond(nil)
                }
                session.pendingQuestion = question
                session.status = .waitingInput
                session.activity = question.questions.first?.question.singleLine
                pendingConnections[question.id] = connection
                connection.onClientGone = { [weak self] in
                    Task { @MainActor in self?.questionAbandoned(question.id, sessionID: session.id) }
                }
                holdConnection = true
                if Defaults[.agentsExpandOnApproval] { expandRequest = question.id }
            } else if payload.toolName == "AskUserQuestion" {
                // Formato que não sabemos ler: fica com o diálogo do Claude.
                session.status = .waitingInput
                session.activity = String(localized: "Question for you")
            } else {
                let permission = Self.permissionRequest(payload: payload, body: request.body, agent: agent, at: now)
                session.pendingPermissions.append(permission)
                session.status = .waitingApproval
                pendingConnections[permission.id] = connection
                connection.onClientGone = { [weak self] in
                    // Respondido no terminal (ou Claude cancelou): tira do notch.
                    Task { @MainActor in self?.permissionAbandoned(permission.id, sessionID: session.id) }
                }
                holdConnection = true
                if Defaults[.agentsExpandOnApproval] { expandRequest = permission.id }
            }
        case "Notification":
            switch payload.notificationType {
            case "permission_prompt" where session.pendingPermissions.isEmpty:
                // Sem PermissionRequest (ex.: host que não dispara o hook) — só dá pra responder lá.
                session.status = .waitingInput
                session.activity = payload.message?.singleLine ?? String(localized: "Permission pending")
            case "elicitation_dialog", "agent_needs_input":
                session.status = .waitingInput
                session.activity = payload.message?.singleLine
            default:
                break
            }
        case "Stop":
            // Só avisa se algo estava de fato em andamento (não num Stop repetido).
            if session.status.isActive { AgentCompletionSound.play() }
            dropPermissions(of: &session)
            session.status = .done
            session.activity = nil
            session.subagents = 0
            finishSteps(of: &session)
            if let message = payload.lastAssistantMessage?.agentSummary, !message.isEmpty {
                session.lastMessage = message
            }
            session.outcomeAcknowledged = false
            lastCompletion = now
            scheduleIndicatorRefresh()
        case "StopFailure":
            dropPermissions(of: &session)
            session.status = .error
            session.errorMessage = (payload.error ?? payload.errorDetails ?? String(localized: "API request failed")).singleLine
            session.subagents = 0
            finishSteps(of: &session, as: .failed)
            session.outcomeAcknowledged = false
            lastCompletion = now
            scheduleIndicatorRefresh()
        case "SubagentStart":
            session.subagents += 1
        case "SubagentStop":
            session.subagents = max(0, session.subagents - 1)
        case "PreCompact":
            session.status = .running
            session.activity = String(localized: "Compacting context")
            session.steps.append(AgentStep(id: UUID().uuidString, kind: .compacting, target: nil, toolName: "PreCompact", startedAt: now))
        case "SessionEnd":
            dropPermissions(of: &session)
            sessions.removeAll { $0.id == session.id }
            connection.respond(nil)
            return
        default:
            break
        }

        upsert(session)
        if !holdConnection { connection.respond(nil) }
    }

    private func applyContext(_ headers: [String: String], to session: inout AgentSession) {
        if let tty = headers["x-bc-tty"], !tty.isEmpty { session.tty = tty }
        if let pid = headers["x-bc-pid"].flatMap(Int32.init) { session.agentPID = pid }
        let host = AgentHost.resolve(
            termProgram: headers["x-bc-term"],
            bundleID: headers["x-bc-bundle"],
            entrypoint: headers["x-bc-entrypoint"]
        )
        if host != .unknown { session.host = host }
    }

    private func upsert(_ session: AgentSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
    }

    // MARK: - Permissões

    private func resolveFirstPermission(of sessionID: String, allow: Bool, always: Bool = false) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let permission = sessions[index].pendingPermission else { return }
        var decision: [String: Any] = allow
            ? ["behavior": "allow"]
            : ["behavior": "deny", "message": "Denied by the user from the boringCode notch."]
        // O Codex recusa updatedPermissions: lá "sempre" vira um "permitir" simples.
        if allow, always, sessions[index].agent == .claude, let suggestions = permission.suggestions,
           let rules = try? JSONSerialization.jsonObject(with: suggestions) {
            decision["updatedPermissions"] = rules
        }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]
        ]
        let body = try? JSONSerialization.data(withJSONObject: output)
        pendingConnections.removeValue(forKey: permission.id)?.respond(body)

        sessions[index].pendingPermissions.removeFirst()
        sessions[index].status = sessions[index].pendingPermissions.isEmpty ? .running : .waitingApproval
        sessions[index].updatedAt = Date()
    }

    /// Monta o pedido de permissão com o que dá para mostrar no cartão.
    private static func permissionRequest(payload: ClaudeHookPayload, body: Data, agent: AgentKind, at date: Date) -> AgentPermissionRequest {
        let toolName = payload.toolName ?? "Tool"
        let (kind, target) = AgentStepParser.classify(toolName: toolName, input: payload.toolInput)
        let stats = AgentStepParser.diffStats(toolName: toolName, input: payload.toolInput)
        var detail: String?
        switch kind {
        case .planning:
            detail = payload.toolInput?["plan"]?.agentSummary
        case .web:
            detail = payload.toolInput?["url"] ?? payload.toolInput?["query"]
        case .editing, .writing, .reading:
            detail = nil
        default:
            if let command = payload.toolInput?["command"] {
                let lines = command.split(whereSeparator: \.isNewline).prefix(6)
                detail = lines.joined(separator: "\n").clipped(400)
            } else {
                detail = payload.toolDetail
            }
        }
        var suggestions: Data?
        if agent == .claude,
           let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let raw = object["permission_suggestions"] as? [Any], !raw.isEmpty {
            suggestions = try? JSONSerialization.data(withJSONObject: raw)
        }
        return AgentPermissionRequest(
            id: UUID(),
            toolName: toolName,
            summary: toolName == "ExitPlanMode" ? String(localized: "Plan ready for review") : payload.toolDetail ?? "",
            kind: kind,
            target: target,
            note: AgentStepParser.note(payload.toolInput),
            detail: detail,
            added: stats?.added,
            removed: stats?.removed,
            suggestions: suggestions,
            receivedAt: date
        )
    }

    // MARK: - Passos

    /// Fecha o passo da ferramenta que terminou (pelo `tool_use_id`; sem ele, o mais antigo da mesma ferramenta).
    private func markStep(of session: inout AgentSession, payload: ClaudeHookPayload, state: AgentStepState) {
        let index = payload.toolUseID.flatMap { id in session.steps.firstIndex(where: { $0.id == id }) }
            ?? session.steps.firstIndex(where: { $0.state == .running && $0.toolName == payload.toolName })
        guard let index else { return }
        session.steps[index].state = state
    }

    /// Fecha os passos ainda abertos (fim do turno; o Codex não manda PostToolUse).
    private func finishSteps(of session: inout AgentSession, kind: AgentStepKind? = nil, as state: AgentStepState = .done) {
        for index in session.steps.indices where session.steps[index].state == .running
            && (kind == nil || session.steps[index].kind == kind) {
            session.steps[index].state = state
        }
    }

    private func questionAbandoned(_ questionID: UUID, sessionID: String) {
        pendingConnections[questionID] = nil
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].pendingQuestion?.id == questionID else { return }
        sessions[index].pendingQuestion = nil
        if sessions[index].status == .waitingInput { sessions[index].status = .running }
    }

    /// `tool_input` cru do corpo do hook, para devolver intacto com as respostas.
    private static func rawToolInput(_ body: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let input = object["tool_input"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: input)
    }

    private func permissionAbandoned(_ permissionID: UUID, sessionID: String) {
        pendingConnections[permissionID] = nil
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].pendingPermissions.removeAll { $0.id == permissionID }
        if sessions[index].pendingPermissions.isEmpty, sessions[index].status == .waitingApproval {
            sessions[index].status = .running
        }
    }

    private func dropPermissions(of session: inout AgentSession) {
        for permission in session.pendingPermissions {
            pendingConnections.removeValue(forKey: permission.id)?.respond(nil)
        }
        session.pendingPermissions.removeAll()
        if let question = session.pendingQuestion {
            pendingConnections.removeValue(forKey: question.id)?.respond(nil)
            session.pendingQuestion = nil
        }
    }

    private func resolveAllPending() {
        pendingConnections.values.forEach { $0.respond(nil) }
        pendingConnections.removeAll()
    }

    // MARK: - Limpeza

    private func scheduleIndicatorRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionFlashDuration + 0.1) { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Tira sessões cujo processo morreu sem SessionEnd e concluídas antigas.
    private func pruneSessions() {
        let now = Date()
        let before = sessions.count
        sessions.removeAll { session in
            if let pid = session.agentPID, kill(pid, 0) != 0, errno == ESRCH {
                for permission in session.pendingPermissions {
                    pendingConnections.removeValue(forKey: permission.id)?.respond(nil)
                }
                if let question = session.pendingQuestion {
                    pendingConnections.removeValue(forKey: question.id)?.respond(nil)
                }
                return true
            }
            let age = now.timeIntervalSince(session.updatedAt)
            switch session.status {
            case .done, .error: return age > 30 * 60
            case .idle: return age > 2 * 60 * 60
            // Sem PID não dá pra saber se o processo morreu: desiste após 2h sem eventos.
            default: return session.agentPID == nil && !session.needsAnswer && age > 2 * 60 * 60
            }
        }
        if sessions.count != before { log.debug("removidas \(before - self.sessions.count) sessões") }

        // "Rodando" sem nenhum evento há 90s e sem processo para confirmar: provavelmente
        // parou sem avisar. Fica parado (sem animação) em vez de chamar atenção à toa.
        for index in sessions.indices where sessions[index].status == .running
            && sessions[index].agentPID == nil
            && now.timeIntervalSince(sessions[index].updatedAt) > 90 {
            sessions[index].status = .idle
            sessions[index].activity = nil
        }
    }
}
