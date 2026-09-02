import SwiftUI
import ElysiumCore

struct RPGCreationWorkspaceView: View {
    @Bindable var model: RPGNativeViewModel

    private var currentStepIndex: Int {
        RPGCreationStep.allCases.firstIndex(of: model.creation.step) ?? 0
    }

    var body: some View {
        NavigationSplitView {
            List {
                Section("Character Creation") {
                    ForEach(Array(RPGCreationStep.allCases.enumerated()), id: \.element) { index, step in
                        let completed = index < currentStepIndex
                        let current = index == currentStepIndex
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(RPGNativeDesign.creationTitle(step))
                                Text("Step \(index + 1) of \(RPGCreationStep.allCases.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: completed ? "checkmark.circle.fill" :
                                  current ? "\(index + 1).circle.fill" : "\(index + 1).circle")
                        }
                        .foregroundStyle(current ? AnyShapeStyle(.primary) :
                            completed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Step \(index + 1), \(RPGNativeDesign.creationTitle(step))")
                        .accessibilityValue(completed ? "Completed" : current ? "Current" : "Upcoming")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: RPGNativeDesign.sidebarWidth, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if model.status != nil || model.authority.disabledControlExplanation != nil {
                    RPGNativeStatusBanner(authority: model.authority, status: model.status)
                        .padding([.horizontal, .top], RPGNativeDesign.contentPadding)
                }
                Group {
                    switch model.creation.step {
                    case .path: RPGPathSelectionView(model: model)
                    case .branch: RPGBranchSelectionView(model: model)
                    case .skills: RPGStartingSkillsView(model: model)
                    case .review: RPGCreationReviewView(model: model)
                    }
                }
            }
            .navigationTitle("Create Character")
        }
        .navigationSplitViewStyle(.balanced)
    }
}
