import SwiftUI

struct AIConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var connection=ConnectionStatus()
    @State private var key=""
    @State private var message=""
    var body: some View {
        VStack(spacing:24) {
            Text("Private demo connection").font(.title2.bold())
            Text("The Gemini API key stays in this iPhone's Keychain. It is not included in the app or repository.").font(.body)
            SecureField("Gemini API key",text:$key).textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive().accessibilityIdentifier("demoKeyField")
            Button("Save and test") {
                do { try DemoAccess.save(key.trimmingCharacters(in:.whitespacesAndNewlines)); key=""; Task { await connection.check() } }
                catch { message=error.localizedDescription }
            }.disabled(key.isEmpty || connection.checking).frame(minHeight:48)
            Button("Test saved connection") { Task { await connection.check() } }.disabled(!DemoAccess.configured || connection.checking).frame(minHeight:48)
            Text(message.isEmpty ? connection.state : message).accessibilityIdentifier("connectionResult")
            Button("Remove demo key") { try? DemoAccess.save(""); message="Demo key removed" }.frame(minHeight:48)
            Button("Done") { dismiss() }.frame(minHeight:48)
            Spacer()
        }.padding(24)
    }
}
