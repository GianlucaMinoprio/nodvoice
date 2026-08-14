import SwiftUI
import UIKit

/// SuperGrok login. Opens the approve link and polls until you finish in the browser.
struct SuperGrokSignInView: View {
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var login: SuperGrokDeviceLogin?
    @State private var status = "Opening SuperGrok…"
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
                } else {
                    ContentUnavailableView(
                        "Approve SuperGrok",
                        systemImage: "person.crop.circle.badge.checkmark",
                        description: Text("Finish sign-in in the browser. This screen waits for you.")
                    )
                    if let login {
                        Button {
                            UIApplication.shared.open(login.verificationURL)
                        } label: {
                            Label("Open SuperGrok", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    }
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
        status = "Opening SuperGrok…"
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
