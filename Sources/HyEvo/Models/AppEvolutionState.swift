import Foundation

// MARK: - Evolution Pipeline Type

/// Which skill pipeline to run on an app before Hydra finishes it.
enum EvolutionPipeline: String, Codable, CaseIterable, Sendable {
    case creativeForge  = "creative_forge"   // 6-phase creative stack
    case omega          = "omega"            // 7-stage meta evolution
    case divergentRail  = "divergent_rail"   // EW-governed parallel phases
    case hyevo          = "hyevo"            // Self-evolving hybrid DAG workflows (MAP-Elites)

    var label: String {
        switch self {
        case .creativeForge: return "Creative Forge"
        case .omega:         return "Omega"
        case .divergentRail: return "Divergent Rail"
        case .hyevo:         return "HyEvo"
        }
    }

    var icon: String {
        switch self {
        case .creativeForge: return "flame.circle.fill"
        case .omega:         return "atom"
        case .divergentRail: return "arrow.triangle.branch"
        case .hyevo:         return "point.3.connected.trianglepath.dotted"
        }
    }

    var skillCommand: String {
        switch self {
        case .creativeForge: return "/creative:forge"
        case .omega:         return "/meta:omega"
        case .divergentRail: return "/divergent-rail"
        case .hyevo:         return "/hyevo"
        }
    }

    /// Recommended pipeline based on the app's contract stage.
    static func recommended(for stage: AppContract.Stage) -> EvolutionPipeline {
        switch stage {
        case .idea, .scaffolded:
            return .creativeForge
        case .built, .registered:
            return .hyevo       // HyEvo for apps that need topology-aware evolution
        case .testflight, .readyToShip, .shipped:
            return .omega
        }
    }
}

// MARK: - Evolution Stage

/// Unified stage enum across the entire fleet pipeline:
/// Skill Phase -> Adversarial Review -> Hydra Cycles
enum EvolutionStage: String, Codable, Sendable, CaseIterable {
    // Pre-pipeline
    case queued             = "queued"

    // Skill execution (Creative Forge / Omega / Divergent Rail)
    case skillRunning       = "skill_running"
    case skillComplete      = "skill_complete"

    // HyEvo DAG evolution (MAP-Elites → Execute DAG → Reflect → Evolve)
    case hyevoSeeding       = "hyevo_seeding"       // Initializing population with seed DAGs
    case hyevoExecuting     = "hyevo_executing"     // Running the current best DAG
    case hyevoReflecting    = "hyevo_reflecting"    // LLM reflecting on execution results
    case hyevoEvolving      = "hyevo_evolving"      // MAP-Elites generating next generation
    case hyevoMigrating     = "hyevo_migrating"     // Cross-island elite migration

    // Adversarial review (Mac4 Codex dispatch)
    case adversarialPending = "adversarial_pending"
    case adversarialRunning = "adversarial_running"
    case adversarialComplete = "adversarial_complete"

    // Hydra cycles (BUILD -> AUDIT -> INCUBATE -> REFINE -> DISPATCH)
    case hydraBuild         = "hydra_build"
    case hydraAudit         = "hydra_audit"
    case hydraIncubate      = "hydra_incubate"
    case hydraRefine        = "hydra_refine"
    case hydraDispatch      = "hydra_dispatch"

    // Terminal
    case complete           = "complete"
    case failed             = "failed"

    var label: String {
        switch self {
        case .queued:              return "Queued"
        case .skillRunning:        return "Skill Running"
        case .skillComplete:       return "Skill Done"
        case .hyevoSeeding:        return "HyEvo: Seeding"
        case .hyevoExecuting:      return "HyEvo: Executing DAG"
        case .hyevoReflecting:     return "HyEvo: Reflecting"
        case .hyevoEvolving:       return "HyEvo: Evolving"
        case .hyevoMigrating:      return "HyEvo: Migrating"
        case .adversarialPending:  return "Review Pending"
        case .adversarialRunning:  return "Adversarial Review"
        case .adversarialComplete: return "Review Done"
        case .hydraBuild:          return "Hydra: Build"
        case .hydraAudit:          return "Hydra: Audit"
        case .hydraIncubate:       return "Hydra: Incubate"
        case .hydraRefine:         return "Hydra: Refine"
        case .hydraDispatch:       return "Hydra: Dispatch"
        case .complete:            return "Complete"
        case .failed:              return "Failed"
        }
    }

    var icon: String {
        switch self {
        case .queued:              return "clock"
        case .skillRunning:        return "gearshape.2.fill"
        case .skillComplete:       return "checkmark.seal"
        case .hyevoSeeding:        return "leaf.fill"
        case .hyevoExecuting:      return "point.3.connected.trianglepath.dotted"
        case .hyevoReflecting:     return "brain.head.profile"
        case .hyevoEvolving:       return "arrow.triangle.2.circlepath"
        case .hyevoMigrating:      return "arrow.left.arrow.right.circle"
        case .adversarialPending:  return "arrow.left.arrow.right"
        case .adversarialRunning:  return "arrow.triangle.2.circlepath"
        case .adversarialComplete: return "checkmark.shield"
        case .hydraBuild:          return "hammer.fill"
        case .hydraAudit:          return "magnifyingglass"
        case .hydraIncubate:       return "flame.fill"
        case .hydraRefine:         return "sparkles"
        case .hydraDispatch:       return "paperplane.fill"
        case .complete:            return "checkmark.circle.fill"
        case .failed:              return "xmark.octagon.fill"
        }
    }

    /// Ordered list of stages for progress calculation (classic pipeline).
    static let pipeline: [EvolutionStage] = [
        .queued,
        .skillRunning, .skillComplete,
        .adversarialPending, .adversarialRunning, .adversarialComplete,
        .hydraBuild, .hydraAudit, .hydraIncubate, .hydraRefine, .hydraDispatch,
        .complete
    ]

    /// HyEvo-specific pipeline stages.
    static let hyevoPipeline: [EvolutionStage] = [
        .queued,
        .hyevoSeeding, .hyevoExecuting, .hyevoReflecting, .hyevoEvolving, .hyevoMigrating,
        .complete
    ]

    /// 0.0 – 1.0 progress through the full pipeline.
    var progress: Double {
        guard let idx = Self.pipeline.firstIndex(of: self) else { return 0 }
        return Double(idx) / Double(Self.pipeline.count - 1)
    }

    /// Which macro-phase are we in? (for section grouping)
    var phase: EvolutionPhase {
        switch self {
        case .queued:
            return .queued
        case .skillRunning, .skillComplete:
            return .skill
        case .hyevoSeeding, .hyevoExecuting, .hyevoReflecting, .hyevoEvolving, .hyevoMigrating:
            return .hyevo
        case .adversarialPending, .adversarialRunning, .adversarialComplete:
            return .adversarial
        case .hydraBuild, .hydraAudit, .hydraIncubate, .hydraRefine, .hydraDispatch:
            return .hydra
        case .complete:
            return .complete
        case .failed:
            return .failed
        }
    }

    /// Map HydraClient phase string → EvolutionStage for UI sync.
    static func fromHydraPhase(_ phase: String, cycle: Int) -> EvolutionStage {
        switch phase.lowercased() {
        case "build":    return .hydraBuild
        case "audit":    return .hydraAudit
        case "incubate": return .hydraIncubate
        case "refine":   return .hydraRefine
        case "dispatch": return .hydraDispatch
        case "idle":     return cycle > 0 ? .hydraDispatch : .hydraBuild
        default:         return .hydraBuild
        }
    }
}

enum EvolutionPhase: String, Sendable {
    case queued, skill, hyevo, adversarial, hydra, complete, failed

    var color: String {
        switch self {
        case .queued:      return "64748B"
        case .skill:       return "8B5CF6"
        case .hyevo:       return "EC4899"   // pink — self-evolving DAGs
        case .adversarial: return "F59E0B"
        case .hydra:       return "06B6D4"
        case .complete:    return "10B981"
        case .failed:      return "EF4444"
        }
    }
}

// MARK: - Evolution Task

/// A single task generated during evolution (from skill output, adversarial review, or Hydra incubation).
struct EvolutionTask: Identifiable, Codable, Sendable {
    let id: String
    let appId: String
    let description: String
    let priority: Int               // 1 = critical, 5 = nice-to-have
    let source: TaskSource          // which phase generated it
    var status: TaskStatus
    let createdAt: Date
    var completedAt: Date?

    enum TaskSource: String, Codable, Sendable {
        case skill          = "skill"
        case adversarial    = "adversarial"
        case hydraBuild     = "hydra_build"
        case hydraAudit     = "hydra_audit"
        case hydraIncubate  = "hydra_incubate"
        case hydraRefine    = "hydra_refine"
        case hyevoDAG       = "hyevo_dag"        // Generated by HyEvo DAG execution
        case hyevoReflect   = "hyevo_reflect"    // Generated by reflect-then-generate
        case manual         = "manual"
    }

    enum TaskStatus: String, Codable, Sendable {
        case pending     = "pending"
        case inProgress  = "in_progress"
        case complete    = "complete"
        case blocked     = "blocked"
    }

    var priorityLabel: String {
        switch priority {
        case 1: return "P1"
        case 2: return "P2"
        case 3: return "P3"
        case 4: return "P4"
        default: return "P5"
        }
    }
}

// MARK: - Per-App Evolution State

/// Tracks the full evolution pipeline state for a single app.
struct AppEvolutionState: Identifiable, Codable, Sendable {
    let id: String                          // matches AppAgent.id
    var pipeline: EvolutionPipeline
    var stage: EvolutionStage
    var tasks: [EvolutionTask]
    var hydraCycle: Int
    var hydraMaxCycles: Int
    var adversarialRounds: Int
    var adversarialMaxRounds: Int
    var dispatchTaskId: String?             // gateway task ID for active dispatch
    var dispatchMachine: String?            // which machine is running it
    var startedAt: Date?
    var completedAt: Date?
    var error: String?

    // HyEvo-specific state
    var hyevoGeneration: Int                // Current evolutionary generation
    var hyevoMaxGenerations: Int            // Stop after this many generations
    var hyevoPopulationId: String?          // Link to WorkflowPopulation
    var hyevoActiveDAGId: String?           // Currently executing DAG
    var hyevoBestFitness: Double            // Best fitness seen so far
    var hyevoIslandCount: Int               // Number of MAP-Elites islands
    var hyevoTotalWorkflows: Int            // Total unique workflows explored

    init(
        id: String,
        pipeline: EvolutionPipeline = .creativeForge,
        stage: EvolutionStage = .queued
    ) {
        self.id = id
        self.pipeline = pipeline
        self.stage = stage
        self.tasks = []
        self.hydraCycle = 0
        self.hydraMaxCycles = 10
        self.adversarialRounds = 0
        self.adversarialMaxRounds = 2
        self.dispatchTaskId = nil
        self.dispatchMachine = nil
        self.startedAt = nil
        self.completedAt = nil
        self.error = nil
        // HyEvo defaults
        self.hyevoGeneration = 0
        self.hyevoMaxGenerations = 20
        self.hyevoPopulationId = nil
        self.hyevoActiveDAGId = nil
        self.hyevoBestFitness = 0
        self.hyevoIslandCount = 6
        self.hyevoTotalWorkflows = 0
    }

    /// Overall progress 0.0 – 1.0 combining stage progress + cycle/generation granularity.
    var overallProgress: Double {
        // HyEvo pipeline: progress based on generation
        if pipeline == .hyevo && stage.phase == .hyevo {
            let stageList = EvolutionStage.hyevoPipeline
            guard let idx = stageList.firstIndex(of: stage) else { return 0 }
            let baseProgress = Double(idx) / Double(stageList.count - 1)
            // Add generation-level granularity within HyEvo phases
            if hyevoMaxGenerations > 0 {
                let genProgress = Double(hyevoGeneration) / Double(hyevoMaxGenerations)
                let hyevoRange = 0.7 // HyEvo phases span ~70% of the pipeline
                return 0.1 + (hyevoRange * genProgress) // 10% for seeding, 70% for evolution
            }
            return baseProgress
        }

        let stageProgress = stage.progress
        // Within Hydra phases, add cycle-level granularity
        if stage.phase == .hydra && hydraMaxCycles > 0 {
            let hydraBase = EvolutionStage.hydraBuild.progress
            let hydraRange = EvolutionStage.complete.progress - hydraBase
            let cycleProgress = Double(hydraCycle) / Double(hydraMaxCycles)
            return hydraBase + (hydraRange * cycleProgress)
        }
        return stageProgress
    }

    var tasksSummary: String {
        let total = tasks.count
        let done = tasks.filter { $0.status == .complete }.count
        let critical = tasks.filter { $0.priority <= 2 && $0.status != .complete }.count
        if total == 0 { return "No tasks yet" }
        return "\(done)/\(total) done" + (critical > 0 ? ", \(critical) critical" : "")
    }

    var isActive: Bool {
        stage != .queued && stage != .complete && stage != .failed
    }
}
