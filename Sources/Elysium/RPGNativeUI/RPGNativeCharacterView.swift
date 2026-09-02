import SwiftUI

struct RPGNativeCharacterView: View {
    @Bindable var model: RPGNativeViewModel

    var body: some View {
        Group {
            if model.state.created {
                if let page = model.tutorialPage {
                    RPGTutorialView(model: model, page: page)
                } else {
                    RPGCharacterWorkspaceView(model: model)
                }
            } else {
                RPGCreationWorkspaceView(model: model)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        .alert("Discard Character Draft?", isPresented: $model.showsDiscardConfirmation) {
            SwiftUI.Button("Cancel", role: .cancel) {}
            SwiftUI.Button("Discard Draft", role: .destructive) {
                model.discardAndClose()
            }
        } message: {
            Text("Your path, sub-class, and starting-skill choices have not been saved.")
        }
        .onExitCommand {
            model.handleEscape()
        }
    }
}
