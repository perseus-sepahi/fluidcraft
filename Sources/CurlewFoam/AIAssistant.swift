import Foundation
import Security
import CurlewMesh
import CurlewSolver

/// AI providers the assistant can talk to.
public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Claude (Anthropic Messages API).
    case anthropic
    /// Any OpenAI-compatible chat-completions endpoint (a gateway or another vendor).
    case openAICompatible
    /// A local model served by Ollama (no key, nothing leaves the Mac).
    case ollama

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic Claude"
        case .openAICompatible: return "OpenAI-compatible endpoint"
        case .ollama: return "Ollama (local)"
        }
    }
    public var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return "https://api.openai.com/v1"
        case .ollama: return "http://localhost:11434"
        }
    }
    public var defaultModel: String {
        switch self {
        case .anthropic: return "claude-opus-5-5"
        case .openAICompatible: return ""
        case .ollama: return "llama3.1"
        }
    }
    /// Models offered in the picker (any other id can be typed).
    public var suggestedModels: [String] {
        switch self {
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
        case .openAICompatible: return []
        case .ollama: return ["llama3.1", "qwen2.5", "mistral"]
        }
    }
    public var needsKey: Bool { self != .ollama }
    /// Environment variable read when no key is stored in the Keychain.
    public var keyEnvironmentVariable: String? {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openAICompatible: return "OPENAI_API_KEY"
        case .ollama: return nil
        }
    }
}

/// Assistant settings. Stored in Curlew's preferences, never in case files; API keys live in
/// the macOS Keychain (`AIKeychain`).
public struct AISettings: Codable, Sendable, Equatable {
    public var provider: AIProvider = .anthropic
    public var model = AIProvider.anthropic.defaultModel
    /// Empty: the provider's default endpoint.
    public var baseURL = ""
    /// Claude: reasoning effort (low, medium, high, xhigh, max).
    public var effort = "high"
    public var maxTokens = 16000
    /// Claude: retry a declined request on Anthropic's recommended model (server-side fallback).
    public var serverFallback = true
    /// Send a summary of the open case (setup, mesh, residuals, reports, recent errors).
    public var includeCaseContext = true

    public init() {}

    public var endpoint: String { baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? provider.defaultBaseURL : baseURL }

    public static let defaultsKey = "curlew.ai.settings"
    public static func load() -> AISettings {
        guard let d = UserDefaults.standard.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(AISettings.self, from: d) else { return AISettings() }
        return s
    }
    public func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: AISettings.defaultsKey) }
    }
}

/// API keys in the login Keychain (service "Curlew AI", one item per provider).
public enum AIKeychain {
    static let service = "Curlew AI"

    public static func key(for p: AIProvider) -> String? {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: p.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        if let v = p.keyEnvironmentVariable, let e = ProcessInfo.processInfo.environment[v], !e.isEmpty { return e }
        return nil
    }

    public static func hasStoredKey(_ p: AIProvider) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Store (or, with an empty string, remove) the key.
    @discardableResult
    public static func setKey(_ key: String, for p: AIProvider) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: p.rawValue]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

public struct AIMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id = UUID()
    public var role: Role
    public var text: String
    public init(role: Role, text: String) { self.role = role; self.text = text }
}

public struct AIError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// The assistant: one request per user turn, with the whole visible conversation.
public enum AIAssistant {
    public static let systemPrompt = """
    You are an experienced CFD engineer helping a user of Curlew, a macOS CFD application that \
    meshes geometry (block meshes, Gmsh, snappyHexMesh) and solves cases with OpenFOAM (ESI \
    v2606); Curlew does the setup, pre- and post-processing. Curlew's setup \
    follows Ansys Fluent's vocabulary (General, Models, Materials, Cell Zone Conditions, \
    Boundary Conditions, Methods, Controls, Report Definitions) and maps it to OpenFOAM \
    dictionaries. It has modules for wind farms (actuator disks in an atmospheric boundary \
    layer), wind-turbine rotors (MRF), electronics cooling (conjugate heat transfer), CAD \
    analysis, and physics-informed neural networks.

    When a case summary is attached, ground your answer in it: point at the page and the \
    setting to change, give values with units, and say why. Flag physics that is likely wrong \
    (Reynolds number versus the turbulence model, y+ versus wall treatment, mesh quality, \
    boundary conditions that over- or under-constrain the flow, energy balances that do not \
    close). If something cannot be judged from the summary, say what you would need to see.
    """

    /// Text summary of the open case, sent with each question when enabled.
    public static func caseContext(mesh: Mesh?, setup: CaseSetup, quality: MeshQualityReport?, residuals: [String: Double],
                                   reports: [String: Double], recentLog: [String]) -> String {
        var t = "## Case: \(setup.title.isEmpty ? "untitled" : setup.title)\n"
        t += "Solver: OpenFOAM \(FoamCaseWriter.resolvedApplication(setup).rawValue)"
        t += ", \(setup.general.time.rawValue), viscous \(setup.models.viscous.rawValue), energy \(setup.models.energy ? "on" : "off")"
        if setup.general.gravityEnabled { t += ", gravity \(setup.general.gravity)" }
        t += "\n"
        if let m = mesh {
            t += "Mesh: \(m.summary); shapes \(m.cellShapeHistogram())\n"
            for z in m.boundaryZones where z.kind != .empty {
                let b = setup.boundaries[z.name]
                var d = "  boundary \(z.name): \(b?.type.rawValue ?? z.kind.rawValue), \(z.count) faces"
                if let b {
                    switch b.type {
                    case .velocityInlet: d += b.atmosphericBoundaryLayer != nil ? ", ABL inlet \(b.atmosphericBoundaryLayer!.referenceVelocity) m/s at \(b.atmosphericBoundaryLayer!.referenceHeight) m" : ", |U| \(b.velocityMagnitude.constantValue.map { "\($0) m/s" } ?? "expression")"
                    case .pressureOutlet, .pressureInlet: d += ", p \(b.gaugePressure.constantValue.map { "\($0)" } ?? "expression") Pa"
                    case .wall: d += ", \(b.wallMotion.rawValue), thermal \(b.thermalCondition.rawValue)"
                    default: break
                    }
                }
                t += d + "\n"
            }
            for z in m.cellZones {
                let c = setup.cellZones[z.name]
                var d = "  cell zone \(z.name): \(c?.kind.rawValue ?? z.kind.rawValue), \(z.cellCount) cells, material \(c?.material ?? "?")"
                if c?.frameMotion == true { d += ", MRF \(c!.rotationSpeed) rad/s" }
                if c?.porous != nil { d += ", porous" }
                if c?.actuatorDisk != nil { d += ", actuator disk Ct \(c!.actuatorDisk!.thrustCoefficient)" }
                if let q = c?.energySource.constantValue, q != 0 { d += ", heat source \(q) W/m³" }
                t += d + "\n"
            }
        } else {
            t += "Mesh: none loaded\n"
        }
        if let q = quality {
            t += String(format: "Mesh quality: min orthogonal quality %.3g, max non-orthogonality %.1f°, max aspect ratio %.3g, %d non-positive cells, %d inverted face pyramids\n",
                        q.minOrthogonalQuality, q.maxNonOrthogonality, q.maxAspectRatio, q.negativeVolumes, q.invertedFacePyramids)
        }
        for name in Set(setup.cellZones.values.map(\.material)).sorted() {
            if let m = setup.material(named: name) {
                t += "Material \(name): rho \(m.density), mu \(m.viscosity), cp \(m.specificHeat), k \(m.thermalConductivity)\n"
            }
        }
        t += "Methods: \(setup.methods.coupling.rawValue), momentum \(setup.methods.momentum.rawValue); URF p \(setup.controls.urf.pressure), U \(setup.controls.urf.momentum)\n"
        let o = setup.openfoam
        t += "OpenFOAM: turbulence \(o.turbulence.rawValue), wall treatment \(o.wallTreatment.rawValue), cores \(o.cores), radiation \(o.radiation.model.rawValue)\n"
        if !residuals.isEmpty {
            t += "Latest scaled residuals: " + residuals.sorted { $0.key < $1.key }.map { String(format: "%@ %.2e", $0.key as NSString, $0.value) }.joined(separator: ", ") + "\n"
        }
        if !reports.isEmpty {
            t += "Reports: " + reports.sorted { $0.key < $1.key }.map { String(format: "%@ = %.6g", $0.key as NSString, $0.value) }.joined(separator: ", ") + "\n"
        }
        if !recentLog.isEmpty { t += "Recent warnings and errors:\n" + recentLog.suffix(15).map { "  " + $0 }.joined(separator: "\n") + "\n" }
        return t
    }

    /// Send the conversation; returns the assistant's reply.
    public static func reply(to conversation: [AIMessage], context: String?, settings s: AISettings) async throws -> String {
        let key = AIKeychain.key(for: s.provider)
        if s.provider.needsKey && (key ?? "").isEmpty {
            throw AIError("No API key for \(s.provider.displayName). Add one in Settings › AI (it is stored in your Keychain).")
        }
        guard !s.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw AIError("Choose a model in Settings › AI.") }
        var turns = conversation.filter { !$0.text.isEmpty }
        if let ctx = context, let i = turns.lastIndex(where: { $0.role == .user }) {
            turns[i].text = "<case_summary>\n\(ctx)</case_summary>\n\n" + turns[i].text
        }
        switch s.provider {
        case .anthropic: return try await anthropic(turns, key: key!, s)
        case .openAICompatible: return try await openAI(turns, key: key ?? "", s)
        case .ollama: return try await ollama(turns, s)
        }
    }

    static func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> [String: Any] {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: r)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? (json["error"] as? String) ?? String(decoding: data.prefix(400), as: UTF8.self)
            throw AIError("HTTP \(h.statusCode): \(msg)")
        }
        return json
    }

    /// Claude Messages API (raw HTTP: Swift has no official Anthropic SDK).
    static func anthropic(_ turns: [AIMessage], key: String, _ s: AISettings) async throws -> String {
        guard let url = URL(string: s.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages") else { throw AIError("bad endpoint \(s.endpoint)") }
        var headers = ["x-api-key": key, "anthropic-version": "2026-10-21"]
        var body: [String: Any] = [
            "model": s.model,
            "max_tokens": max(1024, s.maxTokens),
            "system": systemPrompt,
            "messages": turns.map { ["role": $0.role.rawValue, "content": $0.text] },
        ]
        let effortModels = ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1", "claude-fable-5", "claude-haiku-5-5", "claude-opus-4-8", "claude-opus-4-7"]
        if effortModels.contains(s.model) && !s.effort.isEmpty { body["output_config"] = ["effort": s.effort] }
        // server-side refusal fallback (Claude API): Anthropic picks the retry model by category
        if s.serverFallback && ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-1"].contains(s.model) && s.baseURL.isEmpty {
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            body["fallbacks"] = "default"
        }
        let json = try await post(url, headers: headers, body: body)
        if (json["stop_reason"] as? String) == "refusal" {
            let why = ((json["stop_details"] as? [String: Any])?["explanation"] as? String) ?? ""
            throw AIError("Claude declined this request\(why.isEmpty ? "" : ": \(why)").")
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        if (json["stop_reason"] as? String) == "max_tokens" { return text + "\n\n[cut off at the token limit — raise Max tokens in Settings › AI]" }
        return text
    }

    static func openAI(_ turns: [AIMessage], key: String, _ s: AISettings) async throws -> String {
        guard let url = URL(string: s.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else { throw AIError("bad endpoint \(s.endpoint)") }
        let msgs: [[String: Any]] = [["role": "system", "content": systemPrompt]] + turns.map { ["role": $0.role.rawValue, "content": $0.text] }
        let json = try await post(url, headers: key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"],
                                  body: ["model": s.model, "messages": msgs, "max_tokens": max(1024, s.maxTokens)])
        let choice = (json["choices"] as? [[String: Any]])?.first
        return ((choice?["message"] as? [String: Any])?["content"] as? String) ?? ""
    }

    static func ollama(_ turns: [AIMessage], _ s: AISettings) async throws -> String {
        guard let url = URL(string: s.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/chat") else { throw AIError("bad endpoint \(s.endpoint)") }
        let msgs: [[String: Any]] = [["role": "system", "content": systemPrompt]] + turns.map { ["role": $0.role.rawValue, "content": $0.text] }
        let json = try await post(url, headers: [:], body: ["model": s.model, "messages": msgs, "stream": false])
        return ((json["message"] as? [String: Any])?["content"] as? String) ?? ""
    }
}
