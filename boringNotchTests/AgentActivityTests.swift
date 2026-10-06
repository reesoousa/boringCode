//
//  AgentActivityTests.swift
//  boringNotchTests
//
//  Tradução das ferramentas dos agentes em passos legíveis e resumo final.
//

import XCTest
@testable import boringNotch

final class AgentActivityTests: XCTestCase {
    private func json(_ object: [String: Any]) -> JSONValue {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testClassifiesTools() {
        XCTAssertEqual(AgentStepParser.classify(toolName: "Read", input: json(["file_path": "/a/b/ContentView.swift"])).1, "ContentView.swift")
        XCTAssertEqual(AgentStepParser.classify(toolName: "Grep", input: json(["pattern": "foo"])).0, .searching)
        XCTAssertEqual(AgentStepParser.classify(toolName: "WebFetch", input: json(["url": "https://docs.swift.org/x"])).1, "docs.swift.org")
        let mcp = AgentStepParser.classify(toolName: "mcp__github__create_issue", input: nil)
        XCTAssertEqual(mcp.0, .mcp)
        XCTAssertEqual(mcp.1, "github · create issue")
        XCTAssertEqual(AgentStepParser.classify(toolName: "apply_patch", input: json(["command": "*** Begin Patch\n*** Update File: src/app.ts\n+x"])).1, "app.ts")
    }

    func testBashKinds() {
        XCTAssertEqual(AgentStepParser.bashKind("npm test"), .testing)
        XCTAssertEqual(AgentStepParser.bashKind("cd web && pnpm test -- --watch=false"), .testing)
        XCTAssertEqual(AgentStepParser.bashKind("xcodebuild -scheme App build"), .building)
        XCTAssertEqual(AgentStepParser.bashKind("git status"), .git)
        XCTAssertEqual(AgentStepParser.bashKind("rg pending"), .searching)
        XCTAssertEqual(AgentStepParser.bashKind("cat README.md"), .reading)
        XCTAssertEqual(AgentStepParser.bashKind("sed -i '' s/a/b/ x"), .editing)
        XCTAssertEqual(AgentStepParser.bashKind("python3 script.py"), .running)
        XCTAssertEqual(AgentStepParser.bashKind("CI=1 FOO=bar npm test"), .testing)
    }

    func testShellStepPrefersDescription() {
        let described = AgentStepParser.step(id: "1", toolName: "Bash", input: json(["command": "npm test -- search", "description": "Roda os testes de busca"]), at: Date())
        XCTAssertEqual(described.kind, .testing)
        XCTAssertEqual(described.target, "Roda os testes de busca")
        XCTAssertFalse(described.targetIsCode)
        let raw = AgentStepParser.step(id: "2", toolName: "Bash", input: json(["command": "ls -la"]), at: Date())
        XCTAssertEqual(raw.target, "ls -la")
        XCTAssertTrue(raw.targetIsCode)
    }

    func testDiffStats() {
        let edit = AgentStepParser.diffStats(toolName: "Edit", input: json(["old_string": "a\nb\nc", "new_string": "a\nB\nc\nd"]))
        XCTAssertEqual(edit?.added, 2)
        XCTAssertEqual(edit?.removed, 1)
        let write = AgentStepParser.diffStats(toolName: "Write", input: json(["content": "1\n2\n3"]))
        XCTAssertEqual(write?.added, 3)
        XCTAssertEqual(write?.removed, 0)
        let multi = AgentStepParser.diffStats(toolName: "MultiEdit", input: json(["edits": [
            ["old_string": "x", "new_string": "y"], ["old_string": "", "new_string": "z"],
        ]]))
        XCTAssertEqual(multi?.added, 2)
        XCTAssertEqual(multi?.removed, 1)
        XCTAssertNil(AgentStepParser.diffStats(toolName: "Edit", input: json(["old_string": "same", "new_string": "same"])))
    }

    func testSummaryTakesFirstParagraphWithoutMarkdown() {
        let message = "## Pronto\n\n**Migração aplicada** e `14` testes passaram.\nTudo certo.\n\n- detalhe 1\n- detalhe 2"
        XCTAssertEqual(message.agentSummary, "Pronto")
        XCTAssertEqual("**Migração aplicada** e `14` testes passaram.\nTudo certo.\n\nResto".agentSummary,
                       "Migração aplicada e 14 testes passaram. Tudo certo.")
        XCTAssertEqual("- item com marcador".agentSummary, "item com marcador")
    }

    func testAlwaysAllowKeepsOnlyAllowRules() {
        let raw: [Any] = [
            ["type": "addRules", "behavior": "allow", "destination": "localSettings",
             "rules": [["toolName": "Bash", "ruleContent": "npm test:*"]]],
            ["type": "setMode", "mode": "bypassPermissions", "destination": "session"],
            ["type": "addDirectories", "directories": ["/"], "destination": "session"],
            ["type": "addRules", "behavior": "deny", "rules": [["toolName": "Bash"]]],
        ]
        let kept = AgentPermissionRequest.allowRuleSuggestions(raw)
        XCTAssertEqual(kept?.rules, ["Bash(npm test:*)"])
        let decoded = try? JSONSerialization.jsonObject(with: kept!.data) as? [[String: Any]]
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertNil(AgentPermissionRequest.allowRuleSuggestions([["type": "setMode", "mode": "acceptEdits"]]))
    }

    func testPermissionHeadlines() {
        var request = AgentPermissionRequest(id: UUID(), toolName: "Bash", summary: "", receivedAt: Date())
        request.kind = .testing
        XCTAssertTrue(request.headline(agent: .claude).contains("Claude"))
        XCTAssertFalse(request.canAlwaysAllow)
        request.suggestions = Data("[]".utf8)
        XCTAssertFalse(request.canAlwaysAllow)  // sem regra para mostrar, sem "sempre"
        request.alwaysAllowRules = ["Bash(npm test:*)"]
        XCTAssertTrue(request.canAlwaysAllow)
    }
}
