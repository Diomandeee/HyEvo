import Foundation
import Observation
import OSLog
import SharedServices

/// Orchestrates the Fleet Evolution Pipeline: Skill -> Adversarial Review -> Hydra
/// for every app in the fleet. Persists state to Supabase `app_evolution_tasks`.
@MainActor
@Observable
final class FleetEvolutionClient {
    static let shared = FleetEvolutionClient()

    // MARK: - State

    /// Per-app evolution state keyed by AppAgent.id
    var states: [String: AppEvolutionState] = [:]

    /// Currently selected app for detail view
    var selectedAppId: String?

    /// Queue of app IDs waiting to be processed
    var queue: [String] = []

    /// How many apps can run concurrently (bounded by machine availability)
    var maxConcurrent: Int = 3

    var isLoading = false
    var error: String?
    var lastSync: Date?

    // MARK: - Supabase Config

    private let supabaseURL: String = {
        ProcessInfo.processInfo.environment["SUPABASE_URL"] ?? "https://YOUR_PROJECT.supabase.co"
    }()
    private let supabaseKey: String = {
        ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] ?? ""
    }()

    private init() {}

    // MARK: - Fleet Operations

    /// Enqueue an app for evolution with a specific pipeline.
    func enqueue(appId: String, pipeline: EvolutionPipeline) {
        var state = AppEvolutionState(id: appId, pipeline: pipeline)
        state.stage = .queued
        states[appId] = state
        if !queue.contains(appId) {
            queue.append(appId)
        }
    }

    /// Enqueue an app using the recommended pipeline based on contract stage.
    func enqueueAuto(app: AppAgent) {
        let pipeline = EvolutionPipeline.recommended(for: app.contract.stage)
        enqueue(appId: app.id, pipeline: pipeline)
    }

    /// Enqueue all fleet apps that haven't been processed yet.
    func enqueueAll(fleet: [AppAgent]) {
        for app in fleet {
            let flat = flattenAgent(app)
            for a in flat {
                guard states[a.id] == nil else { continue }
                enqueueAuto(app: a)
            }
        }
    }

    /// Start processing the queue. Dispatches up to maxConcurrent apps.
    func processQueue() async {
        let active = states.values.filter { $0.isActive }.count
        let slots = max(0, maxConcurrent - active)
        guard slots > 0 else { return }

        let toStart = Array(queue.prefix(slots))
        queue.removeFirst(min(slots, queue.count))

        for appId in toStart {
            await startEvolution(appId: appId)
        }
    }

    /// Start the evolution pipeline for a single app.
    func startEvolution(appId: String) async {
        guard var state = states[appId] else { return }

        // HyEvo pipeline has its own entry point
        if state.pipeline == .hyevo {
            await startHyEvo(appId: appId)
            startHyEvoMonitor(appId: appId)
            return
        }

        state.startedAt = Date()
        state.stage = .skillRunning
        states[appId] = state

        // Dispatch the skill via AuraGateway
        let app = findApp(appId)
        let path = app?.iosPath ?? app?.webPath ?? "~/Desktop/\(appId)/"
        let expandedPath = path.hasPrefix("~/")
            ? NSHomeDirectory() + path.dropFirst(1)
            : path

        let prompt = buildSkillPrompt(state: state, path: expandedPath)
        await AuraGatewayClient.shared.spawn(
            prompt: "cd \(expandedPath) && claude --dangerously-skip-permissions -p \"\(prompt)\"",
            target: "auto",
            priority: 3
        )

        if let result = AuraGatewayClient.shared.lastDispatchResult {
            state.dispatchTaskId = result.taskId
            state.dispatchMachine = result.target
        }
        states[appId] = state

        // Persist to Supabase
        await syncStateToSupabase(state)
    }

    /// Advance an app to the next stage (called when a stage completes).
    func advance(appId: String) async {
        guard var state = states[appId] else { return }

        switch state.stage {
        case .queued:
            state.stage = .skillRunning

        case .skillRunning:
            state.stage = .skillComplete

        case .skillComplete:
            if state.pipeline == .hyevo {
                state.stage = .hyevoSeeding
            } else {
                state.stage = .adversarialPending
            }

        // HyEvo stages advance via the monitor loop, but manual advance is supported
        case .hyevoSeeding:
            state.stage = .hyevoExecuting
        case .hyevoExecuting:
            state.stage = .hyevoReflecting
        case .hyevoReflecting:
            state.stage = .hyevoEvolving
        case .hyevoEvolving:
            state.hyevoGeneration += 1
            if state.hyevoGeneration >= state.hyevoMaxGenerations {
                state.stage = .adversarialPending
            } else {
                state.stage = .hyevoExecuting
            }
        case .hyevoMigrating:
            state.stage = .hyevoExecuting

        case .adversarialPending:
            state.stage = .adversarialRunning
            await dispatchAdversarialReview(state: &state)

        case .adversarialRunning:
            state.adversarialRounds += 1
            if state.adversarialRounds >= state.adversarialMaxRounds {
                state.stage = .adversarialComplete
            }

        case .adversarialComplete:
            state.stage = .hydraBuild
            state.hydraCycle = 1
            await dispatchHydra(state: &state)
            states[appId] = state
            startHydraMonitor(appId: appId)
            return

        case .hydraBuild:
            state.stage = .hydraAudit
        case .hydraAudit:
            state.stage = .hydraIncubate
        case .hydraIncubate:
            state.stage = .hydraRefine
        case .hydraRefine:
            state.stage = .hydraDispatch
        case .hydraDispatch:
            // Check if quality gate passes or cycle again
            state.hydraCycle += 1
            if state.hydraCycle > state.hydraMaxCycles {
                state.stage = .complete
                state.completedAt = Date()
            } else {
                state.stage = .hydraBuild
            }

        case .complete, .failed:
            break
        }

        states[appId] = state
        await syncStateToSupabase(state)
    }

    /// Mark an app's evolution as complete (Hydra quality gate passed).
    func markComplete(appId: String) async {
        guard var state = states[appId] else { return }
        state.stage = .complete
        state.completedAt = Date()
        states[appId] = state
        await syncStateToSupabase(state)

        // Auto-process next in queue
        await processQueue()
    }

    /// Mark an app as failed with error message.
    func markFailed(appId: String, error: String) async {
        guard var state = states[appId] else { return }
        state.stage = .failed
        state.error = error
        states[appId] = state
        await syncStateToSupabase(state)
    }

    /// Add a task to an app's evolution task list.
    func addTask(appId: String, description: String, priority: Int, source: EvolutionTask.TaskSource) async {
        guard var state = states[appId] else { return }
        let task = EvolutionTask(
            id: UUID().uuidString,
            appId: appId,
            description: description,
            priority: priority,
            source: source,
            status: .pending,
            createdAt: Date()
        )
        state.tasks.append(task)
        states[appId] = state
        await syncTaskToSupabase(task)
    }

    /// Complete a task.
    func completeTask(appId: String, taskId: String) async {
        guard var state = states[appId],
              let idx = state.tasks.firstIndex(where: { $0.id == taskId }) else { return }
        state.tasks[idx].status = .complete
        state.tasks[idx].completedAt = Date()
        states[appId] = state
        await updateTaskInSupabase(state.tasks[idx])
    }

    // MARK: - HyEvo Population Store

    /// Per-app HyEvo populations (in-memory, synced to Supabase)
    var populations: [String: WorkflowPopulation] = [:]

    /// Active DAGs being executed
    var activeDAGs: [String: WorkflowDAG] = [:]

    // MARK: - HyEvo Pipeline

    /// Start HyEvo evolution for an app: seed population, then enter evolution loop.
    func startHyEvo(appId: String) async {
        guard var state = states[appId], state.pipeline == .hyevo else { return }

        // Phase 1: Seeding
        state.stage = .hyevoSeeding
        state.startedAt = Date()
        states[appId] = state

        var population = WorkflowPopulation(appId: appId)
        population.seed(appId: appId)
        populations[appId] = population

        state.hyevoPopulationId = population.id
        state.hyevoIslandCount = population.islands.count
        state.hyevoTotalWorkflows = population.totalWorkflows
        state.stage = .hyevoExecuting
        states[appId] = state

        // Execute the initial best DAG
        if let bestDAG = population.globalBest {
            activeDAGs[appId] = bestDAG
            state.hyevoActiveDAGId = bestDAG.id
            states[appId] = state
            await executeDAG(appId: appId, dag: bestDAG)
        }
    }

    /// Execute a workflow DAG by dispatching each node via the mesh.
    func executeDAG(appId: String, dag: WorkflowDAG) async {
        var executingDAG = dag
        let app = findApp(appId)
        let path = app?.iosPath ?? app?.webPath ?? "~/Desktop/\(appId)/"

        // Execute nodes in topological order
        var completed = Set<String>()
        while completed.count < executingDAG.nodes.count {
            // Find ready nodes (all dependencies satisfied)
            let ready = executingDAG.nodes.filter { node in
                node.status == .pending && executingDAG.canExecute(node.id)
            }

            guard !ready.isEmpty else {
                // Check if we're stuck (all remaining nodes are blocked)
                let pending = executingDAG.nodes.filter { $0.status == .pending }
                if !pending.isEmpty {
                    log.warning("HyEvo DAG stuck: \(pending.count) nodes can't execute for \(appId)")
                }
                break
            }

            // Dispatch all ready nodes concurrently
            for node in ready {
                guard let idx = executingDAG.nodes.firstIndex(where: { $0.id == node.id }) else { continue }
                executingDAG.nodes[idx].status = .running

                switch node.type {
                case .llm:
                    await AuraGatewayClient.shared.spawn(
                        prompt: "cd \(path) && claude --dangerously-skip-permissions -p \"\(node.content)\"",
                        target: node.model == "codex" ? "mac4" : "auto",
                        priority: 3
                    )
                case .code:
                    await AuraGatewayClient.shared.dispatch(
                        command: "cd \(path) && \(node.content)",
                        target: "auto",
                        priority: 2
                    )
                }

                executingDAG.nodes[idx].status = .complete
                completed.insert(node.id)
            }

            activeDAGs[appId] = executingDAG
        }

        // DAG execution complete — score fitness using HyEvo's weighted formula:
        // R(G) = λ₁·S_q + λ₂·U(C_q) + λ₃·U(T_q)
        // where U(x) = 1/(1 + α·x), λ₁=0.9, λ₂=0.05, λ₃=0.05
        let lambda1 = 0.9   // quality weight
        let lambda2 = 0.05  // cost weight
        let lambda3 = 0.05  // latency weight
        let alpha = 0.001   // normalization constant

        let completedCount = executingDAG.nodes.filter { $0.status == .complete }.count
        let qualityScore = Double(completedCount) / Double(max(1, executingDAG.nodes.count))
        let costUtility = 1.0 / (1.0 + alpha * Double(executingDAG.totalTokenCost))
        let latencyUtility = 1.0 / (1.0 + alpha * Double(executingDAG.totalLatencyMs))

        executingDAG.fitness = lambda1 * qualityScore + lambda2 * costUtility + lambda3 * latencyUtility
        executingDAG.efficiency = costUtility
        executingDAG.computeFeatureVector()
        activeDAGs[appId] = executingDAG

        // Update population with fitness — insert into origin island + random other
        if var pop = populations[appId] {
            for i in 0..<pop.islands.count {
                pop.islands[i].insert(executingDAG)
            }
            pop.globalBestFitness = max(pop.globalBestFitness, executingDAG.fitness)
            pop.globalBestDAGId = pop.globalBest?.id
            populations[appId] = pop
        }
    }

    /// Reflect-then-generate: LLM analyzes execution feedback, then evolves the population.
    ///
    /// Phase 1 (Reflect): Dispatch reflection prompt to LLM via AuraGateway.
    /// The meta-agent receives the executed DAG's structure, node completion status,
    /// failure logs, and a reference elite, then produces a diagnosis + suggestions.
    ///
    /// Phase 2 (Generate): Apply mutations informed by the reflection to each island.
    func reflectAndEvolve(appId: String) async {
        guard var state = states[appId],
              var population = populations[appId],
              let executedDAG = activeDAGs[appId] else { return }

        // ── Phase 1: Reflect ──────────────────────────────────────────────
        state.stage = .hyevoReflecting
        states[appId] = state

        // Build the reflection prompt with DAG execution context
        let reflectionPrompt = buildReflectionPrompt(
            dag: executedDAG,
            elite: population.globalBest,
            generation: population.generation,
            appId: appId
        )

        // Dispatch reflection to LLM via AuraGateway
        await AuraGatewayClient.shared.spawn(
            prompt: reflectionPrompt,
            target: "auto",
            priority: 2
        )

        // Build reflection from execution data (LLM response parsed async by gateway)
        let failedNodes = executedDAG.nodes.filter { $0.status == .failed }
        let completedNodes = executedDAG.nodes.filter { $0.status == .complete }
        let failureAnalysis = failedNodes.isEmpty
            ? "All nodes completed successfully."
            : "Failed nodes: \(failedNodes.map(\.label).joined(separator: ", ")). " +
              "Check timeout settings and upstream dependencies."

        var suggestions: [String] = []
        // Heuristic suggestions based on execution pattern
        if executedDAG.codeNodeCount == 0 {
            suggestions.append("Add deterministic code validation nodes to offload work from LLM inference.")
        }
        if executedDAG.llmNodeCount > 4 {
            suggestions.append("Too many LLM nodes (\(executedDAG.llmNodeCount)). Convert format checks to code nodes for cost savings.")
        }
        if executedDAG.depth > 6 && executedDAG.entryNodes.count == 1 {
            suggestions.append("Deep sequential chain (depth \(executedDAG.depth)). Parallelize independent analysis steps.")
        }
        if !failedNodes.isEmpty {
            suggestions.append("Retry failed nodes with increased timeout or add fallback edges (onFailure condition).")
        }
        let hybridRatio = executedDAG.nodes.isEmpty ? 0 : Double(executedDAG.codeNodeCount) / Double(executedDAG.nodes.count)
        if hybridRatio < 0.2 {
            suggestions.append("Hybrid ratio low (\(Int(hybridRatio * 100))% code). Paper sweet spot is 30-50% code nodes.")
        }
        if suggestions.isEmpty {
            suggestions.append("Topology looks healthy. Try minor edge rewiring to explore nearby optima.")
        }

        let reflection = EvolutionReflection(
            generation: population.generation,
            dagId: executedDAG.id,
            fitness: executedDAG.fitness,
            analysis: "Gen \(population.generation): fitness \(String(format: "%.3f", executedDAG.fitness)). " +
                "\(completedNodes.count)/\(executedDAG.nodes.count) nodes completed. " +
                "LLM/Code: \(executedDAG.llmNodeCount)/\(executedDAG.codeNodeCount). " +
                "Depth: \(executedDAG.depth). \(failureAnalysis)",
            suggestions: suggestions
        )
        population.reflections.append(reflection)

        // ── Phase 2: Evolve ──────────────────────────────────────────────
        state.stage = .hyevoEvolving
        states[appId] = state

        // Parent selection per paper: 50% elite, 30% history, 20% cross-island
        for i in 0..<population.islands.count {
            let roll = Double.random(in: 0...1)
            let parent: WorkflowDAG?
            if roll < 0.5 {
                // 50%: sample from elite archive
                parent = population.islands[i].elite
            } else if roll < 0.8 {
                // 30%: sample from local history (tournament selection)
                parent = population.islands[i].sampleParent()
            } else {
                // 20%: cross-island (global)
                let otherIdx = (i + Int.random(in: 1..<max(2, population.islands.count))) % population.islands.count
                parent = population.islands[otherIdx].sampleParent()
            }
            guard let parentDAG = parent else { continue }

            // Apply island-specific mutation strategy
            var child: WorkflowDAG
            switch population.islands[i].strategy {
            case .addNode:
                // Reflection-guided: add code node if suggestions say so, else random
                let preferCode = suggestions.contains(where: { $0.contains("code") })
                child = WorkflowMutations.addNode(to: parentDAG, type: preferCode ? .code : nil)
            case .removeNode:
                child = WorkflowMutations.removeNode(from: parentDAG)
            case .swapType:
                child = WorkflowMutations.swapType(in: parentDAG)
            case .rewireEdge:
                child = WorkflowMutations.rewireEdge(in: parentDAG)
            case .mutateContent:
                // Content mutation: dispatch to LLM for prompt/script refinement
                child = await mutateContent(dag: parentDAG, appId: appId, reflection: reflection)
            case .crossover:
                let otherIdx = (i + 1) % population.islands.count
                if let other = population.islands[otherIdx].sampleParent() {
                    child = WorkflowMutations.crossover(parentDAG, other)
                } else {
                    child = WorkflowMutations.addNode(to: parentDAG)
                }
            }
            population.islands[i].insert(child)
            population.islands[i].generation += 1
        }

        population.generation += 1

        // Ring migration (per paper: every 15 iterations)
        if population.generation % population.migrationInterval == 0 {
            state.stage = .hyevoMigrating
            states[appId] = state
            population.migrate()
            log.info("HyEvo migration at gen \(population.generation) for \(appId)")
        }

        // Update state
        state.hyevoGeneration = population.generation
        state.hyevoBestFitness = population.globalBest?.fitness ?? 0
        state.hyevoTotalWorkflows = population.totalWorkflows
        state.hyevoActiveDAGId = population.globalBest?.id

        // Check termination
        if population.generation >= state.hyevoMaxGenerations {
            state.stage = .adversarialPending
            log.info("HyEvo complete for \(appId) at gen \(population.generation), best fitness \(state.hyevoBestFitness)")
        } else {
            state.stage = .hyevoExecuting
        }

        populations[appId] = population
        population.lastEvolvedAt = Date()
        states[appId] = state
        await syncStateToSupabase(state)
        await syncDAGToSupabase(executedDAG, appId: appId)
        await syncReflectionToSupabase(reflection, appId: appId)
    }

    /// Build the reflection prompt for the meta-agent.
    private func buildReflectionPrompt(dag: WorkflowDAG, elite: WorkflowDAG?, generation: Int, appId: String) -> String {
        let nodeList = dag.nodes.map { node in
            "  - [\(node.type.label)] \(node.label): status=\(node.status.rawValue)" +
            (node.latencyMs.map { ", latency=\($0)ms" } ?? "") +
            (node.tokenCost.map { ", tokens=\($0)" } ?? "")
        }.joined(separator: "\n")

        let edgeList = dag.edges.map { edge in
            let src = dag.nodes.first { $0.id == edge.sourceId }?.label ?? edge.sourceId
            let tgt = dag.nodes.first { $0.id == edge.targetId }?.label ?? edge.targetId
            return "  - \(src) → \(tgt) [\(edge.condition.rawValue)]"
        }.joined(separator: "\n")

        let eliteInfo: String
        if let elite {
            eliteInfo = "Best elite: fitness=\(String(format: "%.3f", elite.fitness)), " +
                "\(elite.nodes.count) nodes (\(elite.llmNodeCount) LLM, \(elite.codeNodeCount) code), depth=\(elite.depth)"
        } else {
            eliteInfo = "No elite yet."
        }

        return """
        You are the HyEvo meta-agent for app '\(appId)'. Generation \(generation).

        EXECUTED WORKFLOW DAG (fitness: \(String(format: "%.3f", dag.fitness))):
        Nodes (\(dag.nodes.count)):
        \(nodeList)

        Edges (\(dag.edges.count)):
        \(edgeList)

        \(eliteInfo)

        TASK: Analyze this workflow execution. Identify structural bottlenecks, \
        unnecessary LLM calls that could be code nodes, missing validation steps, \
        and parallelization opportunities. Output a JSON block with your analysis \
        and suggested topology modifications.
        """
    }

    /// Content mutation: dispatch to LLM to refine a node's prompt or script.
    private func mutateContent(dag: WorkflowDAG, appId: String, reflection: EvolutionReflection) async -> WorkflowDAG {
        var mutated = dag
        guard !mutated.nodes.isEmpty else { return mutated }

        let idx = Int.random(in: 0..<mutated.nodes.count)
        let node = mutated.nodes[idx]

        // Dispatch content refinement to LLM
        let refinementPrompt = """
        Refine this \(node.type.label) node for app '\(appId)'.
        Current content: \(node.content)
        Reflection: \(reflection.suggestions.joined(separator: "; "))
        Generate an improved version of the node content. Be specific and actionable.
        """

        await AuraGatewayClient.shared.spawn(
            prompt: refinementPrompt,
            target: "auto",
            priority: 2
        )

        // For now, apply heuristic content improvements based on reflection
        if node.type == .llm && reflection.suggestions.contains(where: { $0.contains("code") }) {
            // Convert to a more focused prompt
            mutated.nodes[idx].content = node.content + " Focus on the single most impactful change."
        } else if node.type == .code {
            // Tighten the script
            mutated.nodes[idx].content = node.content + " && echo 'PASS'"
        }

        mutated.generation = dag.generation + 1
        mutated.parentIds = [dag.id]
        return mutated
    }

    // MARK: - HyEvo Supabase Sync

    private func syncDAGToSupabase(_ dag: WorkflowDAG, appId: String) async {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/hyevo_workflow_dags") else { return }

        let topology: [String: Any] = [
            "nodes": dag.nodes.map { [
                "id": $0.id, "label": $0.label, "type": $0.type.rawValue,
                "content": $0.content, "status": $0.status.rawValue
            ] },
            "edges": dag.edges.map { [
                "id": $0.id, "source": $0.sourceId, "target": $0.targetId,
                "condition": $0.condition.rawValue
            ] }
        ]

        let row: [String: Any] = [
            "id": dag.id,
            "app_id": appId,
            "name": dag.name,
            "generation": dag.generation,
            "fitness": dag.fitness,
            "efficiency": dag.efficiency,
            "feature_vector": dag.featureVector,
            "node_count": dag.nodes.count,
            "llm_node_count": dag.llmNodeCount,
            "code_node_count": dag.codeNodeCount,
            "edge_count": dag.edges.count,
            "depth": dag.depth,
            "total_token_cost": dag.totalTokenCost,
            "total_latency_ms": dag.totalLatencyMs,
            "topology": topology,
            "parent_ids": dag.parentIds
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: row) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        request.timeoutInterval = 8

        _ = try? await URLSession.shared.data(for: request)
    }

    private func syncReflectionToSupabase(_ reflection: EvolutionReflection, appId: String) async {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/hyevo_reflections") else { return }

        let row: [String: Any] = [
            "id": reflection.id,
            "app_id": appId,
            "generation": reflection.generation,
            "dag_id": reflection.dagId,
            "fitness": reflection.fitness,
            "analysis": reflection.analysis,
            "suggestions": reflection.suggestions
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: row) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        request.timeoutInterval = 8

        _ = try? await URLSession.shared.data(for: request)
    }

    /// Run one full HyEvo cycle: execute best DAG → reflect → evolve.
    func hyevoStep(appId: String) async {
        guard let state = states[appId], state.pipeline == .hyevo else { return }

        switch state.stage {
        case .hyevoExecuting:
            if let dag = populations[appId]?.globalBest {
                activeDAGs[appId] = dag
                await executeDAG(appId: appId, dag: dag)
                await reflectAndEvolve(appId: appId)
            }
        case .hyevoSeeding:
            await startHyEvo(appId: appId)
        default:
            await reflectAndEvolve(appId: appId)
        }
    }

    /// Start the HyEvo evolution monitor loop (runs generations until complete).
    func startHyEvoMonitor(appId: String) {
        Task { [weak self] in
            guard let self else { return }
            log.info("HyEvo monitor started for \(appId)")
            while let state = states[appId],
                  state.stage.phase == .hyevo {
                await hyevoStep(appId: appId)
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5s between generations
            }
            log.info("HyEvo monitor ended for \(appId) at generation \(states[appId]?.hyevoGeneration ?? 0)")
        }
    }

    // MARK: - Dispatch Helpers

    private func buildSkillPrompt(state: AppEvolutionState, path: String) -> String {
        let skill = state.pipeline.skillCommand
        return """
        \(skill) \(state.id) -- Analyze this app's codebase at \(path). \
        Generate a comprehensive task list for improvements, bugs, features, and polish. \
        Output tasks with priorities P1-P5. \
        At the end of your output, append EXACTLY this block: \
        <!-- EVOLUTION_TASKS_START --> \
        {"app_id": "\(state.id)", "tasks": [{"priority": 1, "description": "..."}]} \
        <!-- EVOLUTION_TASKS_END -->
        """
    }

    // MARK: - Hydra Bridge

    /// Polls Hydra quality gate while app is in Hydra phase (foreground only).
    /// Python orchestrator handles backgrounded polling via Prefect.
    func startHydraMonitor(appId: String) {
        Task { [weak self] in
            guard let self else { return }
            log.info("Hydra monitor started for \(appId)")
            while let state = states[appId], state.stage.phase == .hydra {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                await HydraClient.shared.refresh()
                let hydra = HydraClient.shared

                // Map Hydra phase → EvolutionStage
                let mapped = EvolutionStage.fromHydraPhase(hydra.currentPhase.rawValue, cycle: hydra.currentCycle)
                if var current = states[appId], current.stage != mapped {
                    current.stage = mapped
                    current.hydraCycle = hydra.currentCycle
                    states[appId] = current
                    // Note: Python orchestrator is the authoritative writer to Supabase.
                    // Swift updates UI immediately; DB stays consistent via Python.
                }

                if hydra.qualityGate.isPassing {
                    log.info("Hydra quality PASSING for \(appId) — updating UI")
                    if var current = states[appId] {
                        current.stage = .complete
                        current.completedAt = Date()
                        states[appId] = current
                    }
                    break
                }
            }
        }
    }

    private var log: Logger { Logger(subsystem: "MeshControl", category: "FleetEvolution") }


    private func dispatchAdversarialReview(state: inout AppEvolutionState) async {
        // Dispatch to Mac4 Codex for adversarial review
        let prompt = """
        Run adversarial review on app '\(state.id)'. \
        Review all code changes from the skill phase. \
        Generate ISSUE blocks with FILE/SEVERITY/FIX format. \
        Rounds: \(state.adversarialMaxRounds).
        """
        await AuraGatewayClient.shared.dispatch(
            command: prompt,
            target: "mac4",
            priority: 3,
            model: "codex"
        )
        if let result = AuraGatewayClient.shared.lastDispatchResult {
            state.dispatchTaskId = result.taskId
            state.dispatchMachine = "mac4"
        }
    }

    private func dispatchHydra(state: inout AppEvolutionState) async {
        let app = findApp(state.id)
        let name = app?.name ?? state.id
        await HydraClient.shared.start(subject: name)
    }

    // MARK: - Supabase Sync

    func fetchStatesFromSupabase() async {
        isLoading = true
        defer { isLoading = false }

        guard let url = URL(string: "\(supabaseURL)/rest/v1/app_evolution_states?select=*&order=started_at.desc") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            let rows = try JSONDecoder().decode([SupabaseEvolutionRow].self, from: data)
            for row in rows {
                states[row.app_id] = row.toState()
            }
            lastSync = Date()
        } catch {
            self.error = "Fetch failed: \(error.localizedDescription)"
        }
    }

    func fetchTasksFromSupabase(appId: String) async {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/app_evolution_tasks?app_id=eq.\(appId)&order=priority.asc,created_at.asc") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            let rows = try JSONDecoder().decode([SupabaseTaskRow].self, from: data)
            if var state = states[appId] {
                state.tasks = rows.map { $0.toTask() }
                states[appId] = state
            }
        } catch {}
    }

    private func syncStateToSupabase(_ state: AppEvolutionState) async {
        let row = SupabaseEvolutionRow.from(state)
        guard let url = URL(string: "\(supabaseURL)/rest/v1/app_evolution_states"),
              let body = try? JSONEncoder().encode(row) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        request.timeoutInterval = 8

        _ = try? await URLSession.shared.data(for: request)
    }

    private func syncTaskToSupabase(_ task: EvolutionTask) async {
        let row = SupabaseTaskRow.from(task)
        guard let url = URL(string: "\(supabaseURL)/rest/v1/app_evolution_tasks"),
              let body = try? JSONEncoder().encode(row) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = body
        request.timeoutInterval = 8

        _ = try? await URLSession.shared.data(for: request)
    }

    private func updateTaskInSupabase(_ task: EvolutionTask) async {
        guard let url = URL(string: "\(supabaseURL)/rest/v1/app_evolution_tasks?id=eq.\(task.id)"),
              let body = try? JSONEncoder().encode(SupabaseTaskRow.from(task)) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(supabaseKey)", forHTTPHeaderField: "Authorization")
        request.setValue(supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 8

        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Helpers

    private func findApp(_ id: String) -> AppAgent? {
        for agent in AppAgent.fleet {
            if agent.id == id { return agent }
            if let children = agent.children {
                if let child = children.first(where: { $0.id == id }) { return child }
            }
        }
        return nil
    }

    private func flattenAgent(_ agent: AppAgent) -> [AppAgent] {
        if let children = agent.children, !children.isEmpty {
            return [agent] + children
        }
        return [agent]
    }

    // MARK: - Stats

    var activeCount: Int { states.values.filter { $0.isActive }.count }
    var completedCount: Int { states.values.filter { $0.stage == .complete }.count }
    var queuedCount: Int { queue.count }
    var totalTasks: Int { states.values.reduce(0) { $0 + $1.tasks.count } }
    var completedTasks: Int { states.values.reduce(0) { $0 + $1.tasks.filter { $0.status == .complete }.count } }

    var fleetProgress: Double {
        let total = states.count
        guard total > 0 else { return 0 }
        let sum = states.values.reduce(0.0) { $0 + $1.overallProgress }
        return sum / Double(total)
    }
}

// MARK: - Supabase Row Models

private struct SupabaseEvolutionRow: Codable {
    let app_id: String
    let pipeline: String
    let stage: String
    let hydra_cycle: Int
    let hydra_max_cycles: Int
    let adversarial_rounds: Int
    let adversarial_max_rounds: Int
    let dispatch_task_id: String?
    let dispatch_machine: String?
    let started_at: String?
    let completed_at: String?
    let error: String?

    // HyEvo fields
    let hyevo_generation: Int?
    let hyevo_max_generations: Int?
    let hyevo_best_fitness: Double?
    let hyevo_total_workflows: Int?

    func toState() -> AppEvolutionState {
        var state = AppEvolutionState(
            id: app_id,
            pipeline: EvolutionPipeline(rawValue: pipeline) ?? .creativeForge,
            stage: EvolutionStage(rawValue: stage) ?? .queued
        )
        state.hydraCycle = hydra_cycle
        state.hydraMaxCycles = hydra_max_cycles
        state.adversarialRounds = adversarial_rounds
        state.adversarialMaxRounds = adversarial_max_rounds
        state.dispatchTaskId = dispatch_task_id
        state.dispatchMachine = dispatch_machine
        state.error = error
        state.hyevoGeneration = hyevo_generation ?? 0
        state.hyevoMaxGenerations = hyevo_max_generations ?? 20
        state.hyevoBestFitness = hyevo_best_fitness ?? 0
        state.hyevoTotalWorkflows = hyevo_total_workflows ?? 0
        if let s = started_at { state.startedAt = ISO8601DateFormatter().date(from: s) }
        if let c = completed_at { state.completedAt = ISO8601DateFormatter().date(from: c) }
        return state
    }

    static func from(_ state: AppEvolutionState) -> SupabaseEvolutionRow {
        let fmt = ISO8601DateFormatter()
        return SupabaseEvolutionRow(
            app_id: state.id,
            pipeline: state.pipeline.rawValue,
            stage: state.stage.rawValue,
            hydra_cycle: state.hydraCycle,
            hydra_max_cycles: state.hydraMaxCycles,
            adversarial_rounds: state.adversarialRounds,
            adversarial_max_rounds: state.adversarialMaxRounds,
            dispatch_task_id: state.dispatchTaskId,
            dispatch_machine: state.dispatchMachine,
            started_at: state.startedAt.map { fmt.string(from: $0) },
            completed_at: state.completedAt.map { fmt.string(from: $0) },
            error: state.error,
            hyevo_generation: state.hyevoGeneration,
            hyevo_max_generations: state.hyevoMaxGenerations,
            hyevo_best_fitness: state.hyevoBestFitness,
            hyevo_total_workflows: state.hyevoTotalWorkflows
        )
    }
}

private struct SupabaseTaskRow: Codable {
    let id: String
    let app_id: String
    let description: String
    let priority: Int
    let source: String
    let status: String
    let created_at: String
    let completed_at: String?

    func toTask() -> EvolutionTask {
        let fmt = ISO8601DateFormatter()
        return EvolutionTask(
            id: id,
            appId: app_id,
            description: description,
            priority: priority,
            source: EvolutionTask.TaskSource(rawValue: source) ?? .manual,
            status: EvolutionTask.TaskStatus(rawValue: status) ?? .pending,
            createdAt: fmt.date(from: created_at) ?? Date(),
            completedAt: completed_at.flatMap { fmt.date(from: $0) }
        )
    }

    static func from(_ task: EvolutionTask) -> SupabaseTaskRow {
        let fmt = ISO8601DateFormatter()
        return SupabaseTaskRow(
            id: task.id,
            app_id: task.appId,
            description: task.description,
            priority: task.priority,
            source: task.source.rawValue,
            status: task.status.rawValue,
            created_at: fmt.string(from: task.createdAt),
            completed_at: task.completedAt.map { fmt.string(from: $0) }
        )
    }
}
