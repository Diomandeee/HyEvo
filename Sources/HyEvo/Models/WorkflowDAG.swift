import Foundation

// MARK: - Workflow Node Type

/// HyEvo hybrid nodes: LLM for semantic reasoning, Code for deterministic execution.
enum WorkflowNodeType: String, Codable, Sendable {
    case llm   = "llm"    // Probabilistic LLM inference (prompt-based)
    case code  = "code"   // Deterministic code execution (scripts, tests, lint)

    var icon: String {
        switch self {
        case .llm:  return "brain.head.profile"
        case .code: return "terminal.fill"
        }
    }

    var label: String {
        switch self {
        case .llm:  return "LLM"
        case .code: return "Code"
        }
    }

    var color: String {
        switch self {
        case .llm:  return "8B5CF6"  // violet
        case .code: return "06B6D4"  // cyan
        }
    }
}

// MARK: - Workflow Node

/// A single node in the workflow DAG — either an LLM prompt or a code script.
struct WorkflowNode: Identifiable, Codable, Sendable, Hashable {
    let id: String
    var label: String
    var type: WorkflowNodeType
    var content: String               // Prompt template (LLM) or script body (Code)
    var model: String?                // For LLM nodes: which model to target
    var timeout: TimeInterval         // Max execution time in seconds
    var retries: Int                  // Retry count on failure

    /// Runtime state (not serialized for genome)
    var status: NodeStatus
    var output: String?
    var latencyMs: Int?
    var tokenCost: Int?               // LLM token usage

    enum NodeStatus: String, Codable, Sendable {
        case pending    = "pending"
        case running    = "running"
        case complete   = "complete"
        case failed     = "failed"
        case skipped    = "skipped"
    }

    init(
        id: String = UUID().uuidString,
        label: String,
        type: WorkflowNodeType,
        content: String,
        model: String? = nil,
        timeout: TimeInterval = 120,
        retries: Int = 1
    ) {
        self.id = id
        self.label = label
        self.type = type
        self.content = content
        self.model = model
        self.timeout = timeout
        self.retries = retries
        self.status = .pending
        self.output = nil
        self.latencyMs = nil
        self.tokenCost = nil
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: WorkflowNode, rhs: WorkflowNode) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Workflow Edge

/// Directed dependency edge between nodes in the DAG.
struct WorkflowEdge: Identifiable, Codable, Sendable, Hashable {
    let id: String
    let sourceId: String              // Upstream node
    let targetId: String              // Downstream node (runs after source completes)
    var condition: EdgeCondition      // When to traverse this edge

    enum EdgeCondition: String, Codable, Sendable {
        case always    = "always"     // Always follow
        case onSuccess = "on_success" // Only if source succeeds
        case onFailure = "on_failure" // Only if source fails
    }

    init(
        id: String = UUID().uuidString,
        from sourceId: String,
        to targetId: String,
        condition: EdgeCondition = .onSuccess
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.condition = condition
    }
}

// MARK: - Workflow DAG

/// A complete directed acyclic graph of hybrid LLM + Code nodes.
/// This is the executable workflow topology that HyEvo evolves.
struct WorkflowDAG: Identifiable, Codable, Sendable {
    let id: String
    var name: String
    var nodes: [WorkflowNode]
    var edges: [WorkflowEdge]
    var generation: Int               // Which evolutionary generation produced this
    var fitness: Double               // Quality score from evaluation (0.0 - 1.0)
    var efficiency: Double            // Cost efficiency (lower token/time usage = higher)
    var featureVector: [Double]       // MAP-Elites feature descriptor for diversity
    var createdAt: Date
    var parentIds: [String]           // Which DAGs this was bred from (crossover lineage)

    init(
        id: String = UUID().uuidString,
        name: String = "workflow",
        nodes: [WorkflowNode] = [],
        edges: [WorkflowEdge] = [],
        generation: Int = 0
    ) {
        self.id = id
        self.name = name
        self.nodes = nodes
        self.edges = edges
        self.generation = generation
        self.fitness = 0
        self.efficiency = 0
        self.featureVector = []
        self.createdAt = Date()
        self.parentIds = []
    }

    // MARK: - DAG Properties

    /// Entry nodes (no incoming edges).
    var entryNodes: [WorkflowNode] {
        let targets = Set(edges.map(\.targetId))
        return nodes.filter { !targets.contains($0.id) }
    }

    /// Exit nodes (no outgoing edges).
    var exitNodes: [WorkflowNode] {
        let sources = Set(edges.map(\.sourceId))
        return nodes.filter { !sources.contains($0.id) }
    }

    /// Nodes that depend on the given node.
    func downstream(of nodeId: String) -> [WorkflowNode] {
        let targetIds = edges.filter { $0.sourceId == nodeId }.map(\.targetId)
        return nodes.filter { targetIds.contains($0.id) }
    }

    /// Nodes that the given node depends on.
    func upstream(of nodeId: String) -> [WorkflowNode] {
        let sourceIds = edges.filter { $0.targetId == nodeId }.map(\.sourceId)
        return nodes.filter { sourceIds.contains($0.id) }
    }

    /// Pre-built incoming edge index for O(1) dependency lookups in canExecute.
    private var incomingEdges: [String: [(sourceId: String, condition: WorkflowEdge.EdgeCondition)]] {
        var idx: [String: [(String, WorkflowEdge.EdgeCondition)]] = [:]
        for edge in edges {
            idx[edge.targetId, default: []].append((edge.sourceId, edge.condition))
        }
        return idx
    }

    /// Node lookup by ID for O(1) status checks.
    private var nodeIndex: [String: WorkflowNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    /// Whether all upstream dependencies of a node are complete.
    func canExecute(_ nodeId: String) -> Bool {
        let incoming = incomingEdges[nodeId] ?? []
        let lookup = nodeIndex
        return incoming.allSatisfy { (sourceId, condition) in
            guard let source = lookup[sourceId] else { return true }
            switch condition {
            case .always:    return source.status == .complete || source.status == .failed
            case .onSuccess: return source.status == .complete
            case .onFailure: return source.status == .failed
            }
        }
    }

    /// Topological depth (longest path from entry to exit).
    var depth: Int {
        var memo: [String: Int] = [:]
        func depthOf(_ nodeId: String) -> Int {
            if let cached = memo[nodeId] { return cached }
            let parents = upstream(of: nodeId)
            let d = parents.isEmpty ? 0 : parents.map { depthOf($0.id) }.max()! + 1
            memo[nodeId] = d
            return d
        }
        return nodes.map { depthOf($0.id) }.max() ?? 0
    }

    /// Total node count by type.
    var llmNodeCount: Int { nodes.filter { $0.type == .llm }.count }
    var codeNodeCount: Int { nodes.filter { $0.type == .code }.count }

    /// Overall DAG execution progress.
    var progress: Double {
        guard !nodes.isEmpty else { return 0 }
        let done = nodes.filter { $0.status == .complete || $0.status == .skipped }.count
        return Double(done) / Double(nodes.count)
    }

    /// Total token cost across all LLM nodes.
    var totalTokenCost: Int {
        nodes.compactMap(\.tokenCost).reduce(0, +)
    }

    /// Total latency across critical path.
    var totalLatencyMs: Int {
        nodes.compactMap(\.latencyMs).reduce(0, +)
    }

    // MARK: - Feature Vector

    /// Compute the MAP-Elites feature vector for this DAG.
    /// Dimensions: [llmRatio, normalizedDepth, edgeDensity, rawDepth]
    /// rawDepth (index 3) is included so callers can read it without recomputing.
    mutating func computeFeatureVector() {
        guard !nodes.isEmpty else {
            featureVector = [0, 0, 0, 0]
            return
        }
        let llmRatio = Double(llmNodeCount) / Double(nodes.count)
        let depthVal = depth  // compute once
        let normalizedDepth = min(Double(depthVal) / 10.0, 1.0)
        let maxEdges = Double(nodes.count * (nodes.count - 1)) / 2.0
        let edgeDensity = maxEdges > 0 ? Double(edges.count) / maxEdges : 0
        featureVector = [llmRatio, normalizedDepth, edgeDensity, Double(depthVal)]
    }

    // MARK: - Validation

    /// Check for cycles using iterative DFS (fix P1 — no stack overflow risk).
    var isAcyclic: Bool {
        // Build adjacency list once for O(1) lookups
        var adj: [String: [String]] = [:]
        for edge in edges {
            adj[edge.sourceId, default: []].append(edge.targetId)
        }

        var visited = Set<String>()
        var inStack = Set<String>()

        for node in nodes {
            guard !visited.contains(node.id) else { continue }

            // Iterative DFS with explicit stack: (nodeId, childIteratorIndex)
            var dfsStack: [(id: String, childIdx: Int)] = [(node.id, 0)]
            inStack.insert(node.id)

            while !dfsStack.isEmpty {
                let (currentId, childIdx) = dfsStack.last!
                let children = adj[currentId] ?? []

                if childIdx < children.count {
                    // Advance iterator
                    dfsStack[dfsStack.count - 1].childIdx += 1
                    let childId = children[childIdx]

                    if inStack.contains(childId) {
                        return false // cycle detected
                    }
                    if !visited.contains(childId) {
                        inStack.insert(childId)
                        dfsStack.append((childId, 0))
                    }
                } else {
                    // All children processed — backtrack
                    visited.insert(currentId)
                    inStack.remove(currentId)
                    dfsStack.removeLast()
                }
            }
        }
        return true
    }
}

// MARK: - Seed Workflows

extension WorkflowDAG {
    /// Default seed DAG matching the current linear pipeline: Skill → Review → Build
    static func linearSeed(appId: String) -> WorkflowDAG {
        let analyze = WorkflowNode(
            label: "Analyze Codebase",
            type: .code,
            content: "swift build 2>&1 | tail -20; swiftlint lint --quiet 2>&1 | head -30"
        )
        let plan = WorkflowNode(
            label: "Generate Plan",
            type: .llm,
            content: "Analyze the codebase structure and generate a prioritized task list for improvements."
        )
        let implement = WorkflowNode(
            label: "Implement Changes",
            type: .llm,
            content: "Implement the highest-priority tasks from the plan. Write clean, tested code."
        )
        let test = WorkflowNode(
            label: "Run Tests",
            type: .code,
            content: "swift test 2>&1"
        )
        let review = WorkflowNode(
            label: "Adversarial Review",
            type: .llm,
            content: "Review all changes for bugs, security issues, and quality. Generate issue list.",
            model: "codex"
        )
        let fix = WorkflowNode(
            label: "Apply Fixes",
            type: .llm,
            content: "Apply fixes for all critical and high-severity issues from the review."
        )
        let finalTest = WorkflowNode(
            label: "Final Validation",
            type: .code,
            content: "swift build && swift test 2>&1"
        )

        let edges = [
            WorkflowEdge(from: analyze.id, to: plan.id),
            WorkflowEdge(from: plan.id, to: implement.id),
            WorkflowEdge(from: implement.id, to: test.id),
            WorkflowEdge(from: test.id, to: review.id),
            WorkflowEdge(from: review.id, to: fix.id),
            WorkflowEdge(from: fix.id, to: finalTest.id),
        ]

        return WorkflowDAG(
            name: "\(appId)-linear-seed",
            nodes: [analyze, plan, implement, test, review, fix, finalTest],
            edges: edges,
            generation: 0
        )
    }

    /// Parallel seed: analyze + lint run concurrently, then merge into planning
    static func parallelSeed(appId: String) -> WorkflowDAG {
        let buildCheck = WorkflowNode(
            label: "Build Check",
            type: .code,
            content: "swift build 2>&1 | tail -20"
        )
        let lintCheck = WorkflowNode(
            label: "Lint Check",
            type: .code,
            content: "swiftlint lint --quiet 2>&1 | head -50"
        )
        let depScan = WorkflowNode(
            label: "Dependency Scan",
            type: .code,
            content: "swift package show-dependencies 2>&1"
        )
        let synthesize = WorkflowNode(
            label: "Synthesize Analysis",
            type: .llm,
            content: "Given build output, lint results, and dependency info, synthesize a prioritized improvement plan."
        )
        let implement = WorkflowNode(
            label: "Parallel Implement",
            type: .llm,
            content: "Implement the top 5 improvements. Focus on code quality and test coverage."
        )
        let validate = WorkflowNode(
            label: "Validate",
            type: .code,
            content: "swift build && swift test 2>&1"
        )
        let review = WorkflowNode(
            label: "Review",
            type: .llm,
            content: "Final review: check for regressions, security issues, and code quality.",
            model: "codex"
        )

        let edges = [
            // Parallel fan-out
            WorkflowEdge(from: buildCheck.id, to: synthesize.id),
            WorkflowEdge(from: lintCheck.id, to: synthesize.id),
            WorkflowEdge(from: depScan.id, to: synthesize.id),
            // Sequential after merge
            WorkflowEdge(from: synthesize.id, to: implement.id),
            WorkflowEdge(from: implement.id, to: validate.id),
            WorkflowEdge(from: validate.id, to: review.id),
        ]

        return WorkflowDAG(
            name: "\(appId)-parallel-seed",
            nodes: [buildCheck, lintCheck, depScan, synthesize, implement, validate, review],
            edges: edges,
            generation: 0
        )
    }

    /// Iterative refinement seed: tight loop of implement → test → fix
    static func iterativeSeed(appId: String) -> WorkflowDAG {
        let analyze = WorkflowNode(
            label: "Quick Analyze",
            type: .code,
            content: "swift build 2>&1 | tail -10"
        )
        let plan = WorkflowNode(
            label: "Micro Plan",
            type: .llm,
            content: "Generate exactly 3 focused improvements. Be specific and actionable."
        )
        let impl1 = WorkflowNode(
            label: "Implement Round 1",
            type: .llm,
            content: "Implement improvement #1 from the plan."
        )
        let test1 = WorkflowNode(
            label: "Test Round 1",
            type: .code,
            content: "swift build && swift test 2>&1"
        )
        let impl2 = WorkflowNode(
            label: "Implement Round 2",
            type: .llm,
            content: "Implement improvement #2 from the plan."
        )
        let test2 = WorkflowNode(
            label: "Test Round 2",
            type: .code,
            content: "swift build && swift test 2>&1"
        )
        let impl3 = WorkflowNode(
            label: "Implement Round 3",
            type: .llm,
            content: "Implement improvement #3 from the plan."
        )
        let finalCheck = WorkflowNode(
            label: "Final Check",
            type: .code,
            content: "swift build && swift test 2>&1"
        )

        let edges = [
            WorkflowEdge(from: analyze.id, to: plan.id),
            WorkflowEdge(from: plan.id, to: impl1.id),
            WorkflowEdge(from: impl1.id, to: test1.id),
            WorkflowEdge(from: test1.id, to: impl2.id),
            WorkflowEdge(from: impl2.id, to: test2.id),
            WorkflowEdge(from: test2.id, to: impl3.id),
            WorkflowEdge(from: impl3.id, to: finalCheck.id),
        ]

        return WorkflowDAG(
            name: "\(appId)-iterative-seed",
            nodes: [analyze, plan, impl1, test1, impl2, test2, impl3, finalCheck],
            edges: edges,
            generation: 0
        )
    }
}
