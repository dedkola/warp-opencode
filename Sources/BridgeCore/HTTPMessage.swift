import Foundation

struct SSEBoundaryTracker {
    private var suffix = Data()
    private(set) var isAtEventBoundary = true

    mutating func observe(_ data: Data) {
        guard !data.isEmpty else { return }
        suffix.append(data)
        suffix = Data(suffix.suffix(4))
        isAtEventBoundary = suffix.suffix(2) == Data("\n\n".utf8)
            || suffix == Data("\r\n\r\n".utf8)
    }
}

struct HTTPRequestMessage {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

enum HTTPParseError: Error, LocalizedError {
    case invalid(String), tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .tooLarge: return "Request exceeds the bridge's 16 MB limit."
        }
    }
}

/// One HTTP/1 request per connection. Supports the framing used by HTTP proxies,
/// rejects ambiguous framing, and never interprets an absolute target as an upstream URL.
struct HTTPRequestParser {
    static let maximumBodyBytes = 16 * 1024 * 1024
    private(set) var headers: [String: String]?
    private var buffer = Data()
    private var headerEnd: Int?
    private var method = ""
    private var target = ""

    mutating func append(_ data: Data) throws -> HTTPRequestMessage? {
        buffer.append(data)
        guard buffer.count <= Self.maximumBodyBytes + 256 * 1024 else { throw HTTPParseError.tooLarge }
        if headerEnd == nil {
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 32 * 1024 { throw HTTPParseError.tooLarge }
                return nil
            }
            guard range.lowerBound <= 32 * 1024,
                  let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) else {
                throw HTTPParseError.invalid("Invalid HTTP headers.")
            }
            let lines = head.components(separatedBy: "\r\n")
            let start = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
            guard start.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(start[2])),
                  String(start[1]).hasPrefix("/"), !String(start[1]).hasPrefix("//") else {
                throw HTTPParseError.invalid("Invalid HTTP request target.")
            }
            method = String(start[0]); target = String(start[1])
            var parsed: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                      !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                    throw HTTPParseError.invalid("Invalid HTTP header.")
                }
                let name = String(line[..<colon]).lowercased()
                guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
                    throw HTTPParseError.invalid("Invalid HTTP header name.")
                }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw HTTPParseError.invalid("Invalid HTTP header value.")
                }
                guard parsed[name] == nil else { throw HTTPParseError.invalid("Duplicate HTTP headers are not supported.") }
                parsed[name] = value
            }
            if parsed["expect"] != nil { throw HTTPParseError.invalid("Expect is not supported; send the request body directly.") }
            if parsed["content-length"] != nil && parsed["transfer-encoding"] != nil {
                throw HTTPParseError.invalid("Ambiguous HTTP body framing.")
            }
            headers = parsed
            headerEnd = range.upperBound
        }
        guard let headerEnd, let headers else { return nil }
        let payload = Data(buffer[headerEnd...])
        let body: Data
        if let encoding = headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked" else { throw HTTPParseError.invalid("Unsupported transfer encoding.") }
            guard let decoded = try Self.decodeChunks(payload) else { return nil }
            body = decoded
        } else {
            let raw = headers["content-length"] ?? "0"
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw) else {
                throw HTTPParseError.invalid("Invalid content length.")
            }
            guard count <= Self.maximumBodyBytes else { throw HTTPParseError.tooLarge }
            guard payload.count >= count else { return nil }
            guard payload.count == count else { throw HTTPParseError.invalid("HTTP pipelining is not supported.") }
            body = payload
        }
        return HTTPRequestMessage(method: method, target: target, headers: headers, body: body)
    }

    private static func decodeChunks(_ data: Data) throws -> Data? {
        var cursor = 0
        var output = Data()
        while true {
            guard let line = data.range(of: Data("\r\n".utf8), in: cursor..<data.count) else { return nil }
            guard line.lowerBound - cursor < 128,
                  let text = String(data: data[cursor..<line.lowerBound], encoding: .ascii),
                  let raw = text.split(separator: ";", omittingEmptySubsequences: false).first,
                  !raw.isEmpty, let size = Int(raw, radix: 16), size >= 0 else {
                throw HTTPParseError.invalid("Invalid HTTP chunk.")
            }
            cursor = line.upperBound
            guard size <= maximumBodyBytes - output.count else { throw HTTPParseError.tooLarge }
            if size == 0 {
                guard data.count >= cursor + 2 else { return nil }
                // Trailers are deliberately unsupported to keep authentication unambiguous.
                guard data[cursor..<cursor + 2] == Data("\r\n".utf8), data.count == cursor + 2 else {
                    throw HTTPParseError.invalid("HTTP trailers and pipelining are not supported.")
                }
                return output
            }
            guard data.count >= cursor + size + 2 else { return nil }
            output.append(data[cursor..<cursor + size]); cursor += size
            guard data[cursor..<cursor + 2] == Data("\r\n".utf8) else { throw HTTPParseError.invalid("Invalid HTTP chunk delimiter.") }
            cursor += 2
        }
    }
}
