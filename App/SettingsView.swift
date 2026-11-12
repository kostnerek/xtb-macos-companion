import SwiftUI

/// Login and password for the automatic login. Saved to the keychain; the password is never
/// shown again after saving.
struct SettingsView: View {
    let onSave: () -> Void
    @State private var username = Keychain.username() ?? ""
    @State private var password = ""

    var body: some View {
        Form {
            TextField("Login XTB", text: $username)
            SecureField("Hasło", text: $password)
            Text("Hasło trafia do pęku kluczy macOS. Aplikacja używa go tylko wtedy, gdy xStation poprosi o logowanie.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Zapisz i odśwież") {
                    Keychain.save(username: username, password: password)
                    password = ""
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(username.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
