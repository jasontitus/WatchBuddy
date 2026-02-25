import SwiftUI

struct ConsentView: View {
    @AppStorage("has_accepted_privacy") private var hasAccepted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy Disclosure")
                    .font(.headline)

                Text("WatchBuddy needs to send data to external services to work:")
                    .font(.footnote)

                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Your voice recordings are sent to a server for speech-to-text processing.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.blue)
                    }

                    Label {
                        Text("Transcribed text is sent to a third-party AI provider (Google Gemini, OpenAI, or Anthropic) to generate a response.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "brain")
                            .foregroundColor(.purple)
                    }

                    Label {
                        Text("Data is processed in real time and is not stored by the app.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.green)
                    }
                }

                Text("By tapping \"I Agree\" you consent to this data processing. You can review the full privacy policy at any time from Settings.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button("I Agree") {
                    hasAccepted = true
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding()
        }
    }
}
