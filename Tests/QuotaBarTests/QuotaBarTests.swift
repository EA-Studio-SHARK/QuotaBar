import XCTest
import CommonCrypto
@testable import QuotaBar

final class QuotaBarTests: XCTestCase {
    func testTransientFailureRetainsAndClearlyMarksLastSuccessfulUsage() {
        let previous = ProviderUsage.fromPercent(.codex, percent: 29, metrics: [])
        let failed = ProviderUsage.unavailable(.codex, message: "网络连接已中断")
        let retained = failed.retaining(previous)
        XCTAssertEqual(retained.status, .stale)
        XCTAssertEqual(retained.primaryPercent, 29)
        XCTAssertEqual(retained.updatedAt, previous.updatedAt)
        XCTAssertTrue(retained.displayPercent.contains("上次"))
        XCTAssertNil(UsageSnapshot(providers: [retained], fetchedAt: Date()).worstPercent)
        XCTAssertEqual(failed.retaining(nil), failed)
    }
    func testCodexAcceptsStringAndNumericCreditBalances() throws {
        for (json, expected) in [("\"12.5\"", 12.5), ("12.5", 12.5)] {
            let data = Data("{\"credits\":{\"has_credits\":true,\"unlimited\":false,\"balance\":\(json)},\"rate_limit\":{\"primary_window\":{\"used_percent\":27}}}".utf8)
            let decoded = try JSONDecoder().decode(OpenAIWham.Response.self, from: data)
            XCTAssertEqual(decoded.credits?.balance, expected)
            XCTAssertEqual(decoded.rate_limit?.primary_window?.used_percent, 27)
        }
    }

    func testUnparseableOptionalCreditsDoNotDiscardUsage() throws {
        let data = Data("{\"credits\":{\"balance\":\"unknown\"},\"rate_limit\":{\"primary_window\":{\"used_percent\":41}}}".utf8)
        let decoded = try JSONDecoder().decode(OpenAIWham.Response.self, from: data)
        XCTAssertNil(decoded.credits?.balance)
        XCTAssertEqual(decoded.rate_limit?.primary_window?.used_percent, 41)
    }

    func testCookieKeepsAllJWTComponents() {
        let cookie = "eyJheader.eyJpayload.signature"
        XCTAssertEqual(GrokProvider.cookieString(Data(cookie.utf8), host: ".grok.com", version: 23), cookie)
    }

    func testModernCookieValidatesAndRemovesHostHash() {
        let host = Data(".grok.com".utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = host.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(host.count), &hash) }
        let data = Data(hash) + Data("a.b.c".utf8)
        XCTAssertEqual(GrokProvider.cookieString(data, host: ".grok.com", version: 24), "a.b.c")
        XCTAssertNil(GrokProvider.cookieString(data, host: "wrong.com", version: 24))
    }

    func testDiscoveryOmitsAbsentProviders() {
        let home = URL(fileURLWithPath: "/fixture")
        let paths = Set(["/fixture/.codex/auth.json", "/fixture/.grok/auth.json", "/fixture/.gemini/jetski-standalone-oauth-token"])
        let found = ProviderDiscovery.detected(home: home, exists: { paths.contains($0) }, hasApp: { $0 == "com.todesktop.230313mzl4w4u92" })
        XCTAssertEqual(found, [.cursor, .grok, .antigravity], "卸载后残留的 .codex/auth.json 不应再把 Codex 算作已安装")
        XCTAssertFalse(found.contains(.codex))
        XCTAssertFalse(found.contains(.copilot))

        let reinstalledApp = ProviderDiscovery.detected(home: home, exists: { paths.contains($0) }, hasApp: { $0 == "com.openai.chat" })
        XCTAssertTrue(reinstalledApp.contains(.codex), "重装 ChatGPT.app / Codex.app 后应自动识别")

        let pathsWithCLI = paths.union(["/fixture/.local/bin/codex"])
        let reinstalledCLI = ProviderDiscovery.detected(home: home, exists: { pathsWithCLI.contains($0) }, hasApp: { _ in false })
        XCTAssertTrue(reinstalledCLI.contains(.codex), "重装 codex CLI 后应自动识别")
    }

    func testGrokBillingAndAntigravityQuotaParsing() throws {
        let grokJSON = Data("""
        {"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-07T17:06:20Z"},"creditUsagePercent":15.0}}
        """.utf8)
        let billing = try JSONDecoder().decode(GrokProvider.BillingResponse.self, from: grokJSON)
        XCTAssertEqual(billing.config?.creditUsagePercent, 15.0)
        XCTAssertEqual(billing.config?.currentPeriod?.type, "USAGE_PERIOD_TYPE_WEEKLY")

        let agyJSON = Data("""
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":0.96,"resetTime":"2026-11-01T13:41:34Z"},
          {"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.85,"resetTime":"2026-11-06T22:55:27Z"}
        ]}]}
        """.utf8)
        let summary = try JSONDecoder().decode(AntigravityProvider.QuotaSummaryResponse.self, from: agyJSON)
        let usage = try AntigravityProvider.parseQuota(summary)
        XCTAssertEqual(usage.status, .ok)
        XCTAssertEqual(usage.primaryPercent ?? 0, 15.0, accuracy: 0.01)
        XCTAssertEqual(usage.metrics.map(\.label), ["5小时", "周限额"])
        XCTAssertEqual(usage.metrics.first?.percent ?? 0, 4.0, accuracy: 0.01)
    }

    func testInvalidPercentageIsUnavailableInsteadOfCrashingNotifications() {
        XCTAssertEqual(ProviderUsage.fromPercent(.codex, percent: .nan, metrics: []).status, .unavailable)
        XCTAssertEqual(ProviderUsage.fromPercent(.codex, percent: -.infinity, metrics: []).status, .unavailable)
        XCTAssertEqual(ProviderUsage.fromPercent(.codex, percent: -5, metrics: []).primaryPercent, 0)
    }

    func testLocalProcessTimesOutAndDrainsLargeOutput() throws {
        XCTAssertThrowsError(try LocalProcess.output("/bin/sleep", ["3"], timeout: 0.05))
        let data = try LocalProcess.output("/usr/bin/printf", ["%100000s", "x"])
        XCTAssertEqual(data.count, 100000)
    }

    // MARK: Orbit 活动解析

    func testClaudeEditToolBecomesEditWithProject() {
        let obj: [String: Any] = [
            "type": "assistant", "cwd": "/Users/me/dev/helio", "timestamp": "2026-10-31T01:00:00.000Z",
            "message": ["content": [["type": "tool_use", "name": "Edit", "input": ["file_path": "/Users/me/dev/helio/src/lib/store.ts"]]]],
        ]
        let ev = ActivityParser.claude(obj)
        XCTAssertEqual(ev?.action, .edit("/Users/me/dev/helio/src/lib/store.ts"))
        XCTAssertEqual(ev?.cwd, "/Users/me/dev/helio")
        XCTAssertNotNil(ev?.date)

        let s = AgentSession(id: "x", kind: .claude, sessionId: "x", cwd: ev?.cwd, action: ev!.action!, lastURL: nil, updatedAt: Date())
        XCTAssertEqual(s.fileParts?.folder, "src/lib/")
        XCTAssertEqual(s.fileParts?.name, "store.ts")
        XCTAssertEqual(s.projectName, "helio")
    }

    func testClaudeBrowserToolKeepsURL() {
        let mapped = ActivityParser.claudeTool("mcp__Claude_Browser__navigate", ["url": "https://github.com/patoles/agent-flow"])
        XCTAssertEqual(mapped?.action, .browse("https://github.com/patoles/agent-flow"))
        XCTAssertEqual(AgentSession.shortURL("https://www.github.com/patoles"), "github.com/patoles")
        XCTAssertNil(ActivityParser.claudeTool("TodoWrite", [:]))
    }

    func testClaudeToolResultIsNotANewPrompt() {
        let result: [String: Any] = ["type": "user", "message": ["content": [["type": "tool_result", "content": "ok"]]]]
        XCTAssertNil(ActivityParser.claude(result)?.action)
        XCTAssertEqual(ActivityParser.claude(result)?.pending, false)

        var long = AgentSession(id: "x", kind: .claude, sessionId: "x", cwd: nil, action: .run("swift build"), lastURL: nil,
                                updatedAt: Date(timeIntervalSinceNow: -120))
        XCTAssertFalse(long.isActive())
        long.pending = true
        XCTAssertTrue(long.isActive(), "工具还在跑时，即使超过 45 秒也算在干活")
        let prompt: [String: Any] = ["type": "user", "message": ["content": "修一下登录"]]
        XCTAssertEqual(ActivityParser.claude(prompt)?.action, .think)
    }

    func testCodexPatchAndCommands() {
        let patch = "const patch = \"*** Begin Patch\\n*** Update File: /Users/me/dev/orbit/src/tray.rs\\n@@\""
        XCTAssertEqual(ActivityParser.codexTool("exec", patch)?.0, .edit("/Users/me/dev/orbit/src/tray.rs"))
        XCTAssertEqual(ActivityParser.patchFile("*** Begin Patch\n*** Add File: web/index.html\n+<p>"), .create("web/index.html"))

        let exec = #"const r = await tools.exec_command({cmd:"sed -n '1,120p' src/main.rs","workdir":"/Users/me/dev/orbit"});"#
        let mapped = ActivityParser.codexTool("exec", exec)
        XCTAssertEqual(mapped?.0, .read("/Users/me/dev/orbit/src/main.rs"))
        XCTAssertEqual(mapped?.1, "/Users/me/dev/orbit")

        XCTAssertEqual(ActivityParser.command("rg useSession src", workdir: nil), .search("rg useSession src"))
        XCTAssertEqual(ActivityParser.command("cargo test", workdir: nil), .run("cargo test"))
        XCTAssertEqual(AgentSession.meaningfulCommand(#"cd "/Users/dev/acme/x"; cd sub 2>/dev/null && swift build 2>&1 | tail -5"#), "swift build")
        XCTAssertEqual(ActivityParser.codex(["type": "event_msg", "payload": ["type": "task_complete"]])?.action, .done)
    }

    func testPlanStepsSayAndLines() {
        let todo = ActivityParser.planUpdate("TodoWrite", ["todos": [["content": "读代码", "status": "completed"],
                                                                      ["content": "改追踪", "status": "in_progress"]]])
        var s = AgentSession(id: "x", kind: .claude, sessionId: "x", cwd: nil, action: .think, lastURL: nil, updatedAt: Date())
        s.apply(todo!)
        XCTAssertEqual(s.plan.map(\.text), ["读代码", "改追踪"])

        s.apply(.set([PlanStep(text: "a", status: "in_progress"), PlanStep(text: "b", status: "pending")]))
        s.apply(ActivityParser.planUpdate("mcp__ccd_turn__update_plan", ["advance": true])!)
        XCTAssertEqual(s.plan.map(\.status), ["completed", "in_progress"])
        s.apply(ActivityParser.planUpdate("mcp__ccd_turn__wrap_up", [:])!)
        XCTAssertEqual(s.plan.map(\.status), ["completed", "completed"])
        XCTAssertNil(ActivityParser.planUpdate("mcp__ccd_turn__update_plan", ["scope": "x"]))

        XCTAssertEqual(ActivityParser.shortSay("**Now** rewrite the card view:\nmore"), "Now rewrite the card view")
        XCTAssertEqual(ActivityParser.shortSay("问题确认了。只显示最新动作"), "问题确认了")
        XCTAssertEqual(ActivityParser.editLines("Edit", ["new_string": "a\nb\nc"]), 3)
        XCTAssertEqual(ActivityParser.patchLines("*** Update File: a\n@@\n-x\n+y\n+z"), 2)

        XCTAssertEqual(AgentSession.projectRoot(current: "/Users/me/p", new: "/Users/me/p/static", home: "/Users/me"), "/Users/me/p")
        XCTAssertEqual(AgentSession.projectRoot(current: "/Users/me", new: "/Users/me/p", home: "/Users/me"), "/Users/me/p")
        XCTAssertEqual(AgentSession.projectRoot(current: "/Users/me/p", new: "/Users/me", home: "/Users/me"), "/Users/me/p")
        XCTAssertEqual(AgentSession.projectRoot(current: "/Users/me/p", new: "/Users/me/q", home: "/Users/me"), "/Users/me/q")

        let key = OrbitKey("/Users/me/p/app/x.py", cwd: "/Users/me/p")
        XCTAssertEqual(key.path, "app/x.py")
        XCTAssertEqual(OrbitKey("/Users/me/p/run.py", cwd: "/Users/me/p").path, "run.py")
        XCTAssertEqual(OrbitKey.resolve("app/x.py", cwd: "/Users/me/p"), "/Users/me/p/app/x.py")
    }

    func testClaudeBashReadingAFileShowsTheFile() {
        let piped = ActivityParser.claudeTool("Bash", ["command": #"sed -n 10,50p app/test_video.py | grep -nE "basket""#])
        XCTAssertEqual(piped?.action, .read("app/test_video.py"))
        let cd = ActivityParser.claudeTool("Bash", ["command": "cd /Users/me/dev/helio && cat src/a.ts"])
        XCTAssertEqual(cd?.action, .read("/Users/me/dev/helio/src/a.ts"))

        let s = AgentSession(id: "x", kind: .claude, sessionId: "x", cwd: "/Users/dev/demo-app", action: piped!.action,
                             lastURL: nil, updatedAt: Date())
        XCTAssertEqual(s.absolute("app/test_video.py"), "/Users/dev/demo-app/app/test_video.py")
        XCTAssertEqual(s.parts("app/test_video.py").folder, "app/")
        XCTAssertEqual(s.stepText, "在看 test_video.py")
    }

    func testGrokAndAntigravityActivityParsing() {
        let grokUser: [String: Any] = [
            "type": "user",
            "content": [["type": "text", "text": "<system_reminder>ignore</system_reminder>\n<user_query>\n重新设计导航站首页\n</user_query>"]],
        ]
        XCTAssertEqual(ActivityParser.grok(grokUser).first?.prompt, "重新设计导航站首页")

        let grokTurn: [String: Any] = [
            "type": "assistant",
            "content": "",
            "tool_calls": [
                ["id": "tc1", "name": "todo_write", "arguments": #"{"todos":[{"id":"s1","content":"改样式","status":"in_progress"},{"id":"s2","content":"测页面","status":"pending"}],"merge":false}"#],
                ["id": "tc2", "name": "search_replace", "arguments": #"{"file_path":"/Users/dev/web-nav/app/globals.css","old_string":"a","new_string":"b\nc"}"#],
            ],
        ]
        let grokEvents = ActivityParser.grok(grokTurn)
        XCTAssertEqual(grokEvents.count, 2)
        var gs = AgentSession(id: "g", kind: .grok, sessionId: "g", cwd: "/Users/dev/web-nav", action: .think, lastURL: nil, updatedAt: Date())
        if let plan = grokEvents[0].plan { gs.apply(plan) }
        XCTAssertEqual(gs.plan.map(\.text), ["改样式", "测页面"])
        if let merge = ActivityParser.planUpdate("todo_write", ["todos": [["id": "s1", "status": "completed"], ["id": "s2", "status": "in_progress"]], "merge": true]) {
            gs.apply(merge)
        }
        XCTAssertEqual(gs.plan.map(\.status), ["completed", "in_progress"])
        XCTAssertEqual(grokEvents[1].action, .edit("/Users/dev/web-nav/app/globals.css"))
        XCTAssertEqual(grokEvents[1].lines, 2)

        let agyInput: [String: Any] = [
            "type": "USER_INPUT",
            "content": "<USER_REQUEST>\n把所有 AI 工具额度接进来\n</USER_REQUEST>",
        ]
        XCTAssertEqual(ActivityParser.antigravity(agyInput).first?.prompt, "把所有 AI 工具额度接进来")

        let agyTool: [String: Any] = [
            "type": "PLANNER_RESPONSE",
            "step_index": 12,
            "content": "开始修改发现逻辑。",
            "tool_calls": [
                ["name": "edit_file", "args": ["Path": "\"/Users/me/QuotaBar/Sources/QuotaBar/ProviderDiscovery.swift\"", "Target": "\"old\"", "Replacement": "\"new1\\nnew2\""]],
            ],
        ]
        let agyEvents = ActivityParser.antigravity(agyTool)
        XCTAssertEqual(agyEvents.first?.action, .edit("/Users/me/QuotaBar/Sources/QuotaBar/ProviderDiscovery.swift"))
        XCTAssertEqual(agyEvents.first?.lines, 2)
        XCTAssertEqual(agyEvents.first?.say, "开始修改发现逻辑")
    }
}
