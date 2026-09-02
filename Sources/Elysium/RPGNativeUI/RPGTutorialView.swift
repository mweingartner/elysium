import SwiftUI
import ElysiumCore

struct RPGTutorialView: View {
    let model: RPGNativeViewModel
    let page: Int

    private var isLastPage: Bool { page == RPG_TUTORIAL_PAGES.count }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 30)
            VStack(spacing: 24) {
                Image(systemName: tutorialSymbol)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 84, height: 84)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text(tutorialTitle)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text("Step \(page) of \(RPG_TUTORIAL_PAGES.count)")
                        .foregroundStyle(.secondary)
                }

                Text(RPG_TUTORIAL_PAGES[page - 1])
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560)

                ProgressView(value: Double(page), total: Double(RPG_TUTORIAL_PAGES.count))
                    .frame(maxWidth: 360)
                    .accessibilityLabel("Tutorial progress")
            }
            .padding(40)
            Spacer(minLength: 30)

            Divider()
            HStack {
                SwiftUI.Button("Close") {
                    _ = model.perform(.back)
                }
                SwiftUI.Button("Skip Tutorial") {
                    _ = model.perform(.tutorialSkip)
                }
                Spacer()
                if page > 1 {
                    SwiftUI.Button("Back") {
                        _ = model.perform(.tutorialBack)
                    }
                }
                SwiftUI.Button(isLastPage ? "Finish" : "Next") {
                    _ = model.perform(isLastPage ? .tutorialFinish : .tutorialNext)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(RPGNativeDesign.contentPadding)
        }
        .navigationTitle("Character Tutorial")
    }

    private var tutorialTitle: String {
        switch page {
        case 1: return "Build Your Sub-class"
        case 2: return "Prepare Actions"
        case 3: return "Set Quick Slots"
        default: return "Use Your Loadout"
        }
    }

    private var tutorialSymbol: String {
        switch page {
        case 1: return "point.3.connected.trianglepath.dotted"
        case 2: return "bolt.circle"
        case 3: return "square.grid.3x3.fill"
        default: return "keyboard"
        }
    }
}
