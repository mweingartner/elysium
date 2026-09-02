import SwiftUI

struct RPGCharacterWorkspaceView: View {
    @Bindable var model: RPGNativeViewModel

    private var sectionSelection: Binding<RPGNativeCharacterSection?> {
        Binding(
            get: { model.characterSection },
            set: { if let section = $0 { model.selectCharacterSection(section) } }
        )
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sectionSelection) {
                Section {
                    ForEach(RPGNativeCharacterSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                if let identity = model.pathIdentity {
                    Section("Role") {
                        Text(identity.purpose)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: RPGNativeDesign.sidebarWidth, max: 280)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    SwiftUI.Button {
                        model.requestClose()
                    } label: {
                        Label("Close Character", systemImage: "xmark")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
                .background(.bar)
            }
        } detail: {
            VStack(spacing: 0) {
                RPGCharacterHeaderView(model: model)
                if model.status != nil || model.authority.disabledControlExplanation != nil {
                    RPGNativeStatusBanner(authority: model.authority, status: model.status)
                        .padding(.horizontal, RPGNativeDesign.contentPadding)
                        .padding(.bottom, 12)
                }
                Divider()
                switch model.characterSection {
                case .overview: RPGOverviewView(model: model)
                case .skills: RPGSkillsView(model: model)
                case .loadout: RPGLoadoutView(model: model)
                case .progress: RPGProgressView(model: model)
                }
            }
            .navigationTitle(model.characterSection.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    SwiftUI.Button {
                        model.requestClose()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .help("Close Character")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}
