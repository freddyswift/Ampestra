import Darwin
import Combine
import Foundation
import Network

@MainActor
public final class KEFDiscovery: ObservableObject {
    private struct ServiceResolutionID: Hashable {
        var name: String
        var type: String
        var domain: String
    }

    @Published public var speakers: [DiscoveredSpeaker] = []
    @Published public var isSearching = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastStartedAt: Date?

    public var localNetworkAccessDeniedHandler: (() -> Void)?

    private var httpBrowser: NWBrowser?
    private var raopBrowser: NWBrowser?
    private var stopTask: Task<Void, Never>?
    private var discoveredMACs: [String: String] = [:]
    private var scheduledHTTPServices: Set<ServiceResolutionID> = []
    private var discoveryGeneration = 0

    public init() {}

    public func startDiscovery() {
        stopDiscovery()
        discoveryGeneration += 1
        let generation = discoveryGeneration

        speakers = []
        discoveredMACs = [:]
        scheduledHTTPServices = []
        lastError = nil
        lastStartedAt = Date()
        isSearching = true

        let params = NWParameters()
        params.includePeerToPeer = true

        // RAOP service names commonly include the hardware MAC address as
        // `AABBCCDDEEFF@Speaker Name`. The HTTP API service does not include
        // that MAC, so discovery watches both service families and joins them
        // by normalized speaker name when both are visible.
        raopBrowser = NWBrowser(for: .bonjour(type: "_raop._tcp", domain: nil), using: params)
        raopBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      let parsedService = Self.parseRAOPServiceName(name) else { continue }

                Task { @MainActor in
                    self?.recordMAC(
                        parsedService.macAddress,
                        for: parsedService.speakerName,
                        generation: generation
                    )
                }
            }
        }
        raopBrowser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleBrowserState(state, label: "RAOP", generation: generation)
            }
        }
        raopBrowser?.start(queue: .global(qos: .utility))

        httpBrowser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: params)
        httpBrowser?.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case .service(let name, let type, let domain, _) = result.endpoint,
                      Self.isLikelyKEFSpeakerService(name) else { continue }

                Task { @MainActor in
                    self?.scheduleServiceResolution(
                        name: name,
                        type: type,
                        domain: domain,
                        generation: generation
                    )
                }
            }
        }
        httpBrowser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleBrowserState(state, label: "HTTP", generation: generation)
            }
        }
        httpBrowser?.start(queue: .global(qos: .utility))

        stopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            self?.stopDiscovery(generation: generation)
        }
    }

    public func stopDiscovery() {
        discoveryGeneration += 1
        stopCurrentDiscovery()
    }

    private func stopDiscovery(generation: Int) {
        guard generation == discoveryGeneration else { return }
        discoveryGeneration += 1
        stopCurrentDiscovery()
    }

    private func stopCurrentDiscovery() {
        stopTask?.cancel()
        stopTask = nil
        httpBrowser?.cancel()
        httpBrowser = nil
        raopBrowser?.cancel()
        raopBrowser = nil
        isSearching = false
    }

    private func recordMAC(_ macAddress: String, for speakerName: String, generation: Int) {
        guard generation == discoveryGeneration else { return }

        let normalizedName = Self.normalizedServiceName(speakerName)
        guard discoveredMACs[normalizedName] != macAddress else { return }
        discoveredMACs[normalizedName] = macAddress

        guard let index = speakers.firstIndex(where: {
            Self.normalizedServiceName($0.name) == normalizedName && $0.macAddress == nil
        }) else {
            return
        }

        let speaker = speakers[index]
        speakers[index] = DiscoveredSpeaker(
            id: speaker.id,
            name: speaker.name,
            host: speaker.host,
            macAddress: macAddress
        )
    }

    private func addSpeaker(name: String, host: String) {
        guard let normalizedHost = ManualHostValidator.normalizedDiscoveryHost(host) else { return }

        let displayName = Self.displayName(fromServiceName: name)
        let macAddress = discoveredMACs[Self.normalizedServiceName(name)]

        if let index = speakers.firstIndex(where: { $0.host == normalizedHost }) {
            guard speakers[index].macAddress == nil, let macAddress else { return }

            let speaker = speakers[index]
            speakers[index] = DiscoveredSpeaker(
                id: speaker.id,
                name: displayName,
                host: speaker.host,
                macAddress: macAddress
            )
            return
        }

        speakers.append(
            DiscoveredSpeaker(id: normalizedHost, name: displayName, host: normalizedHost, macAddress: macAddress)
        )
    }

    private func handleBrowserState(_ state: NWBrowser.State, label: String, generation: Int) {
        guard generation == discoveryGeneration else { return }

        switch state {
        case .waiting(let error) where Self.isLocalNetworkPolicyDenied(error):
            lastError = "Local Network access is off."
            localNetworkAccessDeniedHandler?()
            stopDiscovery(generation: generation)
        case .failed(let error):
            lastError = "\(label) discovery failed: \(error.localizedDescription)"
            isSearching = false
        case .cancelled:
            break
        default:
            break
        }
    }

    public nonisolated static func isLocalNetworkPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let errorCode) = error else { return false }
        return errorCode == kDNSServiceErr_PolicyDenied
    }

    /// Resolve a Bonjour service to an IPv4 address using dns_sd APIs.
    ///
    /// NWConnection's IP resolution can return IPv6-only on some networks,
    /// so we use DNSServiceResolve to get the actual .local hostname, then
    /// getaddrinfo to look up the IPv4 address.
    private func scheduleServiceResolution(name: String, type: String, domain: String, generation: Int) {
        guard generation == discoveryGeneration else { return }

        let id = ServiceResolutionID(name: name, type: type, domain: domain)
        guard scheduledHTTPServices.insert(id).inserted else { return }

        let resolutionTask = Task.detached(priority: .utility) { () -> String? in
            guard let hostname = Self.resolveServiceHostname(name: name, type: type, domain: domain) else {
                return nil
            }
            return Self.resolveToIPv4(hostname) ?? hostname
        }

        Task { @MainActor [weak self] in
            guard let host = await resolutionTask.value,
                  let self,
                  self.discoveryGeneration == generation else { return }
            self.addSpeaker(name: name, host: host)
        }
    }

    public nonisolated static func isLikelyKEFSpeakerService(_ name: String) -> Bool {
        let uppercasedName = normalizedServiceName(name).uppercased()
        return uppercasedName.contains("LSX") ||
            uppercasedName.contains("LS50") ||
            uppercasedName.contains("LS60") ||
            uppercasedName.contains("KEF")
    }

    public nonisolated static func parseRAOPServiceName(_ name: String) -> (speakerName: String, macAddress: String)? {
        guard isLikelyKEFSpeakerService(name),
              let separatorIndex = name.firstIndex(of: "@") else {
            return nil
        }

        let rawMAC = String(name[..<separatorIndex])
        guard rawMAC.count == 12, rawMAC.allSatisfy(\.isHexDigit) else {
            return nil
        }

        let macAddress = stride(from: 0, to: 12, by: 2)
            .map { offset -> String in
                let start = rawMAC.index(rawMAC.startIndex, offsetBy: offset)
                let end = rawMAC.index(start, offsetBy: 2)
                return String(rawMAC[start..<end])
            }
            .joined(separator: ":")
        let speakerName = String(name[name.index(after: separatorIndex)...])

        return (speakerName, macAddress)
    }

    public nonisolated static func normalizedServiceName(_ name: String) -> String {
        displayName(fromServiceName: name)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    public nonisolated static func displayName(fromServiceName name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Use DNSServiceResolve to get the .local hostname for a Bonjour service.
    nonisolated static func resolveServiceHostname(name: String, type: String, domain: String) -> String? {
        class Box { var value: String? }
        let box = Box()
        var sdRef: DNSServiceRef?

        let callback: DNSServiceResolveReply = {
            _, _, _, errorCode, _, hosttarget, _, _, _, context in
            guard errorCode == kDNSServiceErr_NoError,
                  let hosttarget,
                  let context else { return }
            let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
            box.value = String(cString: hosttarget)
        }

        let err = DNSServiceResolve(
            &sdRef, 0, 0,
            name, type, domain,
            callback,
            Unmanaged.passUnretained(box).toOpaque()
        )
        guard err == kDNSServiceErr_NoError, let sdRef else { return nil }
        defer { DNSServiceRefDeallocate(sdRef) }

        // Wait for the resolve callback (up to 5 seconds)
        let fd = DNSServiceRefSockFD(sdRef)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, 5000) > 0 {
            DNSServiceProcessResult(sdRef)
        }

        return box.value.map(normalizedHostname)
    }

    /// Use getaddrinfo to resolve a hostname to an IPv4 address.
    nonisolated static func resolveToIPv4(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(hostname, nil, &hints, &result) == 0, let addr = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            addr.pointee.ai_addr, socklen_t(addr.pointee.ai_addrlen),
            &buf, socklen_t(buf.count),
            nil, 0, NI_NUMERICHOST
        ) == 0 else { return nil }

        return String(cString: buf)
    }

    public nonisolated static func normalizedHostname(_ hostname: String) -> String {
        var normalized = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix(".") {
            normalized.removeLast()
        }
        return normalized.lowercased()
    }
}
