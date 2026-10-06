//
//  AgentActivity.swift
//  boringCode
//
//  O que o agente está fazendo, em linguagem de gente: cada ferramenta vira um
//  passo ("Lendo ContentView.swift", "Editando AgentModels.swift +12 −3",
//  "Rodando testes · npm test"). Ideia dos passos e do resumo final adaptada de
//  Coucou (github.com/Louis-CFM/coucou), MIT.
//

import Foundation

/// Tipo de ação — decide o verbo, o ícone e a pose do mascote.
enum AgentStepKind: String, Equatable {
    case thinking
    case reading
    case searching
    case editing
    case writing
    case running
    case testing
    case building
    case git
    case web
    case delegating
    case planning
    case asking
    case mcp
    case compacting
    case other

    /// Verbo no gerúndio, para o passo em andamento.
    var verb: String {
        switch self {
        case .thinking: String(localized: "Thinking", comment: "Agent step in progress")
        case .reading: String(localized: "Reading", comment: "Agent step in progress")
        case .searching: String(localized: "Searching", comment: "Agent step in progress")
        case .editing: String(localized: "Editing", comment: "Agent step in progress")
        case .writing: String(localized: "Creating", comment: "Agent step in progress: writing a new file")
        case .running: String(localized: "Running", comment: "Agent step in progress: shell command")
        case .testing: String(localized: "Testing", comment: "Agent step in progress")
        case .building: String(localized: "Building", comment: "Agent step in progress")
        case .git: String(localized: "Git", comment: "Agent step in progress")
        case .web: String(localized: "Browsing", comment: "Agent step in progress")
        case .delegating: String(localized: "Delegating", comment: "Agent step in progress: subagent")
        case .planning: String(localized: "Planning", comment: "Agent step in progress")
        case .asking: String(localized: "Asking", comment: "Agent step in progress")
        case .mcp: String(localized: "Using", comment: "Agent step in progress: MCP tool")
        case .compacting: String(localized: "Compacting context", comment: "Agent step in progress")
        case .other: String(localized: "Working", comment: "Agent step in progress")
        }
    }

    /// SF Symbol do passo.
    var symbol: String {
        switch self {
        case .thinking: "sparkle"
        case .reading: "doc.text"
        case .searching: "magnifyingglass"
        case .editing: "pencil"
        case .writing: "doc.badge.plus"
        case .running: "terminal"
        case .testing: "checkmark.seal"
        case .building: "hammer"
        case .git: "arrow.triangle.branch"
        case .web: "globe"
        case .delegating: "person.2"
        case .planning: "list.bullet"
        case .asking: "questionmark.bubble"
        case .mcp: "puzzlepiece.extension"
        case .compacting: "archivebox"
        case .other: "gearshape"
        }
    }

    /// Como o mascote se mexe enquanto isso acontece.
    var motion: AgentMascotMotion {
        switch self {
        case .reading, .searching, .web: .scanning
        case .editing, .writing, .planning: .typing
        case .thinking, .asking, .compacting: .thinking
        default: .walking
        }
    }
}

enum AgentStepState: Equatable {
    case running
    case done
    case failed
}

/// Um passo da sessão (uma chamada de ferramenta).
struct AgentStep: Identifiable, Equatable {
    let id: String
    let kind: AgentStepKind
    /// Alvo curto: arquivo, comando, padrão, domínio…
    let target: String?
    /// Nome bruto da ferramenta (fica no tooltip).
    let toolName: String
    /// O alvo é código (comando do shell) — vai em fonte mono.
    var targetIsCode = false
    var state: AgentStepState = .running
    /// Linhas adicionadas/removidas (Edit, MultiEdit, Write).
    var added: Int?
    var removed: Int?
    let startedAt: Date

    /// "Lendo ContentView.swift" — o alvo vai à parte para poder ter outra fonte.
    var title: String { kind.verb }
}

/// Lê `tool_name` + `tool_input` e traduz para um passo.
enum AgentStepParser {
    static func step(id: String, toolName: String, input: JSONValue?, at date: Date) -> AgentStep {
        let (kind, command) = classify(toolName: toolName, input: input)
        // O Bash do Claude Code vem com uma descrição curta ("Roda os testes de busca"):
        // é bem mais clara que o comando cru.
        let isShell = ["Bash", "shell", "exec_command", "local_shell"].contains(toolName)
        let description = isShell ? note(input) : nil
        var step = AgentStep(id: id, kind: kind, target: description ?? command, toolName: toolName,
                             targetIsCode: isShell && description == nil, startedAt: date)
        if let stats = diffStats(toolName: toolName, input: input) {
            step.added = stats.added
            step.removed = stats.removed
        }
        return step
    }

    static func classify(toolName: String, input: JSONValue?) -> (AgentStepKind, String?) {
        let file = (input?["file_path"] ?? input?["notebook_path"] ?? input?["path"]).map { ($0 as NSString).lastPathComponent }
        switch toolName {
        case "Read", "LS", "NotebookRead":
            return (.reading, file)
        case "Edit", "MultiEdit", "NotebookEdit", "apply_patch":
            return (.editing, file ?? patchFile(input?["command"] ?? input?["patch"]))
        case "Write":
            return (.writing, file)
        case "Grep", "Glob", "ToolSearch":
            return (.searching, (input?["pattern"] ?? input?["query"])?.singleLine.clipped(48))
        case "WebFetch":
            return (.web, input?["url"].flatMap { URL(string: $0)?.host } ?? input?["url"])
        case "WebSearch":
            return (.web, input?["query"]?.singleLine.clipped(48))
        case "Task", "Agent", "spawn_agent":
            return (.delegating, (input?["description"] ?? input?["subagent_type"])?.singleLine.clipped(48))
        case "TodoWrite", "TaskCreate", "TaskUpdate", "update_plan":
            return (.planning, nil)
        case "ExitPlanMode", "EnterPlanMode":
            return (.planning, nil)
        case "AskUserQuestion":
            return (.asking, nil)
        case "Bash", "shell", "exec_command", "local_shell", "BashOutput":
            guard let command = input?["command"]?.singleLine, !command.isEmpty else { return (.running, nil) }
            return (bashKind(command), command.clipped(80))
        default:
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.dropFirst(5).components(separatedBy: "__")
                let label = parts.count >= 2 ? "\(parts[0]) · \(parts.dropFirst().joined(separator: "__"))" : parts.joined()
                return (.mcp, label.replacingOccurrences(of: "_", with: " "))
            }
            return (.other, file ?? toolName)
        }
    }

    /// Descrição curta que o agente deu para a ação (`description` do Bash/Task).
    static func note(_ input: JSONValue?) -> String? {
        guard let text = input?["description"]?.singleLine, !text.isEmpty else { return nil }
        return text.clipped(80)
    }

    /// Classifica um comando do shell pelo que ele faz.
    static func bashKind(_ command: String) -> AgentStepKind {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        // "cd pasta && npm test" → olha o último trecho, que é o que importa.
        var last = trimmed.components(separatedBy: "&&").last?.trimmingCharacters(in: .whitespaces) ?? trimmed
        // Pula variáveis de ambiente na frente ("CI=1 npm test").
        while let match = last.range(of: #"^[A-Za-z_][A-Za-z0-9_]*=\S*\s+"#, options: .regularExpression) {
            last.removeSubrange(match)
        }
        let first = last.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let lower = last.lowercased()

        let tests = ["pytest", "vitest", "jest", "npm test", "npm run test", "pnpm test", "yarn test", "bun test",
                     "cargo test", "go test", "swift test", "make test", "xcodebuild test", "unittest", "rspec", "phpunit"]
        if tests.contains(where: { lower.contains($0) }) || (lower.hasPrefix("xcodebuild") && lower.hasSuffix(" test")) {
            return .testing
        }
        switch first {
        case "cat", "bat", "head", "tail", "less", "more", "nl", "sed", "awk", "jq", "open":
            return lower.hasPrefix("sed -i") ? .editing : .reading
        case "rg", "grep", "find", "fd", "ls", "tree", "wc", "which", "mdfind":
            return .searching
        case "git", "gh":
            return .git
        case "curl", "wget":
            return .web
        default:
            break
        }
        let builds = ["xcodebuild", "swift build", "npm run build", "pnpm build", "yarn build", "cargo build", "go build",
                      "make", "tsc", "vite build", "next build", "gradle", "mvn", "swiftc"]
        if builds.contains(where: { lower.hasPrefix($0) || lower.contains(" \($0)") }) { return .building }
        return .running
    }

    /// Codex manda o patch inteiro: o arquivo vem na linha "*** Update File: …".
    private static func patchFile(_ patch: String?) -> String? {
        guard let patch else { return nil }
        for line in patch.split(whereSeparator: \.isNewline) {
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(prefix) {
                return (String(line.dropFirst(prefix.count)) as NSString).lastPathComponent
            }
        }
        return nil
    }

    // MARK: - Diff

    /// +N −M de uma edição, pelo diff das linhas (Myers, do próprio Swift).
    static func diffStats(toolName: String, input: JSONValue?) -> (added: Int, removed: Int)? {
        guard let input else { return nil }
        switch toolName {
        case "Edit":
            return lineDiff(old: input["old_string"] ?? "", new: input["new_string"] ?? "")
        case "MultiEdit":
            guard case .object(let dict) = input, case .array(let edits)? = dict["edits"] else { return nil }
            var total = (added: 0, removed: 0)
            for edit in edits {
                guard let stats = lineDiff(old: edit["old_string"] ?? "", new: edit["new_string"] ?? "") else { continue }
                total.added += stats.added
                total.removed += stats.removed
            }
            return total.added + total.removed > 0 ? total : nil
        case "Write":
            guard let content = input["content"], !content.isEmpty else { return nil }
            return (lines(content).count, 0)
        case "apply_patch":
            guard let patch = input["command"] ?? input["patch"] else { return nil }
            var added = 0, removed = 0
            for line in patch.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
                if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
            }
            return added + removed > 0 ? (added, removed) : nil
        default:
            return nil
        }
    }

    static func lineDiff(old: String, new: String) -> (added: Int, removed: Int)? {
        guard !old.isEmpty || !new.isEmpty else { return nil }
        let oldLines = lines(old), newLines = lines(new)
        // Edição gigante: conta por diferença de tamanho em vez de calcular o diff.
        if oldLines.count * newLines.count > 1_000_000 {
            return (max(0, newLines.count - oldLines.count), max(0, oldLines.count - newLines.count))
        }
        var added = 0, removed = 0
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .insert: added += 1
            case .remove: removed += 1
            }
        }
        return added + removed > 0 ? (added, removed) : nil
    }

    private static func lines(_ text: String) -> [Substring] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false)
    }
}

// MARK: - Texto

extension String {
    /// Corta em `limit` caracteres com reticências.
    func clipped(_ limit: Int) -> String {
        count > limit ? String(prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : self
    }

    /// Primeiro parágrafo de um texto em Markdown, sem a marcação — o resumo do que o
    /// agente fez ("Migração aplicada, 14 testes passaram."). Ideia do `toOneLine` do Coucou.
    var agentSummary: String {
        var paragraph: [String] = []
        for raw in components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let isBreak = line.isEmpty || line.hasPrefix("|") || line.hasPrefix("```")
                || (line.count >= 3 && Set(line).isSubset(of: ["-", "*", "_"]))
            if isBreak {
                if !paragraph.isEmpty { break }
                continue
            }
            paragraph.append(line)
        }
        var text = paragraph.joined(separator: " ")
        for marker in ["**", "__", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        text = text.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^([-*•]|\d+\.)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces).clipped(220)
    }
}
