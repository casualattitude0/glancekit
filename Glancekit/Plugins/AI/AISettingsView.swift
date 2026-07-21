import SwiftUI
import Observation

/// Settings page for the AI Assistant glance: pick a provider, paste that
/// company's key, and choose a model. The key is stored in `CredentialStore`
/// (per provider, so switching companies keeps each key); everything else is
/// non-secret config the store persists on change. A live status line spells out
/// what's still missing.
///
/// Matches the GitHub settings page: a headline, an explanatory caption, then
/// the fields, saving on each change so there's no separate "Save" button.
struct AISettingsView: View {
    @Bindable private var store = AIConfigStore.shared

    /// Selecting a provider goes through `selectProvider(id:)` so the model,
    /// base URL, and stored key all follow the switch.
    private var providerSelection: Binding<String> {
        Binding(get: { store.providerID }, set: { store.selectProvider(id: $0) })
    }

    var body: some View {
        SettingsPage(
            "AI Assistant",
            intro: "Connect a provider so the assistant can answer in the popover. Your API key is stored in Glancekit's credentials file (readable only by your macOS account), never in app preferences."
        ) {
            Picker("Provider", selection: providerSelection) {
                ForEach(AIProvider.catalog) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            VStack(alignment: .leading, spacing: 8) {
                if store.provider.requiresAPIKey {
                    LabeledField("API Key") {
                        SecureField("Paste your \(store.provider.name) key", text: $store.apiKey)
                            .textFieldStyle(.roundedBorder)
                        if let link = store.provider.apiKeysURL, let url = URL(string: link) {
                            Link("Get an API key", destination: url)
                                .font(.caption)
                        }
                    }
                }

                LabeledField("Model") {
                    HStack(spacing: 6) {
                        TextField(modelPlaceholder, text: $store.model)
                            .textFieldStyle(.roundedBorder)
                        // A quick menu of the provider's known models; the field
                        // stays free-text so a newer id can always be typed.
                        if !store.provider.models.isEmpty {
                            Menu {
                                ForEach(store.provider.models, id: \.self) { name in
                                    Button(name) { store.model = name }
                                }
                            } label: {
                                Image(systemName: "list.bullet")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Suggested models")
                        }
                    }
                }

                // Only Custom / local endpoints need a base URL; the fixed
                // providers hide the field to keep the form honest.
                if store.provider.requiresBaseURL {
                    LabeledField("Base URL") {
                        TextField(store.provider.defaultBaseURL, text: $store.baseURL)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledField("Max reply length") {
                    HStack(spacing: 8) {
                        // Stepper rather than a free text field: the value is a
                        // spending cap, and the useful range is narrow enough
                        // that typing an arbitrary number invites a 402 or a
                        // truncated answer.
                        Stepper(
                            value: $store.maxOutputTokens,
                            in: AIConfigStore.minOutputTokens...AIConfigStore.maxOutputTokensCeiling,
                            step: 256
                        ) {
                            Text("\(store.resolvedMaxOutputTokens) tokens")
                                .monospacedDigit()
                        }
                        Spacer()
                    }
                }
                Text("The longest reply the assistant may write. Pay-as-you-go gateways reserve this whole amount before answering and refuse the request if your balance can't cover it — lower it if you hit a credit error. The Smart Panel's one-line summary always uses far less.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $store.systemPrompt)
                    .font(.callout)
                    .frame(minHeight: 90)
                    .padding(4)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                Text("Sets the assistant's persona and instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            statusLine

            Divider()

            MCPSettingsView()
        }
    }

    private var modelPlaceholder: String {
        store.provider.models.first ?? "model id"
    }

    @ViewBuilder
    private var statusLine: some View {
        if store.isConfigured {
            Label("Configured", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label(missingHint, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    /// What's left before `isConfigured` flips true — mirrors the store's rule
    /// (model, plus a key and/or base URL depending on the provider).
    private var missingHint: String {
        var missing: [String] = []
        let provider = store.provider
        if provider.requiresAPIKey,
           store.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("API key") }
        if store.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("model") }
        if provider.requiresBaseURL,
           store.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("base URL") }
        if missing.isEmpty { return "Almost there…" }
        return "Add a " + missing.joined(separator: ", ") + " to finish."
    }
}

// `LabeledField` now lives in `SettingsKit` and is shared across the form pages.
