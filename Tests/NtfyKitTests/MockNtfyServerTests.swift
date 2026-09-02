import Foundation
import Testing

@Test func mockServerStreamsEnqueuedLines() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: #"{"id":"a1","time":1,"event":"open","topic":"t"}"#)
    await server.enqueue(line: #"{"id":"a2","time":2,"event":"message","topic":"t","message":"hi"}"#)

    let url = base.appending(path: "t").appending(path: "json")
    let (bytes, response) = try await URLSession.shared.bytes(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    var lines: [String] = []
    for try await line in bytes.lines { lines.append(line) }
    #expect(lines.count == 2)
    #expect(lines[1].contains("\"message\":\"hi\""))
    #expect(await server.receivedRequestPaths.first?.hasPrefix("/t/json") == true)
}

@Test func mockServerCanReturnAnErrorStatus() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.setResponse(status: 401, body: #"{"code":40101,"error":"unauthorized"}"#)

    let url = base.appending(path: "t").appending(path: "json")
    let (_, response) = try await URLSession.shared.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 401)
}
