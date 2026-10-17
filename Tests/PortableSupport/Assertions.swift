// A deliberately small adapter for running this repository's test bodies on
// Command Line Tools installations without XCTest. This is not an XCTest module
// and is never compiled by the Swift package's normal test target.
import Foundation

enum PortableCheckError: Error { case unwrapFailed }

enum PortableChecks {
    private static let lock = NSLock()
    private static var failures: [String] = []
    private(set) static var testCount = 0
    private(set) static var failedTestCount = 0

    static func fail(_ message: String, file: StaticString, line: UInt) {
        lock.lock()
        failures.append("\(file):\(line): \(message)")
        lock.unlock()
    }

    private static var failureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return failures.count
    }

    private static func failureMessages(in range: Range<Int>) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(failures[range])
    }

    static func run(_ name: String, setup: () throws -> Void,
                    body: () async throws -> Void, teardown: () throws -> Void) async {
        let before = failureCount
        testCount += 1
        do {
            try setup()
            try await body()
        } catch PortableCheckError.unwrapFailed {
            // The failed unwrap has already recorded its source location.
        } catch {
            fail("Uncaught test error: \(error)", file: #filePath, line: #line)
        }
        do { try teardown() }
        catch { fail("Teardown error: \(error)", file: #filePath, line: #line) }
        let after = failureCount
        if after == before {
            print("PASS \(name)")
        } else {
            failedTestCount += 1
            print("FAIL \(name)")
            failureMessages(in: before..<after).forEach { print("  \($0)") }
        }
    }
}

class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}

    func expectation(description: String) -> PortableExpectation {
        PortableExpectation(description: description)
    }

    func fulfillment(of expectations: [PortableExpectation], timeout: TimeInterval,
                     file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            for expectation in expectations where expectation.isInverted && expectation.isFulfilled {
                PortableChecks.fail("Inverted expectation fulfilled: \(expectation.description)", file: file, line: line)
                return
            }
            let positivesDone = expectations.filter { !$0.isInverted }.allSatisfy(\.isFulfilled)
            if positivesDone && !expectations.contains(where: \.isInverted) { return }
            if Date() >= deadline { break }
            do { try await Task.sleep(nanoseconds: 10_000_000) }
            catch {
                PortableChecks.fail("Expectation wait cancelled", file: file, line: line)
                return
            }
        }
        for expectation in expectations {
            if expectation.isInverted && expectation.isFulfilled {
                PortableChecks.fail("Inverted expectation fulfilled: \(expectation.description)", file: file, line: line)
            } else if !expectation.isInverted && !expectation.isFulfilled {
                PortableChecks.fail("Expectation timed out: \(expectation.description)", file: file, line: line)
            }
        }
    }
}

final class PortableExpectation: @unchecked Sendable {
    let description: String
    private let lock = NSLock()
    private var inverted = false
    private var fulfilled = false

    init(description: String) { self.description = description }

    var isInverted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return inverted }
        set { lock.lock(); defer { lock.unlock() }; inverted = newValue }
    }
    var isFulfilled: Bool {
        lock.lock(); defer { lock.unlock() }; return fulfilled
    }
    func fulfill() {
        lock.lock(); defer { lock.unlock() }; fulfilled = true
    }
}

func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    PortableChecks.fail(message.isEmpty ? "Explicit failure" : message, file: file, line: line)
}

private func portableEvaluate<T>(_ expression: () throws -> T, file: StaticString, line: UInt,
                                 check: (T) -> String?) {
    do {
        if let failure = check(try expression()) { PortableChecks.fail(failure, file: file, line: line) }
    } catch {
        PortableChecks.fail("Assertion expression threw: \(error)", file: file, line: line)
    }
}

func XCTAssertTrue(_ expression: @autoclosure () throws -> Bool, _ message: String = "",
                   file: StaticString = #filePath, line: UInt = #line) {
    portableEvaluate(expression, file: file, line: line) { $0 ? nil : "Expected true. \(message)" }
}

func XCTAssertFalse(_ expression: @autoclosure () throws -> Bool, _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    portableEvaluate(expression, file: file, line: line) { $0 ? "Expected false. \(message)" : nil }
}

func XCTAssertNil<T>(_ expression: @autoclosure () throws -> T?, _ message: String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
    portableEvaluate(expression, file: file, line: line) { $0 == nil ? nil : "Expected nil. \(message)" }
}

func XCTAssertEqual<T: Equatable>(_ first: @autoclosure () throws -> T, _ second: @autoclosure () throws -> T,
                                  _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    portableEvaluate({ (try first(), try second()) }, file: file, line: line) {
        $0.0 == $0.1 ? nil : "Values differ: \(String(describing: $0.0)) != \(String(describing: $0.1)). \(message)"
    }
}

func XCTAssertNotEqual<T: Equatable>(_ first: @autoclosure () throws -> T, _ second: @autoclosure () throws -> T,
                                     _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    portableEvaluate({ (try first(), try second()) }, file: file, line: line) {
        $0.0 != $0.1 ? nil : "Values unexpectedly equal. \(message)"
    }
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line,
                             _ errorHandler: (Error) -> Void = { _ in }) {
    do {
        _ = try expression()
        PortableChecks.fail("Expected an error. \(message)", file: file, line: line)
    } catch { errorHandler(error) }
}

func XCTUnwrap<T>(_ expression: @autoclosure () throws -> T?, _ message: String = "",
                  file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value = try expression() else {
        PortableChecks.fail("Expected a non-nil value. \(message)", file: file, line: line)
        throw PortableCheckError.unwrapFailed
    }
    return value
}
