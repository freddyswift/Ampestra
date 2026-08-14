import Foundation
import Network
import XCTest
@testable import KEFCore

final class KEFSpeakerAPITests: XCTestCase {
    func testGetStatusBuildsGetDataRequest() async throws {
        let (api, recorder) = makeAPI { _ in
            .json(#"[{"kefSpeakerStatus":"powerOn"}]"#)
        }

        let status = try await api.getStatus()

        XCTAssertEqual(status, .powerOn)
        let requests = recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.path, "/api/getData")
        XCTAssertEqual(request.queryValue("path"), "settings:/kef/host/speakerStatus")
        XCTAssertEqual(request.queryValue("roles"), "value")
    }

    func testSetVolumeUsesGetSetDataForLegacyModel() async throws {
        let (api, recorder) = makeAPI { request in
            switch request.url.path {
            case "/api/getData" where request.queryValue("path") == "settings:/releasetext":
                return .json(#"[{"string_":"LS50W_4.0"}]"#)
            case "/api/setData":
                return .empty()
            default:
                throw URLError(.badURL)
            }
        }

        try await api.setVolume(130)

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 2)

        let modelRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(modelRequest.method, "GET")
        XCTAssertEqual(modelRequest.url.path, "/api/getData")
        XCTAssertEqual(modelRequest.queryValue("path"), "settings:/releasetext")

        let setRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(setRequest.method, "GET")
        XCTAssertEqual(setRequest.url.path, "/api/setData")
        XCTAssertEqual(setRequest.queryValue("path"), "player:volume")
        XCTAssertEqual(setRequest.queryValue("roles"), "value")
        XCTAssertNil(setRequest.body)

        let value = try decodedSetValue(fromQueryOf: setRequest)
        XCTAssertEqual(value["type"], .string("i32_"))
        XCTAssertEqual(value["i32_"], .int(100))
    }

    func testSetSourceUsesPostSetDataForModelAlias() async throws {
        let (api, recorder) = makeAPI { request in
            switch request.url.path {
            case "/api/getData" where request.queryValue("path") == "settings:/releasetext":
                return .json(#"[{"string_":"LS50W2_4.0"}]"#)
            case "/api/setData":
                return .json(#"{}"#)
            default:
                throw URLError(.badURL)
            }
        }

        try await api.setSource(.tv)

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 2)

        let modelRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(modelRequest.method, "GET")
        XCTAssertEqual(modelRequest.queryValue("path"), "settings:/releasetext")

        let postRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(postRequest.method, "POST")
        XCTAssertEqual(postRequest.url.path, "/api/setData")
        XCTAssertEqual(postRequest.headers["Content-Type"], "application/json")
        XCTAssertNil(postRequest.url.query)

        let body = try decodedSetDataRequest(fromBodyOf: postRequest)
        XCTAssertEqual(body.path, "settings:/kef/play/physicalSource")
        XCTAssertEqual(body.roles, "value")
        XCTAssertEqual(body.value["type"], .string("kefPhysicalSource"))
        XCTAssertEqual(body.value["kefPhysicalSource"], .string("tv"))
    }

    func testSetDataAcceptsBooleanAcknowledgementForLSXII() async throws {
        let (api, recorder) = makeAPI { request in
            switch request.url.path {
            case "/api/getData" where request.queryValue("path") == "settings:/releasetext":
                return .json(#"[{"string_":"LSXII_V30137"}]"#)
            case "/api/setData":
                return .json("true")
            default:
                throw URLError(.badURL)
            }
        }

        try await api.setVolume(40)

        XCTAssertEqual(recorder.requests.last?.method, "POST")
        XCTAssertEqual(recorder.requests.last?.url.path, "/api/setData")
    }

    func testSetDataUsesPostForLS60() async throws {
        let (api, recorder) = makeAPI { request in
            switch request.url.path {
            case "/api/getData" where request.queryValue("path") == "settings:/releasetext":
                return .json(#"[{"string_":"LS60_V31000"}]"#)
            case "/api/setData":
                return .json("true")
            default:
                throw URLError(.badURL)
            }
        }

        try await api.setVolume(30)

        XCTAssertEqual(recorder.requests.last?.method, "POST")
    }

    func testEverySupportedCurrentModelUsesPostSetData() async throws {
        let supportedModels = ["LS50WII", "LSXII", "LSXIILT", "LS60"]

        for model in supportedModels {
            let (api, recorder) = makeAPI { request in
                switch request.url.path {
                case "/api/getData" where request.queryValue("path") == "settings:/releasetext":
                    return .json(#"[{"string_":"\#(model)_V99999"}]"#)
                case "/api/setData":
                    return .json("true")
                default:
                    throw URLError(.badURL)
                }
            }

            try await api.setVolume(35)

            XCTAssertEqual(recorder.requests.last?.method, "POST", "Expected POST writes for \(model)")
            XCTAssertEqual(recorder.requests.last?.url.path, "/api/setData", "Unexpected endpoint for \(model)")
        }
    }

    func testSetDataRejectsExplicitFalseAcknowledgement() async throws {
        let (api, _) = makeAPI { request in
            switch request.url.path {
            case "/api/getData" where request.queryValue("path") == "settings:/releasetext":
                return .json(#"[{"string_":"LSXII_V30137"}]"#)
            case "/api/setData":
                return .json("false")
            default:
                throw URLError(.badURL)
            }
        }

        do {
            try await api.setVolume(40)
            XCTFail("Expected an explicit false acknowledgement to throw")
        } catch KEFError.apiError(let message) {
            XCTAssertEqual(message, "Speaker rejected command")
        } catch {
            XCTFail("Expected KEFError.apiError, got \(error)")
        }
    }

    func testSetDataSurfacesStructuredSpeakerError() async throws {
        let (api, _) = makeAPI { request in
            switch request.url.path {
            case "/api/getData" where request.queryValue("path") == "settings:/releasetext":
                return .json(#"[{"string_":"LSXII_V30137"}]"#)
            case "/api/setData":
                return .json(#"{"error":{"message":"Volume unavailable"}}"#)
            default:
                throw URLError(.badURL)
            }
        }

        do {
            try await api.setVolume(40)
            XCTFail("Expected the speaker error to throw")
        } catch KEFError.apiError(let message) {
            XCTAssertEqual(message, "Volume unavailable")
        } catch {
            XCTFail("Expected KEFError.apiError, got \(error)")
        }
    }

    func testGetDataThrowsAPIErrorForHTTPFailure() async throws {
        let (api, recorder) = makeAPI { _ in
            .empty(statusCode: 503)
        }

        do {
            _ = try await api.getStatus()
            XCTFail("Expected HTTP failure to throw")
        } catch KEFError.apiError(let message) {
            XCTAssertEqual(message, "Speaker returned HTTP 503")
        } catch {
            XCTFail("Expected KEFError.apiError, got \(error)")
        }

        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testDefaultSessionRejectsSpeakerControlledRedirects() async throws {
        let redirectTarget = try LocalHTTPServer { _ in
            Self.httpResponse(
                status: "200 OK",
                headers: ["Content-Type": "application/json"],
                body: #"[{"kefSpeakerStatus":"powerOn"}]"#
            )
        }
        let selectedSpeaker = try LocalHTTPServer { _ in
            Self.httpResponse(
                status: "302 Found",
                headers: ["Location": "http://127.0.0.1:\(redirectTarget.port)/redirected-from-speaker"]
            )
        }
        addTeardownBlock {
            selectedSpeaker.stop()
            redirectTarget.stop()
        }

        let api = KEFSpeakerAPI(host: "127.0.0.1:\(selectedSpeaker.port)")

        let didConnect = await api.testConnection()
        XCTAssertFalse(didConnect)
        XCTAssertEqual(selectedSpeaker.requests.count, 1)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(redirectTarget.requests.count, 0)
    }

    func testGetDataThrowsInvalidResponseForMalformedPayload() async throws {
        let (api, _) = makeAPI { _ in
            .json(#"{"kefSpeakerStatus":"powerOn"}"#)
        }

        do {
            _ = try await api.getStatus()
            XCTFail("Expected malformed payload to throw")
        } catch KEFError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Expected KEFError.invalidResponse, got \(error)")
        }
    }

    func testSetDataThrowsInvalidResponseForMalformedPayload() async throws {
        let (api, _) = makeAPI { request in
            switch request.url.path {
            case "/api/getData" where request.queryValue("path") == "settings:/releasetext":
                return .json(#"[{"string_":"LS50W_4.0"}]"#)
            case "/api/setData":
                return .json("not-json")
            default:
                throw URLError(.badURL)
            }
        }

        do {
            try await api.setVolume(25)
            XCTFail("Expected malformed setData payload to throw")
        } catch KEFError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Expected KEFError.invalidResponse, got \(error)")
        }
    }

    func testSnapshotFallsBackToIndividualRequestsWhenBatchedPayloadIsInvalid() async throws {
        let expectedBatchedPath = [
            "settings:/kef/host/speakerStatus",
            "settings:/kef/play/physicalSource",
            "player:volume",
            "settings:/deviceName",
            "settings:/releasetext",
        ].joined(separator: ",")

        let (api, recorder) = makeAPI { request in
            guard request.url.path == "/api/getData" else {
                throw URLError(.badURL)
            }

            switch request.queryValue("path") {
            case expectedBatchedPath:
                return .json("[]")
            case "settings:/kef/host/speakerStatus":
                return .json(#"[{"kefSpeakerStatus":"powerOn"}]"#)
            case "settings:/kef/play/physicalSource":
                return .json(#"[{"kefPhysicalSource":"tv"}]"#)
            case "player:volume":
                return .json(#"[{"i32_":24}]"#)
            case "settings:/deviceName":
                return .json(#"[{"string_":"Living Room"}]"#)
            case "settings:/releasetext":
                return .json(#"[{"string_":"LSX2_4.0"}]"#)
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await api.getSnapshot()

        XCTAssertEqual(
            snapshot,
            SpeakerSnapshot(
                status: .powerOn,
                source: .tv,
                volume: 24,
                name: "Living Room",
                model: "LSX2"
            )
        )

        let requests = recorder.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests.first?.queryValue("path"), expectedBatchedPath)
        XCTAssertEqual(
            Set(requests.dropFirst().compactMap { $0.queryValue("path") }),
            Set(expectedBatchedPath.components(separatedBy: ","))
        )
    }

    func testSnapshotFallsBackToIndividualRequestsWhenBatchedRequestReturnsAPIError() async throws {
        let expectedBatchedPath = [
            "settings:/kef/host/speakerStatus",
            "settings:/kef/play/physicalSource",
            "player:volume",
            "settings:/deviceName",
            "settings:/releasetext",
        ].joined(separator: ",")

        let (api, recorder) = makeAPI { request in
            guard request.url.path == "/api/getData" else {
                throw URLError(.badURL)
            }

            switch request.queryValue("path") {
            case expectedBatchedPath:
                return .json(#"{"error":{"message":"Node at path does not exist"}}"#, statusCode: 500)
            case "settings:/kef/host/speakerStatus":
                return .json(#"[{"kefSpeakerStatus":"powerOn"}]"#)
            case "settings:/kef/play/physicalSource":
                return .json(#"[{"kefPhysicalSource":"powerOn"}]"#)
            case "player:volume":
                return .json(#"[{"i32_":45}]"#)
            case "settings:/deviceName":
                return .json(#"[{"string_":"LSX II"}]"#)
            case "settings:/releasetext":
                return .json(#"[{"string_":"LSXII_V30137"}]"#)
            default:
                throw URLError(.badURL)
            }
        }

        let snapshot = try await api.getSnapshot()

        XCTAssertEqual(
            snapshot,
            SpeakerSnapshot(
                status: .powerOn,
                source: .wifi,
                volume: 45,
                name: "LSX II",
                model: "LSXII"
            )
        )

        XCTAssertEqual(recorder.requests.count, 6)
        XCTAssertEqual(recorder.requests.first?.queryValue("path"), expectedBatchedPath)
    }

    func testDecodesDynamicDataEntries() throws {
        let json = """
        [
          {
            "state": "playing",
            "i32_": 42,
            "trackRoles": {
              "title": "Song",
              "mediaData": {
                "metaData": {
                  "artist": "Artist",
                  "album": "Album"
                }
              }
            }
          }
        ]
        """

        let entries = try KEFSpeakerAPI.decodeDataEntries(Data(json.utf8))
        XCTAssertEqual(entries.first?.string("state"), "playing")
        XCTAssertEqual(entries.first?.int("i32_"), 42)
        XCTAssertEqual(entries.first?.object("trackRoles")?["title"]?.stringValue, "Song")
    }

    func testRejectsNonArrayResponse() {
        XCTAssertThrowsError(try KEFSpeakerAPI.decodeDataEntries(Data(#"{"state":"playing"}"#.utf8)))
    }

    func testRejectsResponsesLargerThanApplicationLimit() async throws {
        let padding = String(repeating: "a", count: KEFSpeakerAPI.maximumResponseByteCount)
        let (api, _) = makeAPI { _ in
            .json(#"[{"kefSpeakerStatus":"powerOn","padding":"\#(padding)"}]"#)
        }

        do {
            _ = try await api.getStatus()
            XCTFail("Expected oversized payload to throw")
        } catch KEFError.invalidResponse {
            // Expected.
        } catch {
            XCTFail("Expected KEFError.invalidResponse, got \(error)")
        }
    }

    func testRejectsTooManyDataEntries() {
        let entry = #"{"kefSpeakerStatus":"powerOn"}"#
        let json = "[" + Array(repeating: entry, count: 257).joined(separator: ",") + "]"

        XCTAssertThrowsError(try KEFSpeakerAPI.decodeDataEntries(Data(json.utf8)))
    }

    func testRejectsDeeplyNestedDynamicValues() {
        let nestedValue = (0..<40).reduce(#""leaf""#) { value, _ in
            "[\(value)]"
        }
        let json = #"[{"kefSpeakerStatus":"powerOn","ignored":\#(nestedValue)}]"#

        XCTAssertThrowsError(try KEFSpeakerAPI.decodeDataEntries(Data(json.utf8)))
    }

    private func makeAPI(
        host: String = UUID().uuidString.lowercased() + ".test",
        responder: @escaping (RecordedHTTPRequest) throws -> StubbedHTTPResponse
    ) -> (KEFSpeakerAPI, RequestRecorder) {
        let recorder = RequestRecorder()
        URLProtocolStub.register(host: host) { request in
            recorder.append(request)
            return try responder(request)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let session = KEFSpeakerAPI.makeDefaultSession(configuration: configuration)

        addTeardownBlock {
            session.invalidateAndCancel()
            URLProtocolStub.unregister(host: host)
        }

        return (KEFSpeakerAPI(host: host, session: session), recorder)
    }

    private static func httpResponse(
        status: String,
        headers: [String: String] = [:],
        body: String = ""
    ) -> String {
        let bodyByteCount = Data(body.utf8).count
        let headerLines = headers
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\r\n")
        let extraHeaders = headerLines.isEmpty ? "" : "\(headerLines)\r\n"

        return """
        HTTP/1.1 \(status)\r
        Content-Length: \(bodyByteCount)\r
        Connection: close\r
        \(extraHeaders)\r
        \(body)
        """
    }

    private func decodedSetValue(fromQueryOf request: RecordedHTTPRequest) throws -> [String: KEFJSONValue] {
        let value = try XCTUnwrap(request.queryValue("value"))
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try JSONDecoder().decode([String: KEFJSONValue].self, from: data)
    }

    private func decodedSetDataRequest(fromBodyOf request: RecordedHTTPRequest) throws -> DecodedSetDataRequest {
        let body = try XCTUnwrap(request.body)
        return try JSONDecoder().decode(DecodedSetDataRequest.self, from: body)
    }
}

private final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let lock = NSLock()
    private var storedRequests: [String] = []

    private(set) var port: UInt16 = 0

    var requests: [String] {
        lock.withLock { storedRequests }
    }

    init(handler: @escaping (String) -> String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        let startupError = LockedValue<NWError?>(nil)

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection, handler: handler)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupError.value = error
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 2) == .success,
              startupError.value == nil,
              let port = listener.port?.rawValue else {
            listener.cancel()
            throw LocalHTTPServerError.startupFailed
        }

        self.port = port
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection, handler: @escaping (String) -> String) {
        connection.start(queue: queue)
        receive(on: connection, bufferedData: Data(), handler: handler)
    }

    private func receive(
        on connection: NWConnection,
        bufferedData: Data,
        handler: @escaping (String) -> String
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            var requestData = bufferedData
            if let data {
                requestData.append(data)
            }

            if requestData.range(of: Data("\r\n\r\n".utf8)) != nil,
               let request = String(data: requestData, encoding: .utf8) {
                self.record(request)
                let response = handler(request)
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            if error == nil {
                self.receive(on: connection, bufferedData: requestData, handler: handler)
            } else {
                connection.cancel()
            }
        }
    }

    private func record(_ request: String) {
        lock.withLock {
            storedRequests.append(request)
        }
    }
}

private enum LocalHTTPServerError: Error {
    case startupFailed
}

private struct DecodedSetDataRequest: Decodable {
    var path: String
    var roles: String
    var value: [String: KEFJSONValue]
}

private struct StubbedHTTPResponse {
    var statusCode: Int
    var body: Data
    var headers: [String: String]

    static func empty(statusCode: Int = 200, headers: [String: String] = [:]) -> StubbedHTTPResponse {
        StubbedHTTPResponse(statusCode: statusCode, body: Data(), headers: headers)
    }

    static func json(_ json: String, statusCode: Int = 200) -> StubbedHTTPResponse {
        StubbedHTTPResponse(
            statusCode: statusCode,
            body: Data(json.utf8),
            headers: ["Content-Type": "application/json"]
        )
    }
}

private struct RecordedHTTPRequest {
    var method: String
    var url: URL
    var headers: [String: String]
    var body: Data?

    init(request: URLRequest) {
        method = request.httpMethod ?? "GET"
        url = request.url!
        headers = request.allHTTPHeaderFields ?? [:]
        body = Self.bodyData(from: request)
    }

    func queryValue(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }

        return data
    }
}

private final class RequestRecorder {
    private let lock = NSLock()
    private var storedRequests: [RecordedHTTPRequest] = []

    var requests: [RecordedHTTPRequest] {
        lock.withLock { storedRequests }
    }

    func append(_ request: RecordedHTTPRequest) {
        lock.withLock {
            storedRequests.append(request)
        }
    }
}

private final class URLProtocolStub: URLProtocol {
    typealias Handler = (RecordedHTTPRequest) throws -> StubbedHTTPResponse

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
        }
    }

    static func unregister(host: String) {
        _ = lock.withLock {
            handlers.removeValue(forKey: host)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else {
            return false
        }

        return lock.withLock {
            handlers[host] != nil
        }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = RecordedHTTPRequest(request: request)
        guard let handler = Self.handler(for: request.url.host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let stubbedResponse = try handler(request)
            let response = HTTPURLResponse(
                url: request.url,
                statusCode: stubbedResponse.statusCode,
                httpVersion: nil,
                headerFields: stubbedResponse.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stubbedResponse.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func handler(for host: String?) -> Handler? {
        guard let host else {
            return nil
        }

        return lock.withLock {
            handlers[host]
        }
    }
}
