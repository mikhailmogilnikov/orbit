import OrbitUI
import SwiftUI

struct GitSettingsPane: View {
    @Bindable var model: GitModel

    var body: some View {
        SettingsForm {
            Section {
                Toggle(isOn: $model.showsChangeMarkers) {
                    Text("Change markers")
                    Text("Bars beside the line numbers for lines changed and not yet staged.")
                }
                .settingsItem("changeMarkers")
            } header: {
                Text("Editor")
            } footer: {
                Text("Blame and file history are in Git Lens.")
            }
        }
    }
}
