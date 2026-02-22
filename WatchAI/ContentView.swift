import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "applewatch")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            Text("WatchAI")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Open WatchAI on your Apple Watch to use the voice assistant.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

#Preview {
    ContentView()
}
