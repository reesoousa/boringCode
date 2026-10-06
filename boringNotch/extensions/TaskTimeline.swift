//
//  TaskTimeline.swift
//  boringCode
//
//  Como o TimelineView, mas acorda o app só no intervalo pedido. No macOS o TimelineView
//  (qualquer cronograma) segue o display link: acorda a cada quadro da tela (até 120 Hz)
//  e refaz o layout da janela do notch só para decidir que ainda não é hora.
//

import SwiftUI

struct TaskTimeline<Content: View>: View {
    /// Intervalo entre atualizações; nil = parado (mostra a hora de quando apareceu).
    let interval: TimeInterval?
    @ViewBuilder let content: (Date) -> Content

    @State private var now = Date()

    var body: some View {
        content(now)
            .task(id: interval) {
                now = Date()
                guard let interval else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
                    now = Date()
                }
            }
    }
}
