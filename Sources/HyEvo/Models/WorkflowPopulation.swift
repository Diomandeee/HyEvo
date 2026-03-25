import Foundation

// MARK: - MAP-Elites Grid Cell

/// A cell in the MAP-Elites feature grid. Stores the best workflow for this niche.
struct MAPElitesCell: Codable, Sendable {
    let featureKey: String            // Discretized feature vector key (e.g., "0.6-0.3-0.2")
    var workflow: WorkflowDAG
    var fitness: Double
    var visitCount: Int               // How many times this cell has been updated

    init(workflow: WorkflowDAG) {
        var w = workflow
        w.computeFeatureVector()
        self.featureKey = MAPElitesCell.key(for: w.featureVector)
        self.workflow = w
        self.fitness = w.fitness
        self.visitCount = 1
    }

    /// Discretize a continuous feature vector into grid coordinates.
    /// Each dimension is bucketed into 5 bins (0.0-0.2, 0.2-0.4, ...).
    static func key(for features: [Double]) -> String {
        features.map { String(format: "%.1f", (Double(Int($0 * 5)) / 5.0)) }.joined(separator: "-")
    }
}

// MARK: - Island

/// A single island in the multi-island evolutionary strategy.
/// Each island maintains its own MAP-Elites grid and evolves independently,
/// with occasional migration between islands.
struct EvolutionIsland: Identifiable, Codable, Sendable {
    let id: String
    var name: String
    var grid: [String: MAPElitesCell]   // Feature key → best workflow
    var generation: Int
    var bestFitness: Double
    var strategy: MutationStrategy

    enum MutationStrategy: String, Codable, Sendable, CaseIterable {
        case addNode       = "add_node"        // Insert a new node into the DAG
        case removeNode    = "remove_node"     // Remove a low-impact node
        case swapType      = "swap_type"       // LLM ↔ Code node type swap
        case rewireEdge    = "rewire_edge"     // Change edge connections
        case mutateContent = "mutate_content"  // Modify node prompt/script
        case crossover     = "crossover"       // Merge two DAGs

        var label: String {
            switch self {
            case .addNode:       return "Add Node"
            case .removeNode:    return "Remove Node"
            case .swapType:      return "Swap Type"
            case .rewireEdge:    return "Rewire Edge"
            case .mutateContent: return "Mutate Content"
            case .crossover:     return "Crossover"
            }
        }

        var icon: String {
            switch self {
            case .addNode:       return "plus.circle"
            case .removeNode:    return "minus.circle"
            case .swapType:      return "arrow.left.arrow.right"
            case .rewireEdge:    return "arrow.triangle.swap"
            case .mutateContent: return "pencil.circle"
            case .crossover:     return "arrow.triangle.merge"
            }
        }
    }

    init(id: String = UUID().uuidString, name: String, strategy: MutationStrategy) {
        self.id = id
        self.name = name
        self.grid = [:]
        self.generation = 0
        self.bestFitness = 0
        self.strategy = strategy
    }

    /// Insert a workflow into the grid. Replaces existing if fitness is higher.
    mutating func insert(_ workflow: WorkflowDAG) {
        var w = workflow
        w.computeFeatureVector()
        let key = MAPElitesCell.key(for: w.featureVector)

        if let existing = grid[key] {
            if w.fitness > existing.fitness {
                grid[key] = MAPElitesCell(workflow: w)
                grid[key]?.visitCount = existing.visitCount + 1
            }
        } else {
            grid[key] = MAPElitesCell(workflow: w)
        }

        bestFitness = grid.values.map(\.fitness).max() ?? 0
    }

    /// Sample a random workflow from the grid for mutation.
    func sampleParent() -> WorkflowDAG? {
        guard !grid.isEmpty else { return nil }
        let cells = Array(grid.values)
        // Tournament selection: pick 3 random, return the best
        let candidates = (0..<min(3, cells.count)).compactMap { _ in cells.randomElement() }
        return candidates.max(by: { $0.fitness < $1.fitness })?.workflow
    }

    /// Get the elite (best fitness) workflow from this island.
    var elite: WorkflowDAG? {
        grid.values.max(by: { $0.fitness < $1.fitness })?.workflow
    }

    /// Coverage: fraction of feature space cells that are filled.
    var coverage: Double {
        // With 5 bins per 3 dimensions = 125 possible cells
        Double(grid.count) / 125.0
    }

    /// Diversity: variance in fitness across filled cells.
    var diversity: Double {
        let fitnesses = grid.values.map(\.fitness)
        guard fitnesses.count > 1 else { return 0 }
        let mean = fitnesses.reduce(0, +) / Double(fitnesses.count)
        let variance = fitnesses.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(fitnesses.count)
        return sqrt(variance)
    }
}

// MARK: - Population

/// Multi-island MAP-Elites population for HyEvo workflow evolution.
struct WorkflowPopulation: Identifiable, Codable, Sendable {
    let id: String
    let appId: String                     // Which app this population evolves workflows for
    var islands: [EvolutionIsland]
    var generation: Int
    var migrationInterval: Int            // Migrate elite between islands every N generations
    var reflections: [EvolutionReflection] // LLM-generated reflections on what works
    var globalBestFitness: Double
    var globalBestDAGId: String?
    var startedAt: Date
    var lastEvolvedAt: Date?

    init(appId: String, migrationInterval: Int = 5) {
        self.id = UUID().uuidString
        self.appId = appId
        self.generation = 0
        self.migrationInterval = migrationInterval
        self.reflections = []
        self.globalBestFitness = 0
        self.globalBestDAGId = nil
        self.startedAt = Date()
        self.lastEvolvedAt = nil

        // Create one island per mutation strategy (6 islands)
        self.islands = EvolutionIsland.MutationStrategy.allCases.enumerated().map { idx, strategy in
            EvolutionIsland(name: "Island-\(idx)", strategy: strategy)
        }
    }

    /// Seed the population with initial workflow topologies.
    mutating func seed(appId: String) {
        let seeds = [
            WorkflowDAG.linearSeed(appId: appId),
            WorkflowDAG.parallelSeed(appId: appId),
            WorkflowDAG.iterativeSeed(appId: appId),
        ]

        // Distribute seeds across islands
        for (i, seed) in seeds.enumerated() {
            for j in 0..<islands.count {
                var mutated = seed
                mutated.generation = 0
                // Give each seed a slight fitness variation so MAP-Elites has something to work with
                mutated.fitness = Double.random(in: 0.3...0.5)
                islands[j].insert(mutated)
            }
        }
    }

    /// Perform migration: copy elite from each island to all others.
    mutating func migrate() {
        let elites = islands.compactMap(\.elite)
        for i in 0..<islands.count {
            for elite in elites {
                islands[i].insert(elite)
            }
        }
    }

    /// Get the globally best workflow across all islands.
    var globalBest: WorkflowDAG? {
        islands.compactMap(\.elite).max(by: { $0.fitness < $1.fitness })
    }

    /// Total unique workflows across all islands.
    var totalWorkflows: Int {
        islands.reduce(0) { $0 + $1.grid.count }
    }

    /// Average coverage across islands.
    var averageCoverage: Double {
        guard !islands.isEmpty else { return 0 }
        return islands.reduce(0) { $0 + $1.coverage } / Double(islands.count)
    }

    /// Average diversity across islands.
    var averageDiversity: Double {
        guard !islands.isEmpty else { return 0 }
        return islands.reduce(0) { $0 + $1.diversity } / Double(islands.count)
    }
}

// MARK: - Evolution Reflection

/// LLM-generated reflection on workflow execution — the "reflect" in "reflect-then-generate".
struct EvolutionReflection: Identifiable, Codable, Sendable {
    let id: String
    let generation: Int
    let dagId: String                     // Which DAG was evaluated
    let fitness: Double
    let analysis: String                  // LLM analysis of what worked / didn't
    let suggestions: [String]             // Specific topology improvements suggested
    let createdAt: Date

    init(
        generation: Int,
        dagId: String,
        fitness: Double,
        analysis: String,
        suggestions: [String]
    ) {
        self.id = UUID().uuidString
        self.generation = generation
        self.dagId = dagId
        self.fitness = fitness
        self.analysis = analysis
        self.suggestions = suggestions
        self.createdAt = Date()
    }
}

// MARK: - Mutation Operations

/// Pure functions for DAG mutations used by the evolutionary engine.
enum WorkflowMutations {
    /// Add a random node to the DAG, inserting it between two connected nodes.
    static func addNode(to dag: WorkflowDAG, type: WorkflowNodeType? = nil) -> WorkflowDAG {
        var mutated = dag
        let nodeType = type ?? (Bool.random() ? .llm : .code)
        let newNode = WorkflowNode(
            label: nodeType == .llm ? "Evolved LLM Step" : "Evolved Code Check",
            type: nodeType,
            content: nodeType == .llm
                ? "Analyze and improve the output from the previous step."
                : "echo 'validation check'"
        )

        mutated.nodes.append(newNode)

        // Insert between a random existing edge
        if let edge = mutated.edges.randomElement(),
           let edgeIdx = mutated.edges.firstIndex(where: { $0.id == edge.id }) {
            let newEdge1 = WorkflowEdge(from: edge.sourceId, to: newNode.id)
            let newEdge2 = WorkflowEdge(from: newNode.id, to: edge.targetId)
            mutated.edges.remove(at: edgeIdx)
            mutated.edges.append(contentsOf: [newEdge1, newEdge2])
        } else if let lastNode = mutated.nodes.dropLast().last {
            // No edges: connect to last node
            mutated.edges.append(WorkflowEdge(from: lastNode.id, to: newNode.id))
        }

        mutated.generation = dag.generation + 1
        mutated.parentIds = [dag.id]
        return mutated
    }

    /// Remove a random non-entry, non-exit node from the DAG.
    static func removeNode(from dag: WorkflowDAG) -> WorkflowDAG {
        guard dag.nodes.count > 2 else { return dag }
        var mutated = dag

        // Pick a random non-entry, non-exit node
        let entryIds = Set(mutated.entryNodes.map(\.id))
        let exitIds = Set(mutated.exitNodes.map(\.id))
        let candidates = mutated.nodes.filter { !entryIds.contains($0.id) && !exitIds.contains($0.id) }
        guard let victim = candidates.randomElement() else { return dag }

        // Rewire: connect all parents to all children
        let parentEdges = mutated.edges.filter { $0.targetId == victim.id }
        let childEdges = mutated.edges.filter { $0.sourceId == victim.id }
        let newEdges = parentEdges.flatMap { parent in
            childEdges.map { child in
                WorkflowEdge(from: parent.sourceId, to: child.targetId)
            }
        }

        mutated.nodes.removeAll { $0.id == victim.id }
        mutated.edges.removeAll { $0.sourceId == victim.id || $0.targetId == victim.id }
        mutated.edges.append(contentsOf: newEdges)
        mutated.generation = dag.generation + 1
        mutated.parentIds = [dag.id]
        return mutated
    }

    /// Swap a random node's type between LLM and Code.
    static func swapType(in dag: WorkflowDAG) -> WorkflowDAG {
        guard !dag.nodes.isEmpty else { return dag }
        var mutated = dag
        let idx = Int.random(in: 0..<mutated.nodes.count)
        mutated.nodes[idx].type = mutated.nodes[idx].type == .llm ? .code : .llm
        mutated.nodes[idx].content = mutated.nodes[idx].type == .llm
            ? "Analyze and improve based on context."
            : "swift build 2>&1 | tail -10"
        mutated.generation = dag.generation + 1
        mutated.parentIds = [dag.id]
        return mutated
    }

    /// Rewire a random edge to a different target.
    static func rewireEdge(in dag: WorkflowDAG) -> WorkflowDAG {
        guard !dag.edges.isEmpty, dag.nodes.count > 2 else { return dag }
        var mutated = dag
        let edgeIdx = Int.random(in: 0..<mutated.edges.count)
        let edge = mutated.edges[edgeIdx]

        // Pick a new target that isn't the source or current target
        let candidates = mutated.nodes.filter { $0.id != edge.sourceId && $0.id != edge.targetId }
        guard let newTarget = candidates.randomElement() else { return dag }

        mutated.edges[edgeIdx] = WorkflowEdge(
            from: edge.sourceId,
            to: newTarget.id,
            condition: edge.condition
        )

        // Only accept if still acyclic
        if mutated.isAcyclic {
            mutated.generation = dag.generation + 1
            mutated.parentIds = [dag.id]
            return mutated
        }
        return dag // reject cyclic mutation
    }

    /// Crossover: merge topology from two parent DAGs.
    static func crossover(_ a: WorkflowDAG, _ b: WorkflowDAG) -> WorkflowDAG {
        var child = WorkflowDAG(
            name: "\(a.name)-x-\(b.name)",
            generation: max(a.generation, b.generation) + 1
        )

        // Take first half of nodes from parent A, second half from parent B
        let splitA = a.nodes.count / 2
        let splitB = b.nodes.count / 2
        let nodesA = Array(a.nodes.prefix(max(1, splitA)))
        let nodesB = Array(b.nodes.suffix(max(1, splitB)))
        child.nodes = nodesA + nodesB

        // Connect A's last to B's first
        let nodeIds = Set(child.nodes.map(\.id))

        // Keep valid edges from both parents
        let validEdgesA = a.edges.filter { nodeIds.contains($0.sourceId) && nodeIds.contains($0.targetId) }
        let validEdgesB = b.edges.filter { nodeIds.contains($0.sourceId) && nodeIds.contains($0.targetId) }
        child.edges = validEdgesA + validEdgesB

        // Bridge the two halves
        if let lastA = nodesA.last, let firstB = nodesB.first {
            child.edges.append(WorkflowEdge(from: lastA.id, to: firstB.id))
        }

        child.parentIds = [a.id, b.id]

        // Validate acyclic
        if child.isAcyclic {
            return child
        }
        // Fallback: return parent A mutated
        return addNode(to: a)
    }
}
