import SwiftUI

struct ConsentView: View {
    @AppStorage("has_accepted_privacy") private var hasAccepted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy & Data Disclosure")
                    .font(.headline)

                Text("WatchBuddy sends your data to third-party services to function. Please review what is shared:")
                    .font(.footnote)

                // --- Data item 1: Voice recording ---
                dataRow(
                    icon: "mic.fill",
                    color: .blue,
                    title: "Voice Recording",
                    detail: "Your voice audio is sent to a speech-to-text server you configure in Settings for transcription."
                )

                // --- Data item 2: Transcribed text to AI ---
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Transcribed Text")
                            .font(.footnote).bold()
                    } icon: {
                        Image(systemName: "brain")
                            .foregroundColor(.purple)
                    }
                    Text("Your transcribed text is sent to a third-party AI service to generate a response. The AI provider is one of:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("- Google Gemini (Google LLC)")
                        Text("- OpenAI (OpenAI, Inc.)")
                        Text("- Anthropic (Anthropic, PBC)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(8)

                // --- Data item 3: AI response to TTS ---
                dataRow(
                    icon: "speaker.wave.2.fill",
                    color: .orange,
                    title: "AI Response Text",
                    detail: "The AI-generated response text is sent to the speech server for text-to-speech conversion."
                )

                // --- Storage note ---
                dataRow(
                    icon: "lock.shield",
                    color: .green,
                    title: "No Data Stored",
                    detail: "All data is processed in real time and discarded. The app does not store recordings, transcriptions, or AI responses."
                )

                Divider()

                Text("By tapping \"I Agree\" below, you consent to the data sharing described above. You can review the full privacy policy at any time from Settings.")
                    .font(.caption2)
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

    private func dataRow(icon: String, color: Color, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
                    .font(.footnote).bold()
            } icon: {
                Image(systemName: icon)
                    .foregroundColor(color)
            }
            Text(detail)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.15))
        .cornerRadius(8)
    }
}
