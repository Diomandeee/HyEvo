-- HyEvo: Self-Evolving Hybrid DAG Workflow columns for app_evolution_states
-- Adds MAP-Elites population tracking, generation progress, and DAG metadata.
-- Run this in Supabase Dashboard > SQL Editor

-- HyEvo state columns on evolution states
ALTER TABLE app_evolution_states
    ADD COLUMN IF NOT EXISTS hyevo_generation INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hyevo_max_generations INTEGER NOT NULL DEFAULT 20,
    ADD COLUMN IF NOT EXISTS hyevo_population_id TEXT,
    ADD COLUMN IF NOT EXISTS hyevo_active_dag_id TEXT,
    ADD COLUMN IF NOT EXISTS hyevo_best_fitness DOUBLE PRECISION NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hyevo_island_count INTEGER NOT NULL DEFAULT 6,
    ADD COLUMN IF NOT EXISTS hyevo_total_workflows INTEGER NOT NULL DEFAULT 0;

-- HyEvo workflow DAGs: stores serialized DAG topologies per app
CREATE TABLE IF NOT EXISTS hyevo_workflow_dags (
    id TEXT PRIMARY KEY,
    app_id TEXT NOT NULL REFERENCES app_evolution_states(app_id) ON DELETE CASCADE,
    name TEXT NOT NULL DEFAULT 'workflow',
    generation INTEGER NOT NULL DEFAULT 0,
    fitness DOUBLE PRECISION NOT NULL DEFAULT 0,
    efficiency DOUBLE PRECISION NOT NULL DEFAULT 0,
    feature_vector DOUBLE PRECISION[] DEFAULT '{}',
    node_count INTEGER NOT NULL DEFAULT 0,
    llm_node_count INTEGER NOT NULL DEFAULT 0,
    code_node_count INTEGER NOT NULL DEFAULT 0,
    edge_count INTEGER NOT NULL DEFAULT 0,
    depth INTEGER NOT NULL DEFAULT 0,
    total_token_cost INTEGER NOT NULL DEFAULT 0,
    total_latency_ms INTEGER NOT NULL DEFAULT 0,
    topology JSONB NOT NULL DEFAULT '{}',       -- Full serialized DAG (nodes + edges)
    parent_ids TEXT[] DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- HyEvo population islands: tracks MAP-Elites islands
CREATE TABLE IF NOT EXISTS hyevo_islands (
    id TEXT PRIMARY KEY,
    population_id TEXT NOT NULL,
    app_id TEXT NOT NULL REFERENCES app_evolution_states(app_id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    strategy TEXT NOT NULL,
    generation INTEGER NOT NULL DEFAULT 0,
    best_fitness DOUBLE PRECISION NOT NULL DEFAULT 0,
    grid_cell_count INTEGER NOT NULL DEFAULT 0,
    coverage DOUBLE PRECISION NOT NULL DEFAULT 0,
    diversity DOUBLE PRECISION NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- HyEvo reflections: LLM-generated analysis of workflow execution
CREATE TABLE IF NOT EXISTS hyevo_reflections (
    id TEXT PRIMARY KEY,
    app_id TEXT NOT NULL REFERENCES app_evolution_states(app_id) ON DELETE CASCADE,
    generation INTEGER NOT NULL,
    dag_id TEXT REFERENCES hyevo_workflow_dags(id) ON DELETE SET NULL,
    fitness DOUBLE PRECISION NOT NULL DEFAULT 0,
    analysis TEXT NOT NULL,
    suggestions TEXT[] DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_hyevo_dags_app ON hyevo_workflow_dags(app_id);
CREATE INDEX IF NOT EXISTS idx_hyevo_dags_fitness ON hyevo_workflow_dags(fitness DESC);
CREATE INDEX IF NOT EXISTS idx_hyevo_dags_generation ON hyevo_workflow_dags(generation);
CREATE INDEX IF NOT EXISTS idx_hyevo_islands_app ON hyevo_islands(app_id);
CREATE INDEX IF NOT EXISTS idx_hyevo_islands_pop ON hyevo_islands(population_id);
CREATE INDEX IF NOT EXISTS idx_hyevo_reflections_app ON hyevo_reflections(app_id);
CREATE INDEX IF NOT EXISTS idx_hyevo_reflections_gen ON hyevo_reflections(generation);
CREATE INDEX IF NOT EXISTS idx_evo_states_hyevo ON app_evolution_states(pipeline) WHERE pipeline = 'hyevo';

-- RLS (permissive for now — MeshControl is single-user)
ALTER TABLE hyevo_workflow_dags ENABLE ROW LEVEL SECURITY;
ALTER TABLE hyevo_islands ENABLE ROW LEVEL SECURITY;
ALTER TABLE hyevo_reflections ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
    CREATE POLICY hyevo_dags_all ON hyevo_workflow_dags FOR ALL USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE POLICY hyevo_islands_all ON hyevo_islands FOR ALL USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE POLICY hyevo_reflections_all ON hyevo_reflections FOR ALL USING (true) WITH CHECK (true);
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- Realtime for live DAG updates
ALTER PUBLICATION supabase_realtime ADD TABLE hyevo_workflow_dags;
ALTER PUBLICATION supabase_realtime ADD TABLE hyevo_reflections;
