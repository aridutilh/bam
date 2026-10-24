import Foundation

/// One quit decision owns confirmation and the asynchronous save barrier.
/// Cancel never tears down pages; only the application's final termination does.
@MainActor final class QuitCoordinator {
    enum SaveFailureChoice { case cancel, retry, quitWithoutSaving }
    private(set) var isPending = false

    func request(confirmation: @escaping @MainActor () -> Bool,
                 save: @escaping @MainActor () async -> Bool,
                 saveFailure: @escaping @MainActor () -> SaveFailureChoice,
                 reply: @escaping @MainActor (Bool) -> Void) {
        guard !isPending else { return }
        isPending = true
        // Return terminateLater before entering a modal loop. A second Quit
        // request during either the dialog or the save shares this same flow.
        Task { @MainActor in
            guard confirmation() else { finish(false, reply: reply); return }
            while true {
                if await save() { finish(true, reply: reply); return }
                switch saveFailure() {
                case .retry: continue
                case .quitWithoutSaving: finish(true, reply: reply); return
                case .cancel: finish(false, reply: reply); return
                }
            }
        }
    }

    private func finish(_ shouldQuit: Bool, reply: (Bool) -> Void) {
        if !shouldQuit { isPending = false }
        reply(shouldQuit)
    }
}
