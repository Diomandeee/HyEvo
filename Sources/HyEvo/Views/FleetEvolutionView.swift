import SwiftUI

/// Fleet Evolution dashboard -- live progress bars for every app in the pipeline.
/// Tap any app to drill into its task list and work on it linearly.
struct FleetEvolutionView: View {
    @State private var client = FleetEvolutionClient.shared
    @State private var showEnqueueSheet = false
    @State private var selectedDetail: AppEvolutionState?
    @State private var filterPhase: EvolutionPhase?
    @State private var searchText = ""

    private var filteredStates: [AppEvolutionState] {
        var result = Array(client.states.values)
        if let phase = filterPhase {
            result = result.filter { $0.stage.phase == phase }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { $0.id.lowercased().contains(q) }
        }
        return result.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.overallProgress < rhs.overallProgress
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    fleetStatsBar
                    phaseFilterChips
                    if filteredStates.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredStates, id: \.id) { state in
                                appEvolutionCard(state)
                                    .onTapGesture { selectedDetail = state }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Fleet Evolution")
            .searchable(text: $searchText, prompt: "Search apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Enqueue All") {
                            client.enqueueAll(fleet: AppAgent.fleet)
                        }
                        Button("Process Queue") {
                            Task { await client.processQueue() }
                        }
                        Divider()
                        Button("Sync from Supabase") {
                            Task { await client.fetchStatesFromSupabase() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showEnqueueSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(item: $selectedDetail) { state in
                AppEvolutionDetailSheet(state: state)
            }
            .sheet(isPresented: $showEnqueueSheet) {
                EnqueueSheet()
            }
            .task {
                await client.fetchStatesFromSupabase()
            }
        }
    }

    // MARK: - Fleet Stats Bar

    private var fleetStatsBar: some View {
        HStack(spacing: 16) {
            statPill(label: "Active", value: "\(client.activeCount)", color: .cyan)
            statPill(label: "Queued", value: "\(client.queuedCount)", color: .gray)
            statPill(label: "Done", value: "\(client.completedCount)", color: .green)
            statPill(label: "Tasks", value: "\(client.completedTasks)/\(client.totalTasks)", color: .purple)
        }
        .padding(.horizontal, 4)
    }

    private func statPill(label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Phase Filter

    private var phaseFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(label: "All", phase: nil)
                filterChip(label: "Skill", phase: .skill)
                filterChip(label: "HyEvo", phase: .hyevo)
                filterChip(label: "Review", phase: .adversarial)
                filterChip(label: "Hydra", phase: .hydra)
                filterChip(label: "Done", phase: .complete)
                filterChip(label: "Failed", phase: .failed)
            }
        }
    }

    private func filterChip(label: String, phase: EvolutionPhase?) -> some View {
        let isSelected = filterPhase == phase
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                filterPhase = isSelected ? nil : phase
            }
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .bold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - App Card

    private func appEvolutionCard(_ state: AppEvolutionState) -> some View {
        let app = findApp(state.id)
        let phaseColor = Color(hex: state.stage.phase.color)

        return VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: app?.icon ?? "app.circle")
                    .font(.title3)
                    .foregroundStyle(phaseColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app?.name ?? state.id)
                        .font(.headline)
                    Text(state.pipeline.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.stage.label)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(phaseColor)
                    if state.stage.phase == .hydra {
                        Text("Cycle \(state.hydraCycle)/\(state.hydraMaxCycles)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if state.stage.phase == .hyevo {
                        Text("Gen \(state.hyevoGeneration)/\(state.hyevoMaxGenerations)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Progress bar with completion glow
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [phaseColor.opacity(0.7), phaseColor],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * state.overallProgress)
                        .animation(.easeInOut(duration: 0.5), value: state.overallProgress)
                    if state.stage.phase == .complete {
                        Capsule()
                            .fill(DesignTokens.moss.opacity(0.3))
                            .shadow(color: DesignTokens.moss.opacity(0.5), radius: 6)
                    }
                }
            }
            .frame(height: 6)
            .onChange(of: state.stage) { oldStage, newStage in
                if newStage.phase == .complete && oldStage.phase != .complete {
                    HapticEngine.success()
                }
            }

            // Stage pipeline dots
            pipelineDots(state)

            // Task summary
            HStack {
                Image(systemName: "checklist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(state.tasksSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let machine = state.dispatchMachine {
                    Text(machine)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Text("\(Int(state.overallProgress * 100))%")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(phaseColor)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Pipeline Dots

    private func pipelineDots(_ state: AppEvolutionState) -> some View {
        let phases: [(EvolutionPhase, String)] = state.pipeline == .hyevo
            ? [(.skill, "S"), (.hyevo, "E"), (.adversarial, "A"), (.hydra, "H"), (.complete, "C")]
            : [(.skill, "S"), (.adversarial, "A"), (.hydra, "H"), (.complete, "C")]
        return HStack(spacing: 4) {
            ForEach(phases, id: \.0) { phase, letter in
                let isCurrent = state.stage.phase == phase
                let isPast = phaseOrder(state.stage.phase) > phaseOrder(phase)
                Circle()
                    .fill(isPast ? Color(hex: phase.color) : isCurrent ? Color(hex: phase.color).opacity(0.6) : Color(.tertiarySystemFill))
                    .frame(width: isCurrent ? 10 : 7, height: isCurrent ? 10 : 7)
                    .overlay {
                        if isCurrent {
                            Circle()
                                .stroke(Color(hex: phase.color), lineWidth: 1.5)
                                .frame(width: 14, height: 14)
                        }
                    }
                if phase != .complete {
                    Rectangle()
                        .fill(isPast ? Color(hex: phase.color).opacity(0.5) : Color(.tertiarySystemFill))
                        .frame(height: 1.5)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func phaseOrder(_ phase: EvolutionPhase) -> Int {
        switch phase {
        case .queued:      return 0
        case .skill:       return 1
        case .hyevo:       return 2
        case .adversarial: return 3
        case .hydra:       return 4
        case .complete:    return 5
        case .failed:      return 6
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No apps in the evolution pipeline")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap + to enqueue apps, or use Enqueue All from the menu.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 60)
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
}

// MARK: - App Evolution Detail Sheet

struct AppEvolutionDetailSheet: View {
    let state: AppEvolutionState
    @State private var client = FleetEvolutionClient.shared
    @Environment(\.dismiss) private var dismiss

    private var app: AppAgent? {
        for agent in AppAgent.fleet {
            if agent.id == state.id { return agent }
            if let children = agent.children {
                if let child = children.first(where: { $0.id == state.id }) { return child }
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    HStack {
                        Image(systemName: app?.icon ?? "app.circle")
                            .font(.largeTitle)
                            .foregroundStyle(Color(hex: state.stage.phase.color))
                        VStack(alignment: .leading) {
                            Text(app?.name ?? state.id)
                                .font(.title2.bold())
                            Text("\(state.pipeline.label) Pipeline")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Int(state.overallProgress * 100))%")
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .foregroundStyle(Color(hex: state.stage.phase.color))
                    }

                    // Progress
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Stage: \(state.stage.label)")
                            .font(.subheadline.bold())
                        if state.stage.phase == .hydra {
                            Text("Hydra Cycle \(state.hydraCycle) of \(state.hydraMaxCycles)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if state.stage.phase == .adversarial {
                            Text("Review Round \(state.adversarialRounds) of \(state.adversarialMaxRounds)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if state.pipeline == .hyevo {
                            HStack(spacing: 12) {
                                Label("Gen \(state.hyevoGeneration)/\(state.hyevoMaxGenerations)", systemImage: "arrow.triangle.2.circlepath")
                                Label("Fitness \(Int(state.hyevoBestFitness * 100))%", systemImage: "chart.line.uptrend.xyaxis")
                                Label("\(state.hyevoTotalWorkflows) DAGs", systemImage: "point.3.connected.trianglepath.dotted")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        ProgressView(value: state.overallProgress)
                            .tint(Color(hex: state.stage.phase.color))
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    // HyEvo DAG Visualization
                    if state.pipeline == .hyevo {
                        let dag = FleetEvolutionClient.shared.activeDAGs[state.id]
                            ?? WorkflowDAG.linearSeed(appId: state.id)
                        let pop = FleetEvolutionClient.shared.populations[state.id]
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Workflow DAG")
                                .font(.headline)
                            WorkflowDAGView(dag: dag, population: pop)
                                .frame(height: 400)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }

                    // Actions
                    HStack(spacing: 12) {
                        Button {
                            Task { await client.advance(appId: state.id) }
                        } label: {
                            Label("Advance", systemImage: "forward.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.stage == .complete || state.stage == .failed)

                        Button {
                            Task { await client.markComplete(appId: state.id) }
                        } label: {
                            Label("Complete", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }

                    // Task List
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Tasks")
                                .font(.headline)
                            Spacer()
                            Text(state.tasksSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if state.tasks.isEmpty {
                            Text("No tasks generated yet. Tasks appear as the pipeline runs.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(state.tasks) { task in
                                taskRow(task)
                            }
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

                    // Dispatch Info
                    if let machine = state.dispatchMachine {
                        HStack {
                            Label("Running on", systemImage: "desktopcomputer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(machine)
                                .font(.caption.bold())
                            if let taskId = state.dispatchTaskId {
                                Text(taskId.prefix(8) + "...")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }

                    if let error = state.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding()
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding()
            }
            .navigationTitle(app?.name ?? state.id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await client.fetchTasksFromSupabase(appId: state.id)
            }
        }
    }

    private func taskRow(_ task: EvolutionTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: task.status == .complete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(task.status == .complete ? .green : .secondary)
                .onTapGesture {
                    if task.status != .complete {
                        Task { await client.completeTask(appId: state.id, taskId: task.id) }
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(task.description)
                    .font(.subheadline)
                    .strikethrough(task.status == .complete)
                HStack(spacing: 6) {
                    Text(task.priorityLabel)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(task.priority <= 2 ? .red : .secondary)
                    Text(task.source.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Enqueue Sheet

struct EnqueueSheet: View {
    @State private var client = FleetEvolutionClient.shared
    @State private var selectedApps: Set<String> = []
    @State private var pipelineOverride: EvolutionPipeline?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                pipelineSection
                appsSection
            }
            .navigationTitle("Enqueue Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    enqueueButton
                }
            }
        }
    }

    private var pipelineSection: some View {
        Section {
            Picker("Pipeline", selection: $pipelineOverride) {
                Text("Auto (by stage)").tag(nil as EvolutionPipeline?)
                ForEach(EvolutionPipeline.allCases, id: \.self) { p in
                    Label(p.label, systemImage: p.icon).tag(p as EvolutionPipeline?)
                }
            }
        }
    }

    private var appsSection: some View {
        Section("Apps") {
            ForEach(AppAgent.fleet, id: \.id) { agent in
                enqueueRow(agent)
            }
        }
    }

    private func enqueueRow(_ agent: AppAgent) -> some View {
        let isQueued = client.states[agent.id] != nil
        let isSelected = selectedApps.contains(agent.id)
        return HStack {
            Image(systemName: agent.icon)
                .foregroundStyle(isQueued ? Color.green : Color.primary)
            Text(agent.name)
            Spacer()
            if isQueued {
                Text("Queued").font(.caption).foregroundStyle(.green)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isQueued else { return }
            if isSelected { selectedApps.remove(agent.id) } else { selectedApps.insert(agent.id) }
        }
    }

    private var enqueueButton: some View {
        Button("Enqueue \(selectedApps.count)") {
            for appId in selectedApps {
                if let override = pipelineOverride {
                    client.enqueue(appId: appId, pipeline: override)
                } else if let agent = AppAgent.fleet.first(where: { $0.id == appId }) {
                    client.enqueueAuto(app: agent)
                }
            }
            dismiss()
        }
        .disabled(selectedApps.isEmpty)
        .fontWeight(.bold)
    }
}

// MARK: - Identifiable Conformance

extension AppEvolutionState: Equatable {
    static func == (lhs: AppEvolutionState, rhs: AppEvolutionState) -> Bool {
        lhs.id == rhs.id && lhs.stage == rhs.stage && lhs.overallProgress == rhs.overallProgress
    }
}

// MARK: - Color Extension

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
