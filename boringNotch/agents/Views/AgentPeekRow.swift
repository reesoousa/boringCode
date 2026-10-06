//
//  AgentPeekRow.swift
//  boringCode
//
//  Linha que cresce por baixo do notch fechado quando algo importante acontece
//  com um agente: pedido de aprovação, pergunta, fim do turno (com o resumo do
//  que ele fez) ou erro. Clique abre a aba Agentes.
//

import SwiftUI

struct AgentPeekRow: View {
    let peek: AgentPeek

    private var symbol: String {
        switch peek.kind {
        case .approval: "exclamationmark.circle.fill"
        case .question: "questionmark.circle.fill"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch peek.kind {
        case .approval: AgentSessionStatus.waitingApproval.tint
        case .question: AgentSessionStatus.waitingInput.tint
        case .done: AgentSessionStatus.done.tint
        case .error: AgentSessionStatus.error.tint
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: peek.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(peek.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                if let detail = peek.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11, design: peek.kind == .approval ? .monospaced : .default))
                        .foregroundStyle(.gray)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, -4)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
