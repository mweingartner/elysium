import SwiftUI
import ElysiumCore

struct RPGPathSelectionView: View {
    @Bindable var model: RPGNativeViewModel

    private let columns = [GridItem(.adaptive(minimum: 270), spacing: RPGNativeDesign.cardSpacing)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RPGNativeDesign.sectionSpacing) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Choose your role")
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        Text("A path defines your core play style, level growth, and the activities that earn experience. You’ll specialize next.")
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: columns, alignment: .leading,
                              spacing: RPGNativeDesign.cardSpacing) {
                        ForEach(RPG_PATH_DEFINITIONS, id: \.id) { path in
                            let selected = model.pendingPathID == path.id
                            let identity = rpgPathIdentity(pathID: path.id)
                            SwiftUI.Button {
                                model.pendingPathID = path.id
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(alignment: .center) {
                                        Image(systemName: RPGNativeDesign.pathSymbol(path.id))
                                            .font(.title2)
                                            .foregroundStyle(.tint)
                                            .frame(width: 28)
                                        Text(path.displayName)
                                            .font(.title2)
                                            .fontWeight(.semibold)
                                        Spacer()
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                            .accessibilityHidden(true)
                                    }
                                    Text(identity?.purpose ?? path.summary)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let identity {
                                        Text(identity.playLoop)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Divider()
                                    Label(rpgPathGrowthLine(path.id), systemImage: "heart.text.square")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                                .background(selected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                                .overlay {
                                    RoundedRectangle(cornerRadius: RPGNativeDesign.cardRadius)
                                        .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.22),
                                                lineWidth: selected ? 2 : 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: RPGNativeDesign.cardRadius))
                                .contentShape(RoundedRectangle(cornerRadius: RPGNativeDesign.cardRadius))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(path.displayName), \(selected ? "selected" : "not selected")")
                            .accessibilityValue([
                                identity?.purpose ?? path.summary,
                                identity?.playLoop,
                                rpgPathGrowthLine(path.id),
                            ].compactMap { $0 }.joined(separator: " "))
                            .accessibilityHint("Select this path. Its exact class XP rules appear below.")
                        }
                    }

                    if let identity = rpgPathIdentity(pathID: model.pendingPathID),
                       let path = rpgPathDefinition(model.pendingPathID) {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(identity.playLoop)
                                    .foregroundStyle(.secondary)
                                ForEach(Array(identity.progressionCriteria.enumerated()),
                                        id: \.element.eventKind) { index, criterion in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(criterion.title)
                                                .font(.headline)
                                            Spacer()
                                            Text(criterion.reward)
                                                .font(.subheadline)
                                                .fontWeight(.semibold)
                                                .foregroundStyle(.tint)
                                        }
                                        Text(criterion.criterion)
                                        Text(criterion.limit)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .accessibilityElement(children: .combine)
                                    if index + 1 < identity.progressionCriteria.count {
                                        Divider()
                                    }
                                }
                            }
                            .padding(4)
                        } label: {
                            Label("How \(path.displayName) Earns Class XP",
                                  systemImage: "chart.line.uptrend.xyaxis")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                    }
                }
                .padding(RPGNativeDesign.contentPadding)
            }

            Divider()
            HStack {
                SwiftUI.Button("Cancel") { model.requestClose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                SwiftUI.Button("Continue") { model.choosePendingPath() }
                    .keyboardShortcut(.defaultAction)
                    .help("Continue to sub-class selection")
            }
            .padding(RPGNativeDesign.contentPadding)
        }
    }
}
