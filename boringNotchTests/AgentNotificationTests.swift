//
//  AgentNotificationTests.swift
//  boringNotchTests
//
//  Notificações do sistema vindas de agentes de IA dão lugar ao cartão do notch.
//

import XCTest
@testable import boringNotch

final class AgentNotificationTests: XCTestCase {
    private func note(bundle: String?, app: String? = nil, title: String? = nil, body: String? = nil) -> SystemNotification {
        SystemNotification(id: UUID().uuidString, appName: app, bundleID: bundle, title: title, subtitle: nil, body: body, receivedAt: Date())
    }

    func testRecognizesAgentApps() {
        XCTAssertTrue(SystemNotificationManager.isFromAIAgent(note(bundle: "com.anthropic.claudefordesktop", title: "Claude needs your permission")))
        XCTAssertTrue(SystemNotificationManager.isFromAIAgent(note(bundle: "com.openai.codex", title: "Codex finished")))
        XCTAssertTrue(SystemNotificationManager.isFromAIAgent(note(bundle: nil, app: "Claude", title: "Ready")))
    }

    func testRecognizesAgentsInTerminals() {
        XCTAssertTrue(SystemNotificationManager.isFromAIAgent(note(bundle: "com.googlecode.iterm2", title: "Claude Code", body: "Claude needs your permission to use Bash")))
        XCTAssertFalse(SystemNotificationManager.isFromAIAgent(note(bundle: "com.googlecode.iterm2", title: "Build finished")))
    }

    func testIgnoresOtherAppsMentioningClaude() {
        // Alguém falando do Claude no Slack não é o agente pedindo nada.
        XCTAssertFalse(SystemNotificationManager.isFromAIAgent(note(bundle: "com.tinyspeck.slackmacgap", title: "Ana", body: "testei o Claude Code hoje")))
        XCTAssertFalse(SystemNotificationManager.isFromAIAgent(note(bundle: "com.openai.chat", title: "ChatGPT")))
    }
}
