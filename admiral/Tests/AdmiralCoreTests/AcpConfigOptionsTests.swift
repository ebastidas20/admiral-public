import XCTest
@testable import AdmiralCore

final class AcpConfigOptionsTests: XCTestCase {
    private func json(_ s: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }

    /// claude-agent-acp's `session/new` result (permission mode + two models), as it sends it.
    static let claudeAgentACP = """
    {"sessionId":"s1","configOptions":[
     {"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"default",
      "description":"Session permission mode",
      "options":[
       {"value":"default","name":"Manual","description":"Always ask before making changes","_meta":{"kind":"standard"}},
       {"value":"acceptEdits","name":"Accept edits","description":"Automatically accept all file edits",
        "_meta":{"kind":"standard"}},
       {"value":"plan","name":"Plan","description":"Create a plan before making changes","_meta":{"kind":"plan"}},
       {"value":"auto","name":"Auto","description":"Claude handles permission decisions",
        "_meta":{"kind":"auto_review"}},
       {"value":"bypassPermissions","name":"Bypass permissions","description":"Accepts all permissions",
        "_meta":{"kind":"full_access"}}]},
     {"id":"model","name":"Model","category":"model","type":"select","currentValue":"claude-sonnet-4-6",
      "description":"AI model to use",
      "options":[{"value":"claude-sonnet-4-6","name":"Sonnet"},{"value":"claude-opus-4-6","name":"Opus"}]}],
    "modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Manual"},{"id":"plan","name":"Plan"}]}}
    """

    /// A mode or a model names itself; any other option's value needs its name ("Fast: Off").
    func testChipLabelLeadsWithTheNameExceptForModeAndModel() {
        func option(_ name: String, _ category: String?, current: String? = "off") -> AcpConfigOption {
            AcpConfigOption(id: name.lowercased(), name: name, category: category, currentValue: current,
                            values: [AcpOptionValue(value: "on", name: "On"), AcpOptionValue(value: "off", name: "Off")])
        }
        XCTAssertEqual(option("Mode", "mode").chipLabel, "Off")
        XCTAssertEqual(option("Model", "model").chipLabel, "Off")
        XCTAssertEqual(option("Fast", "model_config").chipLabel, "Fast: Off")
        XCTAssertEqual(option("Effort", "thought_level", current: "on").chipLabel, "Effort: On")
        XCTAssertEqual(option("Agent", nil, current: "custom").chipLabel, "Agent: custom")
        XCTAssertEqual(option("Fast", "model_config", current: nil).chipLabel, "Fast")
    }

    func testDecodesClaudeAgentACPOptions() {
        let options = AcpConfigOption.decodeAll(json(Self.claudeAgentACP))
        XCTAssertEqual(options.map(\.id), ["mode", "model"], "configOptions win over modes")
        XCTAssertEqual(options.map(\.name), ["Mode", "Model"])
        XCTAssertEqual(options[0].values.count, 5)
        XCTAssertEqual(options[0].values[3].value, "auto")
        XCTAssertEqual(options[0].values[0].name, "Manual")
        XCTAssertEqual(options[0].values[0].description, "Always ask before making changes")
        XCTAssertEqual(options[0].currentValue, "default")
        XCTAssertEqual(options[0].currentName, "Manual")
        XCTAssertEqual(options[0].category, "mode")
        XCTAssertEqual(options[0].description, "Session permission mode")
        XCTAssertEqual(options.map(\.setter), [.configOption, .configOption])
        XCTAssertEqual(options[1].values.map(\.value), ["claude-sonnet-4-6", "claude-opus-4-6"])
        XCTAssertNil(options[1].values[0].group)
    }

    func testGroupedOptionsFlattenWithTheirGroup() {
        let options = AcpConfigOption.decodeAll(json("""
        {"configOptions":[{"id":"model","name":"Model","type":"select","currentValue":"b","options":[
          {"group":"rec","name":"Recommended","options":[{"value":"a","name":"A"},{"value":"b","name":"B"}]},
          {"group":"more","name":"More","options":[{"value":"c","name":"C","description":"slow"}]}]}]}
        """))
        XCTAssertEqual(options.first?.values, [
            AcpOptionValue(value: "a", name: "A", group: "Recommended"),
            AcpOptionValue(value: "b", name: "B", group: "Recommended"),
            AcpOptionValue(value: "c", name: "C", description: "slow", group: "More"),
        ])
    }

    func testBooleanOptionsAreDropped() {
        let options = AcpConfigOption.decodeAll(json("""
        {"configOptions":[{"id":"fast","name":"Fast","type":"boolean","currentValue":true},
          {"id":"model","name":"Model","type":"select","currentValue":"a","options":[{"value":"a","name":"A"}]}]}
        """))
        XCTAssertEqual(options.map(\.id), ["model"])
    }

    func testOnlyBooleanOptionsFallBackToModes() {
        let options = AcpConfigOption.decodeAll(json("""
        {"configOptions":[{"id":"fast","name":"Fast","type":"boolean","currentValue":true}],
         "modes":{"currentModeId":"a","availableModes":[{"id":"a","name":"Ask"}]}}
        """))
        XCTAssertEqual(options.map(\.id), ["mode"])
        XCTAssertEqual(options.first?.setter, .legacyMode)
    }

    func testLegacyModesBecomeOneModeOption() {
        let options = AcpConfigOption.decodeAll(json("""
        {"modes":{"currentModeId":"a","availableModes":[{"id":"a","name":"Ask"},{"id":"b","name":"Code"}]}}
        """))
        XCTAssertEqual(options, [AcpConfigOption(
            id: "mode", name: "Mode", category: "mode", currentValue: "a",
            values: [AcpOptionValue(value: "a", name: "Ask"), AcpOptionValue(value: "b", name: "Code")],
            setter: .legacyMode)])
        XCTAssertEqual(AcpConfigOption.decodeAll(json("{}")), [])
        XCTAssertEqual(AcpConfigOption.decodeAll(json(#"{"configOptions":null,"modes":null}"#)), [])
    }

    func testOrderedPutsModeModelThenOthersLast() {
        func o(_ id: String, _ category: String?) -> AcpConfigOption {
            AcpConfigOption(id: id, name: id, category: category, currentValue: nil, values: [])
        }
        let ordered = AcpConfigOption.ordered([
            o("_x", "_custom"), o("effort", "thought_level"), o("model", "model"), o("none", nil),
            o("fast", "model_config"), o("mode", "mode"), o("_y", "_custom"),
        ])
        XCTAssertEqual(ordered.map(\.id), ["mode", "model", "fast", "effort", "_x", "none", "_y"])
    }

    func testApplyingCurrentModeSetsOnlyTheModeOption() {
        let options = AcpConfigOption.decodeAll(json(Self.claudeAgentACP)).applyingCurrentMode("plan")
        XCTAssertEqual(options.map(\.currentValue), ["plan", "claude-sonnet-4-6"])
    }

    func testConfigOptionUpdateDecodesTheFullList() {
        let update = AcpUpdate.decode(json("""
        {"sessionId":"s1","update":{"sessionUpdate":"config_option_update","configOptions":[
          {"id":"model","name":"Model","type":"select","currentValue":"a","options":[{"value":"a","name":"A"}]}]}}
        """))
        XCTAssertEqual(update?.updates.first, .configOptions([AcpConfigOption(
            id: "model", name: "Model", currentValue: "a", values: [AcpOptionValue(value: "a", name: "A")])]))
    }

    // MARK: - Catalog store

    func testCatalogRoundTripsPerAgent() {
        let suite = "acp-catalog-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AcpOptionCatalogStore(defaults: defaults)
        let (a, b) = (UUID(), UUID())
        let options = AcpConfigOption.decodeAll(json(Self.claudeAgentACP))
        XCTAssertEqual(store.load(agentID: a), [])
        store.save(options, agentID: a)
        store.save([options[1]], agentID: b)
        XCTAssertEqual(AcpOptionCatalogStore(defaults: defaults).load(agentID: a), options)
        XCTAssertEqual(store.load(agentID: b), [options[1]])
    }

    // MARK: - Draft

    func testDraftSplitsCatalogOptionsFromOtherRows() {
        let catalog = AcpConfigOption.decodeAll(json(Self.claudeAgentACP))
        let config = AcpAgentConfig(
            name: "A", launch: AcpCommand(command: "npx"), cwd: "/w",
            defaultConfigOptions: ["mode": "plan", "custom": "1"])
        var draft = AcpAgentDraft(config, catalog: catalog)
        XCTAssertEqual(draft.startingOptions, ["mode": "plan"])
        XCTAssertEqual(draft.configOptions.map, ["custom": "1"])
        draft.startingOptions["model"] = "claude-opus-4-6"
        draft.startingOptions["mode"] = nil
        XCTAssertEqual(draft.config.defaultConfigOptions, ["model": "claude-opus-4-6", "custom": "1"])
        XCTAssertTrue(draft.validationErrors.isEmpty)

        draft.configOptions = AcpPairList(["model": "x"])
        XCTAssertFalse(draft.validationErrors.isEmpty, "a row for an option already picked is a duplicate")

        let noCatalog = AcpAgentDraft(config)
        XCTAssertEqual(noCatalog.startingOptions, [:])
        XCTAssertEqual(noCatalog.configOptions.map, ["mode": "plan", "custom": "1"])
    }
}
