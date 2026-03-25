# HyEvo: Self-Evolving Hybrid Workflow DAGs in MeshControl

## What Is HyEvo?

HyEvo is a new evolution pipeline in MeshControl that treats the **workflow topology itself as the thing being evolved**, not just the prompts or agents within a fixed pipeline.

Instead of running every app through the same Skill -> Adversarial -> Hydra sequence, HyEvo generates, tests, and evolves entire workflow DAGs (directed acyclic graphs) using a population-based evolutionary algorithm called MAP-Elites. Each DAG is a mix of two node types:

- **LLM nodes**: Semantic reasoning tasks dispatched to Claude/Codex via the mesh
- **Code nodes**: Deterministic scripts (build, test, lint) that run instantly without LLM inference

The evolution discovers the optimal mix and arrangement of these nodes for each app.

---

## Why This Matters

The current MeshControl pipelines (Creative Forge, Omega, Divergent Rail) are **fixed topologies**. Every app goes through the same sequence of stages regardless of what the app actually needs. This has two problems:

1. **One size doesn't fit all.** A mature app near TestFlight doesn't need the same workflow as an idea-stage scaffold.
2. **LLM overuse.** Every step dispatches to an LLM, even tasks that could be a simple `swift build` or `swiftlint` check. This wastes tokens, time, and mesh compute.

HyEvo solves both: it discovers app-specific topologies that mix LLM reasoning with cheap deterministic checks, cutting inference cost by up to 19x and latency by up to 16x (per the original paper's benchmarks).

---

## How It Works: The Evolution Loop

### Step 1: Seeding

When you enqueue an app with the HyEvo pipeline, the system creates a **population** of workflow DAGs. Three seed topologies are generated:

- **Linear seed**: Analyze -> Plan -> Implement -> Test -> Review -> Fix -> Validate (mirrors the current pipeline)
- **Parallel seed**: Build check + Lint check + Dep scan run concurrently, then merge into a synthesis step
- **Iterative seed**: Tight loop of implement -> test -> implement -> test for focused micro-improvements

These seeds are distributed across 6 **islands**, each specializing in a different mutation strategy.

### Step 2: Execute the Best DAG

The current best DAG (highest fitness) is selected and executed. Each node runs in topological order:

- Nodes with no dependencies (entry nodes) start first
- When a node's upstream dependencies are all complete, it becomes ready
- Ready nodes at the same level run concurrently via AuraGateway dispatch
- LLM nodes go to Claude sessions on the mesh; code nodes run as shell commands

### Step 3: Score Fitness

After execution, the DAG is scored using a weighted formula from the HyEvo paper:

```
R = 0.9 * quality + 0.05 * cost_utility + 0.05 * latency_utility
```

Where:
- **Quality** (90% weight): fraction of nodes that completed successfully
- **Cost utility** (5%): inverse of total token cost across LLM nodes
- **Latency utility** (5%): inverse of total execution time

Quality dominates, but cost and latency create pressure to replace unnecessary LLM nodes with code nodes.

### Step 4: Reflect

This is the "reflect" in "reflect-then-generate." A meta-agent prompt is built containing:

- The full DAG structure (every node, its type, status, latency, token cost)
- All edges and their conditions
- The current elite (best-ever DAG) for comparison
- Failure logs from any nodes that didn't complete

This prompt is dispatched to an LLM via AuraGateway. The system also generates heuristic suggestions based on execution patterns:

- Is the code node ratio too low? (Paper sweet spot is 30-50%)
- Is the DAG too deep and sequential?
- Did any nodes fail?
- Are there LLM nodes doing work that could be deterministic?

These suggestions are stored as **reflections** and inform the next generation's mutations.

### Step 5: Evolve (MAP-Elites)

This is where the magic happens. The population uses **MAP-Elites**, a quality-diversity algorithm that maintains a grid of diverse high-performing solutions instead of converging on a single optimum.

**The 6 Islands:**

Each island specializes in one mutation strategy:

| Island | Strategy | What It Does |
|--------|----------|-------------|
| 0 | Add Node | Inserts a new LLM or Code node between existing nodes |
| 1 | Remove Node | Removes a low-impact node and rewires its connections |
| 2 | Swap Type | Converts an LLM node to Code or vice versa |
| 3 | Rewire Edge | Changes edge connections (only accepts acyclic results) |
| 4 | Mutate Content | Refines a node's prompt/script via LLM dispatch |
| 5 | Crossover | Merges topology from two parent DAGs |

**Parent Selection (per paper):**

- 50% chance: pick the elite (best) from the island's archive
- 30% chance: tournament selection from the island's history
- 20% chance: sample from a different island (cross-pollination)

**Feature Grid:**

Each DAG is placed in a 3D feature grid based on:
1. **LLM ratio**: proportion of LLM nodes (0.0 = all code, 1.0 = all LLM)
2. **Depth**: longest path from entry to exit, normalized
3. **Edge density**: how connected the graph is

A new DAG only replaces an existing grid cell occupant if its fitness is higher. This maintains diversity: the population always has both shallow/deep, LLM-heavy/code-heavy, sparse/dense topologies.

### Step 6: Migrate

Every N generations (default: 5), **ring migration** occurs: each island copies its best DAG and sends it to all other islands. This spreads winning patterns across the population while maintaining island-level diversity through different mutation strategies.

### Step 7: Repeat or Terminate

The loop continues (execute -> score -> reflect -> evolve -> migrate) for up to 20 generations (configurable). When complete, the best DAG moves to Adversarial Review, then Hydra cycles as usual.

---

## Architecture: Files and Components

### Models

**`WorkflowDAG.swift`** (Core data model)
- `WorkflowNode`: A single execution unit. Type is `.llm` or `.code`. Tracks status, output, latency, token cost.
- `WorkflowEdge`: Directed dependency with conditions (always, onSuccess, onFailure).
- `WorkflowDAG`: The complete graph. Computes entry/exit nodes, topological depth, feature vectors, acyclicity validation, progress tracking.
- Seed factories: `linearSeed()`, `parallelSeed()`, `iterativeSeed()` generate starting topologies.

**`WorkflowPopulation.swift`** (Evolutionary engine)
- `MAPElitesCell`: Single cell in the feature grid. Stores the best workflow for that niche.
- `EvolutionIsland`: One island with its own MAP-Elites grid, mutation strategy, and generation counter.
- `WorkflowPopulation`: The full multi-island population. Handles seeding, migration, global best tracking.
- `EvolutionReflection`: LLM-generated analysis with suggestions.
- `WorkflowMutations`: Pure functions for all 6 mutation operations.

**`AppEvolutionState.swift`** (Modified)
- New pipeline: `.hyevo` with pink color and DAG icon
- New stages: `hyevoSeeding`, `hyevoExecuting`, `hyevoReflecting`, `hyevoEvolving`, `hyevoMigrating`
- New fields: `hyevoGeneration`, `hyevoMaxGenerations`, `hyevoBestFitness`, `hyevoTotalWorkflows`
- New task sources: `hyevoDAG`, `hyevoReflect`

### Service

**`FleetEvolutionClient.swift`** (Modified)
- `startHyEvo()`: Seeds population, begins evolution loop
- `executeDAG()`: Dispatches nodes via AuraGateway in topological order
- `reflectAndEvolve()`: Full reflect-then-generate cycle with LLM dispatch
- `buildReflectionPrompt()`: Constructs structured meta-agent prompt
- `mutateContent()`: LLM-driven node content refinement
- `hyevoStep()` / `startHyEvoMonitor()`: Evolution loop management
- `syncDAGToSupabase()` / `syncReflectionToSupabase()`: Persistence

### View

**`WorkflowDAGView.swift`** (New)
- Layer-based DAG layout (topological ordering)
- Node circles colored by type (violet=LLM, cyan=Code) with status indicators
- Curved edges with arrow heads and condition-based styling
- Fitness gauge (circular progress)
- Population stats bar (generation, islands, workflows, coverage, best fitness)
- Tap-to-inspect: NodeDetailSheet shows content, dependencies, metadata
- PopulationDetailSheet: Island cards with grid coverage visualization, reflections

**`FleetEvolutionView.swift`** (Modified)
- HyEvo filter chip in phase bar
- Generation counter on app cards when pipeline is HyEvo
- DAG visualization embedded in detail sheet
- Updated pipeline dots to include HyEvo phase

### Database

**`supabase/migrations/20260325_hyevo_columns.sql`**
- `hyevo_*` columns on `app_evolution_states`
- `hyevo_workflow_dags`: Serialized DAG topologies with metrics
- `hyevo_islands`: MAP-Elites island state
- `hyevo_reflections`: LLM analysis history

---

## How to Use

### Enqueue an App with HyEvo

1. Open MeshControl -> Apps -> Evolution
2. Tap the **+** button (Enqueue)
3. In the Pipeline picker, select **HyEvo**
4. Select one or more apps
5. Tap **Enqueue**

The app will appear in the evolution list with a pink HyEvo badge.

### Monitor Evolution

- The card shows current generation (e.g., "Gen 5/20") and stage
- Pipeline dots include an "E" for HyEvo between Skill and Adversarial
- Tap any HyEvo app to see the full DAG visualization
- The population bar at the bottom shows real-time stats

### Inspect the DAG

- Tap any node in the DAG view to see its content, type, dependencies, and execution metrics
- Tap the population bar to see all 6 islands, their coverage grids, and recent reflections
- Each reflection shows what the meta-agent learned and suggested

### After Evolution Completes

When HyEvo reaches its max generation count, the best-evolved DAG automatically feeds into Adversarial Review (Codex on Mac4), then Hydra cycles as usual. The workflow topology is preserved and can be reused for future runs.

---

## Key Concepts Glossary

| Term | Meaning |
|------|---------|
| **DAG** | Directed Acyclic Graph. A workflow where nodes can't form loops. |
| **LLM Node** | A node that dispatches a prompt to an LLM (Claude, Codex) for semantic reasoning. |
| **Code Node** | A node that runs a deterministic script (build, test, lint). Fast and free. |
| **MAP-Elites** | Quality-diversity algorithm. Maintains a grid of diverse good solutions, not just one best. |
| **Island** | An independent sub-population with its own mutation strategy. |
| **Feature Vector** | Describes a DAG's structural characteristics (LLM ratio, depth, density). Determines grid cell placement. |
| **Fitness** | Weighted score: 90% quality + 5% cost efficiency + 5% speed. |
| **Reflect-then-generate** | LLM analyzes execution results, then mutations are applied informed by that analysis. |
| **Migration** | Copying elite DAGs between islands to spread winning patterns. |
| **Crossover** | Merging two parent DAGs by taking half the nodes from each. |
| **Generation** | One full cycle of execute -> score -> reflect -> evolve. |

---

## Connection to the Paper

This implementation is based on "HyEvo: Self-Evolving Hybrid Agentic Workflows for Efficient Reasoning" (arXiv:2603.19639, March 2026) by Beibei Xu et al. from East China Normal University.

Key adaptations for MeshControl:
- **Node dispatch via AuraGateway** instead of local Python execution
- **6 islands** (one per mutation type) instead of the paper's 2
- **3D feature vector** (LLM ratio, depth, edge density) instead of 2D (node count, LLM proportion)
- **Swift/SwiftUI implementation** with real-time DAG visualization
- **Supabase persistence** for cross-session evolution continuity
- **Mesh-aware execution** with multi-machine dispatch and model routing
