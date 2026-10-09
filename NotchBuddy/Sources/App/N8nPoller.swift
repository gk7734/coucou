import Foundation

// MARK: - N8nPoller
// Polls n8n for the latest workflow execution every 15s.
// Tries /api/v1/executions first, falls back to /rest/executions.
// On a new terminal execution: fetches full details, stores [name, detail] in steps.

final class N8nPoller: @unchecked Sendable {
    static let shared = N8nPoller()
    private let gate = ServicePollGate(pillId: "integration_n8n", keychainKeys: ["n8n-url", "n8n-api-key"])
    // Read and written only by the poll, which the gate runs one at a time.
    private var lastExecutionId: String = ""

    private init() {}

    @MainActor
    func start() {
        gate.start(after: 3, every: 15) { [weak self] generation in
            await self?.poll(generation: generation)
        }
    }

    // MARK: - Poll list endpoint

    private func poll(generation: Int) async {
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            n8nLog("No API key or URL configured")
            return
        }
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoints = [
            "\(base)/api/v1/executions?limit=1&includeData=false",
            "\(base)/rest/executions?limit=1&includeData=false",
        ]
        await tryList(endpoints, apiKey: apiKey, base: base, idx: 0, generation: generation)
    }

    private func tryList(_ urls: [String], apiKey: String, base: String, idx: Int, generation: Int) async {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            n8nLog("All list endpoints failed")
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        n8nLog("Polling \(url.host ?? "?")\(url.path)")

        let (data, code, error) = await ServicePollGate.load(req)
        if let error {
            n8nLog("Network error: \(error.localizedDescription)")
            await tryList(urls, apiKey: apiKey, base: base, idx: idx + 1, generation: generation)
            return
        }
        guard let data else {
            await tryList(urls, apiKey: apiKey, base: base, idx: idx + 1, generation: generation)
            return
        }
        n8nLog("HTTP \(code) · \(data.count) bytes")
        guard code == 200 else {
            await tryList(urls, apiKey: apiKey, base: base, idx: idx + 1, generation: generation)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return }

        // Response is either { "data": [...] } or [...]
        let items: [[String: Any]]
        if let obj = json as? [String: Any], let arr = obj["data"] as? [[String: Any]] {
            items = arr
        } else if let arr = json as? [[String: Any]] {
            items = arr
        } else {
            n8nLog("Unexpected response shape")
            return
        }

        guard let first = items.first else { n8nLog("No executions found"); return }

        let id: String
        if let s = first["id"] as? String      { id = s }
        else if let n = first["id"] as? Int    { id = "\(n)" }
        else { n8nLog("No id in execution"); return }

        guard id != lastExecutionId else {
            n8nLog("Same id=\(id) — no change")
            return
        }

        // Terminal check: use status field — more reliable than the `finished` bool
        // (published workflows often have finished=false on error)
        let status = first["status"] as? String ?? ""
        let isTerminal = ["success", "error", "crashed", "canceled", "failed"].contains(status)
        guard isTerminal else {
            n8nLog("id=\(id) status=\(status.isEmpty ? "?" : status) — not terminal")
            return
        }

        lastExecutionId = id
        let success = status == "success"
        n8nLog("New execution id=\(id) status=\(status)")

        // Fetch full detail (includeData=true required in some n8n versions)
        let detailUrls = [
            "\(base)/api/v1/executions/\(id)?includeData=true",
            "\(base)/api/v1/executions/\(id)",
            "\(base)/rest/executions/\(id)?includeData=true",
            "\(base)/rest/executions/\(id)",
        ]
        await fetchDetail(detailUrls, apiKey: apiKey, success: success, idx: 0, generation: generation)
    }

    // MARK: - Fetch full execution detail

    private func fetchDetail(_ urls: [String], apiKey: String, success: Bool, idx: Int, generation: Int) async {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            dispatch(success: success, name: "Workflow", detail: nil, generation: generation)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, code, _) = await ServicePollGate.load(req)
        guard let data, code == 200 else {
            n8nLog("Detail HTTP \(code) \(url.host ?? "?")\(url.path)")
            await fetchDetail(urls, apiKey: apiKey, success: success, idx: idx + 1, generation: generation)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            await fetchDetail(urls, apiKey: apiKey, success: success, idx: idx + 1, generation: generation)
            return
        }
        let name = extractWorkflowName(from: json)
        let detail = parseDetail(from: json, success: success)
        n8nLog("Parsed: \(name)")
        dispatch(success: success, name: name, detail: detail, generation: generation)
    }

    private func extractWorkflowName(from json: [String: Any]) -> String {
        if let wd = json["workflowData"] as? [String: Any], let name = wd["name"] as? String { return name }
        if let name = json["name"] as? String { return name }
        return "Workflow"
    }

    // MARK: - Parse execution output / error message

    private func parseDetail(from json: [String: Any], success: Bool) -> String? {
        guard let execData   = json["data"] as? [String: Any],
              let resultData = execData["resultData"] as? [String: Any] else { return nil }

        if success {
            return parseSuccessDetail(resultData: resultData)
        } else {
            return parseErrorDetail(resultData: resultData)
        }
    }

    private func parseErrorDetail(resultData: [String: Any]) -> String? {
        // Top-level error
        if let error = resultData["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? ""
            if let node = (error["node"] as? [String: Any])?["name"] as? String, !node.isEmpty {
                return "\(node)\n\(msg)"
            }
            return msg
        }
        // Scan runData for first node error
        if let runData = resultData["runData"] as? [String: Any] {
            for (nodeName, runs) in runData {
                if let runs = runs as? [[String: Any]],
                   let run = runs.first,
                   let err = run["error"] as? [String: Any],
                   let msg = err["message"] as? String {
                    return "\(nodeName)\n\(msg)"
                }
            }
        }
        return nil
    }

    private func parseSuccessDetail(resultData: [String: Any]) -> String? {
        guard let lastNode = resultData["lastNodeExecuted"] as? String,
              let runData  = resultData["runData"] as? [String: Any],
              let nodeRuns = runData[lastNode] as? [[String: Any]],
              let run      = nodeRuns.first,
              let data     = run["data"] as? [String: Any],
              let main     = data["main"] as? [[[String: Any]]],
              let items    = main.first else { return nil }

        let count = items.count
        let header = "→ \(lastNode) · \(count) item\(count == 1 ? "" : "s")"

        // Preview first item's JSON keys (up to 4)
        if let firstItem = items.first,
           let jsonObj = firstItem["json"] as? [String: Any], !jsonObj.isEmpty {
            let lines = jsonObj.prefix(4).map { "\($0.key): \(fmtValue($0.value))" }
            return "\(header)\n\(lines.joined(separator: "\n"))"
        }
        return header
    }

    private func fmtValue(_ v: Any) -> String {
        if let s = v as? String  { return String(s.prefix(50)) }
        if let n = v as? NSNumber { return n.stringValue }
        if let a = v as? [Any]   { return "[\(a.count)]" }
        if v is [String: Any]    { return "{…}" }
        return "\(v)"
    }

    // MARK: - Dispatch to main

    private func dispatch(success: Bool, name: String, detail: String?, generation: Int) {
        DispatchQueue.main.async {
            guard self.gate.isCurrent(generation) else { return }
            self.handleExecution(success: success, name: name, detail: detail)
        }
    }

    @MainActor
    private func handleExecution(success: Bool, name: String, detail: String?) {
        let state = AppState.shared

        // Apply workflow filter (empty = all workflows)
        if !state.n8nWorkflowFilter.isEmpty && !state.n8nWorkflowFilter.contains(name) { return }

        state.n8nRuns = Array(([N8nRun(workflow: name, detail: detail, success: success, date: Date())]
                               + state.n8nRuns).prefix(10))

        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_n8n" }) else { return }
        let focused = state.focusId == "integration_n8n"

        state.tasks[idx].state = success ? .finished : .error
        state.tasks[idx].steps = detail != nil ? [name, detail!] : [name]

        if !focused {
            state.tasks[idx].pillBadge = success ? .finished : .error
        }
        SoundEngine.shared.play(success ? "finish" : "error")

        // Auto-clear after 60s (user needs time to read detail)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == "integration_n8n" }) else { return }
            guard state.tasks[i].state == .finished || state.tasks[i].state == .error else { return }
            state.tasks[i].state    = .idle
            state.tasks[i].steps    = []
            state.tasks[i].pillBadge = nil
        }
    }

    // MARK: - Logging

    private func n8nLog(_ message: String) {
        appendAppLog("n8n.log", message, timestampFormat: "HH:mm:ss")
    }
}
