# HyEvo

**Self-Evolving Hybrid Agentic Workflow DAGs**

MAP-Elites evolution of LLM + Code node topologies for autonomous app development. Based on [arXiv:2603.19639](https://arxiv.org/abs/2603.19639).

## What is this?

HyEvo treats the **workflow topology itself as an evolvable artifact**. Instead of fixed agent pipelines, it generates directed acyclic graphs (DAGs) mixing two node types:

- **LLM nodes** -- semantic reasoning (code analysis, planning, review)
- **Code nodes** -- deterministic execution (build, test, lint)

A multi-island MAP-Elites algorithm evolves these topologies over generations, discovering optimal structures per app.

## The Evolution Loop

```
Seed Population (3 topologies x 6 islands)
       |
       v
  Execute Best DAG -----> Score Fitness
       ^                    |
       |                    v
   Migrate <---- Evolve <---- Reflect
  (every Nth)   (MAP-Elites)  (LLM meta-agent)
```

**Fitness**: `R = 0.9 * quality + 0.05 * cost_utility + 0.05 * latency_utility`

**6 Islands**, each with a mutation strategy:
| Island | Strategy | Effect |
|--------|----------|--------|
| 0 | Add Node | Insert LLM or Code node |
| 1 | Remove Node | Prune low-impact node |
| 2 | Swap Type | LLM <-> Code conversion |
| 3 | Rewire Edge | Change connections |
| 4 | Mutate Content | LLM-refined prompts/scripts |
| 5 | Crossover | Merge two parent DAGs |

**Parent selection**: 50% elite, 30% history, 20% cross-island.

## Structure

```
Sources/HyEvo/
  Models/
    WorkflowDAG.swift          # DAG, Node, Edge models + seed topologies
    WorkflowPopulation.swift   # MAP-Elites population, islands, mutations
    AppEvolutionState.swift    # Pipeline state machine + HyEvo stages
  Views/
    WorkflowDAGView.swift      # Force-directed DAG visualization (SwiftUI)
    FleetEvolutionView.swift   # Fleet dashboard with HyEvo integration
  Services/
    FleetEvolutionClient.swift # Evolution engine, DAG execution, reflect-then-generate

docs/
  HYEVO.md                     # Detailed technical documentation

supabase/migrations/
  20260325_hyevo_columns.sql   # Database schema (Supabase/Postgres)

audio/
  HyEvo_Explainer.mp3         # Audio walkthrough (OpenAI TTS)
```

## Key Concepts

- **Hybrid nodes**: LLM for reasoning, Code for deterministic ops. Evolution finds the optimal ratio (paper sweet spot: 30-50% code).
- **MAP-Elites**: Quality-diversity search over a 3D feature grid (LLM ratio, depth, edge density). Maintains diverse topologies instead of converging on one.
- **Reflect-then-generate**: LLM meta-agent analyzes execution feedback, then mutations are applied informed by that analysis.
- **Ring migration**: Elite DAGs spread across islands every N generations.

## Context

Built for [MeshControl](https://github.com/Diomandeee/MeshControl), an iOS command center for distributed autonomous app development across a multi-machine mesh. HyEvo replaces fixed evolution pipelines with self-evolving workflow topologies.

Adapted from the paper:

> **HyEvo: Self-Evolving Hybrid Agentic Workflows for Efficient Reasoning**
> Beibei Xu, Yutong Ye, Chuyun Shen, Yingbo Zhou, Cheng Chen, Mingsong Chen
> East China Normal University, Beihang University, SUIBE, Fudan University
> [arXiv:2603.19639](https://arxiv.org/abs/2603.19639) (March 2026)

Key results from the paper: up to 19x cost reduction and 16x latency reduction vs state-of-the-art baselines on math/coding benchmarks.

## License

MIT
