protocol KEFSpeakerClientFactory {
    func makeClient(host: String) -> KEFSpeakerClient
}

struct LiveKEFSpeakerClientFactory: KEFSpeakerClientFactory {
    func makeClient(host: String) -> KEFSpeakerClient {
        KEFSpeakerAPI(host: host)
    }
}
