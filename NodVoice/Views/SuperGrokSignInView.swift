import SwiftUI
import UIKit

/// Device-code SuperGrok login. Opens Safari; the app polls until you approve.
struct SuperGrokSignInView: View {
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var login: SuperGrokDeviceLogin?
    @State private var status = "Starting SuperGrok sign-in…"
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let errorText {
                    ContentUnavailableView(
                        "Couldn’t sign in",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorText)
                    )
                    Button("Try again") { start() }
                        .buttonStyle(.borderedProminent)
                } else if let login {
                    Text("Enter this code on xAI")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(login.userCode)
                        .font(.largeTitle.monospaced().weight(.bold))
                        .textSelection(.enabled)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)

                    Button {
                        UIPasteboard.general.string = login.userCode
                    } label: {
                        Label("Copy code", systemImage: "doc.on.doc")
                    }

                    Button {
                        openURL(login.verificationURL)
                    } label: {
                        Label("Open xAI to approve", systemImage: "safari")
                    }
                    .buttonStyle(.borderedProminent)

                    ProgressView(status)
                        .padding(.top, 8)
                } else {
                    ProgressView(status)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("SuperGrok")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pollTask?.cancel()
                        dismiss()
                    }
                }
            }
            .onAppear { start() }
            .onDisappear { pollTask?.cancel() }
        }
    }

    private func start() {
        pollTask?.cancel()
        errorText = nil
        login = nil
        status = "Starting SuperGrok sign-in…"
        pollTask = Task {
            do {
                let started = try await SuperGrokAuth.shared.startDeviceLogin()
                guard !Task.isCancelled else { return }
                login = started
                status = "Waiting for approval…"
                await MainActor.run {
                    UIApplication.shared.open(started.verificationURL)
                }
                try await SuperGrokAuth.shared.pollUntilAuthorized(started)
                guard !Task.isCancelled else { return }
                onFinished()
                dismiss()
            } catch is CancellationError {
                // ignore
            } catch {
                guard !Task.isCancelled else { return }
                errorText = error.localizedDescription
            }
        }
    }
}
