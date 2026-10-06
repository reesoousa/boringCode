//
//  AgentColors.swift
//  boringCode
//
//  Cores dos agentes e dos status das sessões (o desenho de cada agente
//  fica em AgentMascot).
//

import SwiftUI

extension AgentSessionStatus {
    var tint: Color {
        switch self {
        case .running: .claudeOrange  // por agente: AgentKind.tint
        case .waitingApproval: .yellow
        case .waitingInput: .effectiveAccent
        case .done: .green
        case .error: .red
        case .idle: .gray
        }
    }
}

extension Color {
    /// Laranja da marca Claude — usado só para "rodando".
    static let claudeOrange = Color(red: 0.851, green: 0.467, blue: 0.341)
    /// Azul do Codex (mesmo tom do Open Island).
    static let codexBlue = Color(red: 0.290, green: 0.639, blue: 0.875)
}

extension AgentKind {
    var tint: Color {
        switch self {
        case .claude: .claudeOrange
        case .codex: .codexBlue
        }
    }
}
