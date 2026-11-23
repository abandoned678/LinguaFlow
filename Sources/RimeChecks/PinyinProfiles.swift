import Foundation
import RimeInput

@MainActor
enum PinyinProfiles {
    static func run(shared: URL) throws {
        let user = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: user) }
        let runtime = try RimeRuntime(sharedDataDirectory: shared, userDataDirectory: user)
        let engine = try RimeEngine(runtime: runtime)
        let other = try RimeEngine(runtime: runtime)
        func require(_ condition: Bool, _ name: String) throws {
            if !condition { throw NSError(domain: "PinyinProfiles." + name, code: 1) }
        }
        func type(_ code: String) -> RimeSnapshot {
            engine.clear()
            var s = engine.process(keyCode: Int32(code.utf8.first!))
            for key in code.utf8.dropFirst() { s = engine.process(keyCode: Int32(key)) }
            return s
        }
        for layout in ["full", "flypy"] {
            for groups in ["", "z", "c", "s", "zc", "zs", "cs", "zcs"] {
                for suffix in ["", "_private"] {
                    let schema = layout == "full" && groups.isEmpty && suffix.isEmpty
                        ? "luna_pinyin_simp" : "sjy_" + layout + groups + suffix
                    engine.clear()
                    try require(engine.selectSchema(schema), "schemaAvailable")
                    let snapshot = type(layout == "flypy" ? "nihc" : "nihao")
                    try require(snapshot.candidates.first?.text == "你好", "layout")
                }
            }
        }
        // Compare the displayed first five candidates with a cold dictionary.
        // Report only ranks and counts; actual candidate strings stay in memory.
        for (group, full, flypy, target) in [("z", "zongguo", "zsgo", "中国"),
                                            ("c", "ceshi", "ceui", "车市"),
                                            ("s", "senme", "sfme", "什么")] {
            for (layout, code, base) in [("full", full, "luna_pinyin_simp"), ("flypy", flypy, "sjy_flypy")] {
                engine.clear()
                try require(engine.selectSchema(base), "baselineSchema")
                let baseline = type(code).candidates.map(\.text)
                for groups in [group, "zcs"] {
                    engine.clear()
                    try require(engine.selectSchema("sjy_" + layout + groups), "fuzzySchema")
                    let enabled = type(code).candidates.map(\.text)
                    let rankBefore = baseline.firstIndex(of: target).map { $0 + 1 } ?? 0
                    let rankAfter = enabled.firstIndex(of: target).map { $0 + 1 } ?? 0
                    let additional = Set(enabled).subtracting(baseline).subtracting([target]).count
                    print("layout=\(layout) sample=\(group) groups=\(groups) before=\(rankBefore) after=\(rankAfter) additional=\(additional)")
                    try require(rankAfter > 0 && (rankBefore == 0 || rankAfter < rankBefore), "fuzzyRank")
                }
            }
        }
        engine.clear()
        try require(!engine.selectSchema("sjy_nonexistent_private"), "unavailablePrivateSchema")
        var slot = RimeSessionSlot()
        var attempts = 0
        func create(_ schema: String) -> RimeEngine? {
            attempts += 1
            return try? RimeEngine(runtime: runtime, schema: schema)
        }
        slot.load(schema: "sjy_nonexistent_private", create: create)
        slot.load(schema: "sjy_nonexistent_private", create: create)
        try require(slot.engine == nil && attempts == 1, "suppressRepeatedCreation")
        slot.load(schema: "sjy_nonexistent_private", reactivated: true, create: create)
        try require(slot.engine == nil && attempts == 2, "retryOnActivation")
        slot.load(schema: "luna_pinyin_simp", create: create)
        let recovered = slot.engine
        try require(recovered != nil && attempts == 3, "recoverOnValidSchema")
        _ = recovered?.process(keyCode: 110)
        try require(recovered?.process(keyCode: 105).preedit.isEmpty == false, "recoveredComposition")
        slot.load(schema: "sjy_fullz", create: create)
        try require(slot.engine === recovered && attempts == 3, "preserveActiveSession")
        recovered?.clear()
        try require(recovered?.selectSchema("sjy_idle") == true, "releaseRecoveredReader")
        let phraseFile = user.appendingPathComponent("sjy_personal.txt")
        for phrase in ["繁體測試", "修改短語", ""] {
            engine.clear()
            try require(engine.selectSchema("sjy_idle") && other.selectSchema("sjy_idle"), "releaseReaders")
            let value = phrase.isEmpty ? "" : "\(phrase)\tsjy\t100\n"
            try ("# Rime table\n#@/db_name\tsjy_personal\n#@/db_type\ttabledb\n" + value)
                .write(to: phraseFile, atomically: true, encoding: .utf8)
            try require(engine.selectSchema("sjy_flypyzcs_private") && other.selectSchema("luna_pinyin_simp"), "reopenReaders")
            for reader in [engine, other] {
                var snapshot = reader.process(keyCode: 115)
                for key in "jy".utf8 { snapshot = reader.process(keyCode: Int32(key)) }
                let first = snapshot.candidates.first?.text
                if phrase.isEmpty {
                    try require(first != "修改短語" && first != "修改短语", "nativePhraseDeletion")
                } else {
                    try require(first == phrase && reader.selectCandidate(at: 0).commit == phrase, "nativeLiteralPhrase")
                }
                reader.clear()
            }
        }
        // Reverse the two weights after the idle-schema handoff; file order stays
        // unchanged, so cached readers and ignored weights both fail this check.
        let weightedFile = user.appendingPathComponent("sjy_weighted.txt")
        for (firstWeight, secondWeight) in [(120, 90), (90, 120)] {
            let rows = "# Rime table\n#@/db_name\tsjy_weighted\n#@/db_type\ttabledb\n红样本\tqaz\t\(firstWeight)\n蓝样本\tqaz\t\(secondWeight)\n"
            // Imports publish the complete file first; idle controllers then drop
            // their old native readers before the next composition starts.
            try rows.write(to: weightedFile, atomically: true, encoding: .utf8)
            try require(engine.selectSchema("sjy_idle") && other.selectSchema("sjy_idle"), "releaseWeightedReaders")
            let expected = firstWeight > secondWeight ? ["红样本", "蓝样本"] : ["蓝样本", "红样本"]
            for (reader, schema) in [(engine, "luna_pinyin_simp"), (other, "sjy_flypy_private")] {
                try require(reader.selectSchema(schema), "openWeightedProfile")
                var ranked = reader.process(keyCode: 113)
                for key in "az".utf8 { ranked = reader.process(keyCode: Int32(key)) }
                try require(Array(ranked.candidates.prefix(2).map(\.text)) == expected, "nativeImportedFrequencyOrder")
                try require(reader.selectCandidate(at: 0).commit == expected[0], "nativeImportedFrequencyCommit")
                reader.clear()
            }
        }
        try FileManager.default.removeItem(at: weightedFile)
        try require(engine.selectSchema("sjy_idle") && other.selectSchema("sjy_idle"), "releaseClearedWeightReaders")
        try require(engine.selectSchema("luna_pinyin_simp"), "reopenClearedWeights")
        try require(!type("qaz").candidates.contains(where: { ["红样本", "蓝样本"].contains($0.text) }), "removedImportedWeights")
        print("Native imported frequencies, updates and removal passed")
        print("32 native layout/learning profiles, fuzzy initials, unavailable schema and multi-session phrase mutations passed")
    }
}
