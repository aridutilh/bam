import Foundation

/// Apple events may arrive before or after startup decides which process owns
/// the profile. Connect once to either the local browser or the duplicate relay.
@MainActor final class ExternalURLDelivery {
    private var pending: [URL] = []
    private var destination: (([URL]) -> Void)?

    func receive(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let destination { destination(urls) }
        else { pending.append(contentsOf: urls) }
    }

    func connect(to destination: @escaping ([URL]) -> Void) {
        self.destination = destination
        let queued = pending
        pending.removeAll()
        if !queued.isEmpty { destination(queued) }
    }
}
