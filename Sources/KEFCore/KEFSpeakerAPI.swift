import Foundation

/// Protocol used by `AppState` and settings code instead of depending directly
/// on a concrete network client. Tests can use lightweight fakes when exercising
/// connection and action flow.
public protocol KEFSpeakerClient: AnyObject, Sendable {
    var host: String { get }

    func getSnapshot() async throws -> SpeakerSnapshot
    func getStatus() async throws -> SpeakerStatus
    func getSource() async throws -> SpeakerSource
    func getVolume() async throws -> Int
    func getSpeakerName() async throws -> String
    func getModel() async throws -> String
    func getPlayerState() async throws -> PlayerState
    func getIsPlaying() async throws -> Bool
    func getNowPlayingInfo() async throws -> NowPlayingInfo
    func setVolume(_ volume: Int) async throws
    func setSource(_ source: SpeakerSource) async throws
    func powerOn() async throws
    func shutdown() async throws
    func togglePlayPause() async throws
    func nextTrack() async throws
    func previousTrack() async throws
    func validateConnection() async throws
    func testConnection() async -> Bool
}

extension KEFSpeakerClient {
    public func validateConnection() async throws {
        guard await testConnection() else {
            throw KEFError.connectionFailed
        }
    }
}

public final class KEFSpeakerAPI: Sendable {
    private static let postSetDataModels: Set<String> = ["LS50WII", "LSXII", "LSXIILT", "LS60"]
    private static let modelAliases: [String: String] = [
        "LS50W2": "LS50WII",
        "LSX2": "LSXII",
        "LSX2LT": "LSXIILT",
    ]
    public static let maximumResponseByteCount = 512 * 1_024
    public static let responseTimeout: TimeInterval = 8

    public let host: String
    private let session: URLSession
    private let modelCache = LockedValue<String?>(nil)
    private let setDataUsesPostCache = LockedValue<Bool?>(nil)
    private let supportsBatchedGetDataCache = LockedValue<Bool?>(nil)

    public convenience init(host: String) {
        self.init(host: host, session: Self.makeDefaultSession())
    }

    init(host: String, session: URLSession) {
        self.host = host
        self.session = session
    }

    deinit {
        session.invalidateAndCancel()
    }

    public static func makeDefaultSession(
        configuration: URLSessionConfiguration = .ephemeral,
        resourceTimeout: TimeInterval = responseTimeout
    ) -> URLSession {
        let config = configuration
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = max(0.1, resourceTimeout)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(
            configuration: config,
            delegate: SpeakerHTTPRedirectPolicy(),
            delegateQueue: nil
        )
    }

    // MARK: - Low-level API

    private func getData(path: String, roles: String = "value") async throws -> [KEFDataEntry] {
        guard var components = URLComponents(string: "http://\(host)/api/getData") else {
            throw KEFError.connectionFailed
        }
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "roles", value: roles),
        ]
        guard let url = components.url else { throw KEFError.connectionFailed }
        let data = try await data(from: url)
        return try Self.decodeDataEntries(data)
    }

    private func getData(paths: [String], roles: String = "value") async throws -> [KEFDataEntry] {
        guard !paths.isEmpty else { return [] }
        return try await getData(path: paths.joined(separator: ","), roles: roles)
    }

    private func firstData(path: String, roles: String = "value") async throws -> KEFDataEntry {
        guard let first = try await getData(path: path, roles: roles).first else {
            throw KEFError.invalidResponse
        }
        return first
    }

    private func setData(path: String, roles: String = "value", value: KEFSetValue) async throws {
        if try await usesPostForSetData() {
            try await postSetData(path: path, roles: roles, value: value)
        } else {
            try await getSetData(path: path, roles: roles, value: value)
        }
    }

    private func getSetData(path: String, roles: String, value: KEFSetValue) async throws {
        guard var components = URLComponents(string: "http://\(host)/api/setData") else {
            throw KEFError.connectionFailed
        }
        let valueData = try JSONEncoder().encode(value)
        guard let valueString = String(data: valueData, encoding: .utf8) else {
            throw KEFError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "roles", value: roles),
            URLQueryItem(name: "value", value: valueString),
        ]
        guard let url = components.url else { throw KEFError.connectionFailed }
        let data = try await data(from: url)
        try validateSetDataResponse(data)
    }

    private func postSetData(path: String, roles: String, value: KEFSetValue) async throws {
        guard let url = URL(string: "http://\(host)/api/setData") else {
            throw KEFError.connectionFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(KEFSetDataRequest(path: path, roles: roles, value: value))

        let data = try await data(for: request)
        try validateSetDataResponse(data)
    }

    private func data(from url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        try validateHTTPResponse(response)
        return try await Self.collect(bytes, maximumByteCount: Self.maximumResponseByteCount)
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        try validateHTTPResponse(response)
        return try await Self.collect(bytes, maximumByteCount: Self.maximumResponseByteCount)
    }

    private static func collect(
        _ bytes: URLSession.AsyncBytes,
        maximumByteCount: Int
    ) async throws -> Data {
        var data = Data()
        data.reserveCapacity(min(maximumByteCount, 16 * 1_024))

        for try await byte in bytes {
            guard data.count < maximumByteCount else {
                throw KEFError.invalidResponse
            }

            data.append(byte)
        }

        return data
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KEFError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw KEFError.apiError("Speaker returned HTTP \(httpResponse.statusCode)")
        }
    }

    private func validateSetDataResponse(_ data: Data) throws {
        guard !data.isEmpty else { return }

        // KEF firmware generations do not share one acknowledgement shape:
        // successful writes may return an object, a scalar `true`, or `null`.
        // Require bounded valid JSON, then reject only an explicit failure or
        // an error payload instead of treating a different success shape as a
        // malformed speaker response.
        let decoder = JSONDecoder()
        decoder.userInfo[.kefJSONDecodingLimits] = KEFJSONDecodingLimits.speakerResponse

        let response: KEFJSONValue
        do {
            response = try decoder.decode(KEFJSONValue.self, from: data)
        } catch {
            throw KEFError.invalidResponse
        }

        if case .bool(false) = response {
            throw KEFError.apiError("Speaker rejected command")
        }

        if case .object(let object) = response,
           let error = object["error"],
           !error.representsNoError {
            let message = error.speakerErrorMessage ?? "Speaker rejected command"
            throw KEFError.apiError(message)
        }
    }

    private func usesPostForSetData() async throws -> Bool {
        if let cached = setDataUsesPostCache.value {
            return cached
        }

        let model = try await getModel()
        let normalizedModel = Self.modelAliases[model] ?? model
        let usesPost = Self.postSetDataModels.contains(normalizedModel)
        setDataUsesPostCache.value = usesPost
        return usesPost
    }

    // MARK: - Read

    public func getSnapshot() async throws -> SpeakerSnapshot {
        if supportsBatchedGetDataCache.value != false {
            do {
                let snapshot = try await getBatchedSnapshot()
                supportsBatchedGetDataCache.value = true
                return snapshot
            } catch KEFError.invalidResponse {
                supportsBatchedGetDataCache.value = false
            } catch KEFError.apiError(_) {
                supportsBatchedGetDataCache.value = false
            } catch {
                throw error
            }
        }

        return try await getUnbatchedSnapshot()
    }

    private func getBatchedSnapshot() async throws -> SpeakerSnapshot {
        let entries = try await getData(paths: [
            "settings:/kef/host/speakerStatus",
            "settings:/kef/play/physicalSource",
            "player:volume",
            "settings:/deviceName",
            "settings:/releasetext",
        ])

        guard entries.count >= 5 else { throw KEFError.invalidResponse }

        guard let statusRaw = entries[0].string("kefSpeakerStatus") else {
            throw KEFError.invalidResponse
        }
        let volume = try Self.validatedVolume(from: entries[2])
        let sourceRaw = entries[1].string("kefPhysicalSource") ?? "standby"
        let modelRaw = entries[4].string("string_") ?? ""
        let model = Self.normalizedModelName(from: modelRaw)
        modelCache.value = model

        return SpeakerSnapshot(
            status: SpeakerStatus(rawValue: statusRaw),
            source: SpeakerSource(rawValue: sourceRaw) ?? .wifi,
            volume: volume,
            name: entries[3].string("string_") ?? "KEF Speaker",
            model: model
        )
    }

    private func getUnbatchedSnapshot() async throws -> SpeakerSnapshot {
        async let s = getStatus()
        async let src = getSource()
        async let vol = getVolume()
        async let name = getSpeakerName()
        async let model = getModel()

        return try await SpeakerSnapshot(
            status: s,
            source: src,
            volume: vol,
            name: name,
            model: model
        )
    }

    public func getStatus() async throws -> SpeakerStatus {
        let data = try await firstData(path: "settings:/kef/host/speakerStatus")
        guard let raw = data.string("kefSpeakerStatus") else {
            throw KEFError.invalidResponse
        }
        return SpeakerStatus(rawValue: raw)
    }

    public func getSource() async throws -> SpeakerSource {
        let data = try await firstData(path: "settings:/kef/play/physicalSource")
        let raw = data.string("kefPhysicalSource") ?? "standby"
        return SpeakerSource(rawValue: raw) ?? .wifi
    }

    public func getVolume() async throws -> Int {
        let data = try await firstData(path: "player:volume")
        return try Self.validatedVolume(from: data)
    }

    private static func validatedVolume(from entry: KEFDataEntry) throws -> Int {
        guard let volume = entry.int("i32_"), 0...100 ~= volume else {
            throw KEFError.invalidResponse
        }
        return volume
    }

    public func getSpeakerName() async throws -> String {
        let data = try await firstData(path: "settings:/deviceName")
        return data.string("string_") ?? "KEF Speaker"
    }

    public func getModel() async throws -> String {
        if let cached = modelCache.value {
            return cached
        }

        let data = try await firstData(path: "settings:/releasetext")
        let raw = data.string("string_") ?? ""
        let model = Self.normalizedModelName(from: raw)
        modelCache.value = model
        return model
    }

    private static func normalizedModelName(from raw: String) -> String {
        raw.components(separatedBy: "_").first ?? raw
    }

    private func getPlayerData() async throws -> KEFDataEntry {
        try await firstData(path: "player:player/data")
    }

    public func getIsPlaying() async throws -> Bool {
        try await getPlayerState().isPlaying
    }

    public func getNowPlayingInfo() async throws -> NowPlayingInfo {
        try await getPlayerState().nowPlaying
    }

    public func getPlayerState() async throws -> PlayerState {
        let data = try await getPlayerData()
        let trackRoles = data.object("trackRoles")
        let mediaData = trackRoles?["mediaData"]?.objectValue
        let metadata = mediaData?["metaData"]?.objectValue

        return PlayerState(
            isPlaying: data.string("state") == "playing",
            nowPlaying: NowPlayingInfo(
                title: trackRoles?["title"]?.stringValue,
                artist: metadata?["artist"]?.stringValue,
                album: metadata?["album"]?.stringValue
            )
        )
    }

    // MARK: - Write

    public func setVolume(_ volume: Int) async throws {
        let clamped = max(0, min(100, volume))
        try await setData(
            path: "player:volume",
            value: ["type": .string("i32_"), "i32_": .int(clamped)]
        )
    }

    public func setSource(_ source: SpeakerSource) async throws {
        try await setData(
            path: "settings:/kef/play/physicalSource",
            value: ["type": .string("kefPhysicalSource"), "kefPhysicalSource": .string(source.rawValue)]
        )
    }

    public func powerOn() async throws {
        try await setData(
            path: "settings:/kef/play/physicalSource",
            value: ["type": .string("kefPhysicalSource"), "kefPhysicalSource": .string("powerOn")]
        )
    }

    public func shutdown() async throws {
        try await setData(
            path: "settings:/kef/play/physicalSource",
            value: ["type": .string("kefPhysicalSource"), "kefPhysicalSource": .string("standby")]
        )
    }

    public func togglePlayPause() async throws {
        try await setData(
            path: "player:player/control",
            roles: "activate",
            value: ["control": .string("pause")]
        )
    }

    public func nextTrack() async throws {
        try await setData(
            path: "player:player/control",
            roles: "activate",
            value: ["control": .string("next")]
        )
    }

    public func previousTrack() async throws {
        try await setData(
            path: "player:player/control",
            roles: "activate",
            value: ["control": .string("previous")]
        )
    }

    public func testConnection() async -> Bool {
        do {
            try await validateConnection()
            return true
        } catch {
            return false
        }
    }

    public func validateConnection() async throws {
        _ = try await getStatus()
    }

    static func decodeDataEntries(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [KEFDataEntry] {
        guard data.count <= maximumResponseByteCount else {
            throw KEFError.invalidResponse
        }

        decoder.userInfo[.kefJSONDecodingLimits] = KEFJSONDecodingLimits.speakerResponse
        do {
            return try decoder.decode(KEFDataEntryList.self, from: data).entries
        } catch {
            throw KEFError.invalidResponse
        }
    }
}

extension KEFSpeakerAPI: KEFSpeakerClient {}

private final class SpeakerHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get {
            lock.withLock { storedValue }
        }
        set {
            lock.withLock {
                storedValue = newValue
            }
        }
    }
}

typealias KEFSetValue = [String: KEFJSONValue]

/// Flexible JSON value used at the KEF API boundary.
///
/// The speaker returns endpoint-specific keys such as `kefSpeakerStatus`,
/// `i32_`, or nested `trackRoles`. Decoding into this enum preserves the dynamic
/// shape at the edge while preventing untyped `[String: Any]` from spreading
/// through the rest of the codebase.
enum KEFJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: KEFJSONValue])
    case array([KEFJSONValue])
    case null

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            return Int(exactly: value)
        default:
            return nil
        }
    }

    var objectValue: [String: KEFJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    init(from decoder: Decoder) throws {
        let limits = decoder.kefJSONDecodingLimits
        guard decoder.codingPath.count <= limits.maximumNestingDepth else {
            throw KEFError.invalidResponse
        }

        if let keyedContainer = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            guard keyedContainer.allKeys.count <= limits.maximumObjectMemberCount else {
                throw KEFError.invalidResponse
            }

            var object: [String: KEFJSONValue] = [:]
            for key in keyedContainer.allKeys {
                object[key.stringValue] = try keyedContainer.decode(KEFJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var unkeyedContainer = try? decoder.unkeyedContainer() {
            if let count = unkeyedContainer.count, count > limits.maximumArrayElementCount {
                throw KEFError.invalidResponse
            }

            var array: [KEFJSONValue] = []
            while !unkeyedContainer.isAtEnd {
                guard array.count < limits.maximumArrayElementCount else {
                    throw KEFError.invalidResponse
                }
                array.append(try unkeyedContainer.decode(KEFJSONValue.self))
            }
            self = .array(array)
            return
        }

        let singleValueContainer = try decoder.singleValueContainer()
        if singleValueContainer.decodeNil() {
            self = .null
        } else if let value = try? singleValueContainer.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? singleValueContainer.decode(Int.self) {
            self = .int(value)
        } else if let value = try? singleValueContainer.decode(Double.self) {
            self = .double(value)
        } else if let value = try? singleValueContainer.decode(String.self) {
            guard value.count <= limits.maximumStringLength else {
                throw KEFError.invalidResponse
            }
            self = .string(value)
        } else {
            throw KEFError.invalidResponse
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .int(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .double(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .object(let value):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, nestedValue) in value {
                try container.encode(nestedValue, forKey: DynamicCodingKey(stringValue: key))
            }
        case .array(let value):
            var container = encoder.unkeyedContainer()
            for nestedValue in value {
                try container.encode(nestedValue)
            }
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}

struct KEFDataEntry: Decodable, Equatable, Sendable {
    let values: [String: KEFJSONValue]

    init(values: [String: KEFJSONValue]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let limits = decoder.kefJSONDecodingLimits
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard container.allKeys.count <= limits.maximumObjectMemberCount else {
            throw KEFError.invalidResponse
        }

        var values: [String: KEFJSONValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(KEFJSONValue.self, forKey: key)
        }
        self.values = values
    }

    func string(_ key: String) -> String? {
        values[key]?.stringValue
    }

    func int(_ key: String) -> Int? {
        values[key]?.intValue
    }

    func object(_ key: String) -> [String: KEFJSONValue]? {
        values[key]?.objectValue
    }
}

private struct KEFSetDataRequest: Encodable {
    var path: String
    var roles: String
    var value: KEFSetValue
}

private struct KEFDataEntryList: Decodable {
    var entries: [KEFDataEntry]

    init(from decoder: Decoder) throws {
        let limits = decoder.kefJSONDecodingLimits
        var container = try decoder.unkeyedContainer()
        if let count = container.count, count > limits.maximumEntryCount {
            throw KEFError.invalidResponse
        }

        var entries: [KEFDataEntry] = []
        while !container.isAtEnd {
            guard entries.count < limits.maximumEntryCount else {
                throw KEFError.invalidResponse
            }
            entries.append(try container.decode(KEFDataEntry.self))
        }

        self.entries = entries
    }
}

private struct KEFJSONDecodingLimits {
    var maximumEntryCount: Int
    var maximumObjectMemberCount: Int
    var maximumArrayElementCount: Int
    var maximumNestingDepth: Int
    var maximumStringLength: Int

    static let speakerResponse = KEFJSONDecodingLimits(
        maximumEntryCount: 256,
        maximumObjectMemberCount: 128,
        maximumArrayElementCount: 128,
        maximumNestingDepth: 32,
        maximumStringLength: 64 * 1_024
    )
}

private extension CodingUserInfoKey {
    static let kefJSONDecodingLimits = CodingUserInfoKey(rawValue: "kefJSONDecodingLimits")!
}

private extension Decoder {
    var kefJSONDecodingLimits: KEFJSONDecodingLimits {
        userInfo[.kefJSONDecodingLimits] as? KEFJSONDecodingLimits ?? .speakerResponse
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private extension KEFJSONValue {
    var representsNoError: Bool {
        switch self {
        case .null, .bool(false):
            true
        default:
            false
        }
    }

    var speakerErrorMessage: String? {
        switch self {
        case .string(let message):
            message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case .object(let payload):
            if let message = payload["message"]?.stringValue {
                message.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            } else {
                nil
            }
        default:
            nil
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
