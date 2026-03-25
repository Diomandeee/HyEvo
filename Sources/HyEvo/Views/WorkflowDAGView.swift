import SwiftUI

/// Visualizes a HyEvo workflow DAG with force-directed layout,
/// hybrid node indicators (LLM vs Code), and animated edge flow.
struct WorkflowDAGView: View {
    let dag: WorkflowDAG
    let population: WorkflowPopulation?
    var onNodeTap: ((WorkflowNode) -> Void)?

    @State private var nodePositions: [String: CGPoint] = [:]
    @State private var selectedNode: WorkflowNode?
    @State private var showPopulationSheet = false

    var body: some View {
        VStack(spacing: 0) {
            dagHeader
            GeometryReader { geo in
                ZStack {
                    // Background grid
                    dagBackground(size: geo.size)

                    // Edges
                    ForEach(dag.edges) { edge in
                        edgeLine(edge, in: geo.size)
                    }

                    // Nodes
                    ForEach(dag.nodes) { node in
                        nodeView(node)
                            .position(positionFor(node, in: geo.size))
                    }
                }
            }
            .frame(minHeight: 300)
            .clipped()

            if let population {
                populationBar(population)
            }
        }
        .onAppear { layoutNodes() }
        .sheet(item: $selectedNode) { node in
            NodeDetailSheet(node: node, dag: dag)
        }
        .sheet(isPresented: $showPopulationSheet) {
            if let population {
                PopulationDetailSheet(population: population)
            }
        }
    }

    // MARK: - Header

    private var dagHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(dag.name)
                    .font(.custom("Quicksand-Bold", size: 16))
                HStack(spacing: 12) {
                    Label("\(dag.nodes.count) nodes", systemImage: "circle.grid.3x3")
                    Label("\(dag.edges.count) edges", systemImage: "arrow.right")
                    Label("Gen \(dag.generation)", systemImage: "arrow.triangle.2.circlepath")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            fitnessGauge
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var fitnessGauge: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Color(.tertiarySystemFill), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: dag.fitness)
                    .stroke(fitnessColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(dag.fitness * 100))")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(fitnessColor)
            }
            .frame(width: 36, height: 36)
            Text("Fitness")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var fitnessColor: Color {
        if dag.fitness >= 0.8 { return Color(hex: "10B981") } // green
        if dag.fitness >= 0.5 { return Color(hex: "F59E0B") } // amber
        return Color(hex: "EF4444") // red
    }

    // MARK: - Background

    private func dagBackground(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let spacing: CGFloat = 30
            for x in stride(from: 0, to: canvasSize.width, by: spacing) {
                for y in stride(from: 0, to: canvasSize.height, by: spacing) {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                        with: .color(.primary.opacity(0.05))
                    )
                }
            }
        }
    }

    // MARK: - Edge Rendering

    private func edgeLine(_ edge: WorkflowEdge, in size: CGSize) -> some View {
        let from = positionFor(nodeById(edge.sourceId), in: size)
        let to = positionFor(nodeById(edge.targetId), in: size)

        return ZStack {
            // Edge line
            Path { path in
                path.move(to: from)
                let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                path.addQuadCurve(to: to, control: CGPoint(x: mid.x, y: mid.y - 20))
            }
            .stroke(
                edgeColor(edge),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: edge.condition == .onFailure ? [4, 4] : [])
            )

            // Arrow indicator
            arrowHead(from: from, to: to)
                .fill(edgeColor(edge))
        }
    }

    private func edgeColor(_ edge: WorkflowEdge) -> Color {
        switch edge.condition {
        case .always:    return .primary.opacity(0.3)
        case .onSuccess: return Color(hex: "10B981").opacity(0.5)
        case .onFailure: return Color(hex: "EF4444").opacity(0.5)
        }
    }

    private func arrowHead(from: CGPoint, to: CGPoint) -> Path {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let arrowLen: CGFloat = 8
        let arrowPoint = CGPoint(
            x: to.x - cos(angle) * 24, // offset from node center
            y: to.y - sin(angle) * 24
        )
        return Path { path in
            path.move(to: arrowPoint)
            path.addLine(to: CGPoint(
                x: arrowPoint.x - arrowLen * cos(angle - .pi / 6),
                y: arrowPoint.y - arrowLen * sin(angle - .pi / 6)
            ))
            path.addLine(to: CGPoint(
                x: arrowPoint.x - arrowLen * cos(angle + .pi / 6),
                y: arrowPoint.y - arrowLen * sin(angle + .pi / 6)
            ))
            path.closeSubpath()
        }
    }

    // MARK: - Node Rendering

    private func nodeView(_ node: WorkflowNode) -> some View {
        let color = Color(hex: node.type.color)
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Circle()
                    .stroke(color, lineWidth: node.status == .running ? 2.5 : 1.5)
                    .frame(width: 44, height: 44)
                Image(systemName: statusIcon(node))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)

                // Running pulse
                if node.status == .running {
                    Circle()
                        .stroke(color.opacity(0.4), lineWidth: 2)
                        .frame(width: 52, height: 52)
                        .scaleEffect(1.3)
                        .opacity(0)
                        .animation(
                            .easeInOut(duration: 1.2).repeatForever(autoreverses: false),
                            value: node.status
                        )
                }

                // Type badge
                Text(node.type.label)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(color, in: Capsule())
                    .offset(x: 18, y: -18)
            }
            Text(node.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
        }
        .onTapGesture {
            selectedNode = node
            onNodeTap?(node)
        }
    }

    private func statusIcon(_ node: WorkflowNode) -> String {
        switch node.status {
        case .pending:  return node.type.icon
        case .running:  return "arrow.trianglehead.clockwise"
        case .complete: return "checkmark"
        case .failed:   return "xmark"
        case .skipped:  return "forward.fill"
        }
    }

    // MARK: - Population Bar

    private func populationBar(_ pop: WorkflowPopulation) -> some View {
        Button {
            showPopulationSheet = true
        } label: {
            HStack(spacing: 16) {
                populationStat("Gen", "\(pop.generation)", Color(hex: "EC4899"))
                populationStat("Islands", "\(pop.islands.count)", Color(hex: "8B5CF6"))
                populationStat("Workflows", "\(pop.totalWorkflows)", Color(hex: "06B6D4"))
                populationStat("Coverage", "\(Int(pop.averageCoverage * 100))%", Color(hex: "F59E0B"))
                populationStat("Best", "\(Int((pop.globalBest?.fitness ?? 0) * 100))%", Color(hex: "10B981"))
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .buttonStyle(.plain)
    }

    private func populationStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Layout

    private func layoutNodes() {
        // Topological layer-based layout
        var layers: [[WorkflowNode]] = []
        var placed = Set<String>()

        // BFS from entry nodes
        var currentLayer = dag.entryNodes
        while !currentLayer.isEmpty {
            layers.append(currentLayer)
            placed.formUnion(currentLayer.map(\.id))
            var nextLayer: [WorkflowNode] = []
            for node in currentLayer {
                for child in dag.downstream(of: node.id) {
                    if !placed.contains(child.id) {
                        // Only add if all parents are placed
                        let allParentsPlaced = dag.upstream(of: child.id).allSatisfy { placed.contains($0.id) }
                        if allParentsPlaced {
                            nextLayer.append(child)
                        }
                    }
                }
            }
            // Deduplicate
            var seen = Set<String>()
            nextLayer = nextLayer.filter { seen.insert($0.id).inserted }
            currentLayer = nextLayer
        }

        // Add any orphan nodes
        let unplaced = dag.nodes.filter { !placed.contains($0.id) }
        if !unplaced.isEmpty {
            layers.append(unplaced)
        }

        // Assign positions
        let layerSpacing: CGFloat = 90
        let nodeSpacing: CGFloat = 100
        for (layerIdx, layer) in layers.enumerated() {
            let y = CGFloat(layerIdx) * layerSpacing + 60
            let totalWidth = CGFloat(layer.count - 1) * nodeSpacing
            let startX = -totalWidth / 2.0
            for (nodeIdx, node) in layer.enumerated() {
                let x = startX + CGFloat(nodeIdx) * nodeSpacing
                nodePositions[node.id] = CGPoint(x: x, y: y)
            }
        }
    }

    private func positionFor(_ node: WorkflowNode?, in size: CGSize) -> CGPoint {
        guard let node, let pos = nodePositions[node.id] else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        return CGPoint(x: size.width / 2 + pos.x, y: pos.y)
    }

    private func nodeById(_ id: String) -> WorkflowNode? {
        dag.nodes.first { $0.id == id }
    }
}

// MARK: - Node Detail Sheet

struct NodeDetailSheet: View {
    let node: WorkflowNode
    let dag: WorkflowDAG
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Type + status
                    HStack {
                        Image(systemName: node.type.icon)
                            .font(.title2)
                            .foregroundStyle(Color(hex: node.type.color))
                        VStack(alignment: .leading) {
                            Text(node.label)
                                .font(.custom("Quicksand-Bold", size: 20))
                            HStack(spacing: 8) {
                                Text(node.type.label)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color(hex: node.type.color).opacity(0.2), in: Capsule())
                                Text(node.status.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 6) {
                        Text(node.type == .llm ? "Prompt" : "Script")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(node.content)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Metadata
                    if let model = node.model {
                        metaRow("Model", model)
                    }
                    metaRow("Timeout", "\(Int(node.timeout))s")
                    metaRow("Retries", "\(node.retries)")
                    if let latency = node.latencyMs {
                        metaRow("Latency", "\(latency)ms")
                    }
                    if let tokens = node.tokenCost {
                        metaRow("Token Cost", "\(tokens)")
                    }

                    // Dependencies
                    let upstream = dag.upstream(of: node.id)
                    let downstream = dag.downstream(of: node.id)
                    if !upstream.isEmpty {
                        depSection("Depends On", nodes: upstream)
                    }
                    if !downstream.isEmpty {
                        depSection("Feeds Into", nodes: downstream)
                    }
                }
                .padding()
            }
            .navigationTitle(node.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.bold())
        }
    }

    private func depSection(_ title: String, nodes: [WorkflowNode]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(nodes) { node in
                HStack(spacing: 8) {
                    Image(systemName: node.type.icon)
                        .font(.caption)
                        .foregroundStyle(Color(hex: node.type.color))
                    Text(node.label)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - Population Detail Sheet

struct PopulationDetailSheet: View {
    let population: WorkflowPopulation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Overview
                    HStack(spacing: 16) {
                        overviewStat("Generation", "\(population.generation)", Color(hex: "EC4899"))
                        overviewStat("Total DAGs", "\(population.totalWorkflows)", Color(hex: "06B6D4"))
                        overviewStat("Best Fitness", String(format: "%.1f%%", (population.globalBest?.fitness ?? 0) * 100), Color(hex: "10B981"))
                    }

                    // Islands
                    Text("Islands")
                        .font(.custom("Quicksand-Bold", size: 18))
                    ForEach(population.islands) { island in
                        islandCard(island)
                    }

                    // Reflections
                    if !population.reflections.isEmpty {
                        Text("Reflections")
                            .font(.custom("Quicksand-Bold", size: 18))
                        ForEach(population.reflections.suffix(5)) { reflection in
                            reflectionCard(reflection)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("MAP-Elites Population")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func overviewStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func islandCard(_ island: EvolutionIsland) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: island.strategy.icon)
                    .foregroundStyle(Color(hex: "EC4899"))
                Text(island.name)
                    .font(.headline)
                Spacer()
                Text(island.strategy.label)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color(hex: "EC4899").opacity(0.15), in: Capsule())
            }

            HStack(spacing: 16) {
                miniStat("Workflows", "\(island.grid.count)")
                miniStat("Best Fit", String(format: "%.0f%%", island.bestFitness * 100))
                miniStat("Coverage", String(format: "%.0f%%", island.coverage * 100))
                miniStat("Gen", "\(island.generation)")
            }

            // Grid coverage visualization
            gridCoverageView(island)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func gridCoverageView(_ island: EvolutionIsland) -> some View {
        // 5x5 grid showing which feature cells are filled
        let gridSize = 5
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(12), spacing: 2), count: gridSize), spacing: 2) {
            ForEach(0..<(gridSize * gridSize), id: \.self) { idx in
                let row = idx / gridSize
                let col = idx % gridSize
                let key = "\(Double(col) / Double(gridSize))-\(Double(row) / Double(gridSize))-0.0"
                let isFilled = island.grid[key] != nil
                Rectangle()
                    .fill(isFilled ? Color(hex: "EC4899").opacity(0.6) : Color(.tertiarySystemFill))
                    .frame(width: 12, height: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
    }

    private func reflectionCard(_ reflection: EvolutionReflection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Gen \(reflection.generation)")
                    .font(.caption.bold())
                    .foregroundStyle(Color(hex: "EC4899"))
                Spacer()
                Text(String(format: "Fitness: %.0f%%", reflection.fitness * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(reflection.analysis)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(reflection.suggestions, id: \.self) { suggestion in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text(suggestion)
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.caption, design: .rounded, weight: .bold))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Identifiable already declared in WorkflowDAG.swift

// MARK: - Color Helper

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
