import Foundation

enum SpeakerActionError: LocalizedError, Equatable {
    case stateChangeTimedOut

    var errorDescription: String? {
        switch self {
        case .stateChangeTimedOut:
            "The speaker did not confirm the requested change in time."
        }
    }
}
