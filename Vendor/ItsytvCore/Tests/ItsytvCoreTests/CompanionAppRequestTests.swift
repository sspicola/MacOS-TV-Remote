import XCTest
@testable import ItsytvCore

final class CompanionAppRequestTests: XCTestCase {
    private func response(_ content: OPACK.Value) -> OPACK.Value {
        .dictionary([("_t", .int(3)), ("_c", content)])
    }

    func testValidEmptyAppListIsSuccess() throws {
        XCTAssertTrue(try CompanionAppResponse.appList(response(.dict([]))).isEmpty)
    }

    func testMissingOrMalformedAppListIsFailure() {
        let malformed: [OPACK.Value] = [
            .dictionary([("_t", .int(3))]),
            response(.null),
            response(.dictionary([("com.test.app", .int(1))])),
            response(.dictionary([("com.test.app", .string(""))]))
        ]
        for value in malformed {
            XCTAssertThrowsError(try CompanionAppResponse.appList(value))
        }
    }

    func testAppListPreservesBundleIdentifiersAndSortsNames() throws {
        let apps = try CompanionAppResponse.appList(response(.dictionary([
            ("com.test.z", .string("Zoo")),
            ("com.test.a", .string("Apple"))
        ])))
        XCTAssertEqual(apps.map(\.bundleID), ["com.test.a", "com.test.z"])
        XCTAssertEqual(apps.map(\.name), ["Apple", "Zoo"])
    }

    func testExplicitUnsupportedResponseHasDistinctError() {
        let value = OPACK.Value.dictionary([
            ("_t", .int(3)), ("_em", .string("Command not supported"))
        ])
        XCTAssertThrowsError(try CompanionAppResponse.appList(value)) { error in
            XCTAssertEqual(error as? AppleTVAppRequestError, .unsupported(message: "Command not supported"))
        }
    }

    func testLaunchAcknowledgmentMayHaveNoContentButCannotContainServerError() throws {
        try CompanionAppResponse.validateAcknowledgment(.dictionary([("_t", .int(3))]))
        XCTAssertThrowsError(try CompanionAppResponse.validateAcknowledgment(.dictionary([
            ("_t", .int(3)), ("_em", .string("Launch denied"))
        ])))
        XCTAssertThrowsError(try CompanionAppResponse.validateAcknowledgment(.dictionary([
            ("_t", .int(3)), ("_ec", .int(1))
        ])))
    }

    func testTimeoutCompletesOnceAndRemovesLateResponseHandler() {
        let conn = CompanionConnection()
        let completion = expectation(description: "timeout")
        var calls = 0
        let xid = conn.sendRequestAwaitingResponse(eventName: "test", content: .dict([]), timeout: 0.01) { result in
            calls += 1
            if case .failure(let error) = result {
                XCTAssertEqual(error as? AppleTVAppRequestError, .timedOut(operation: "test"))
            } else { XCTFail("No transport response was delivered") }
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1)
        XCTAssertFalse(conn.dispatchResponse(xid: xid, message: response(.dict([]))))
        XCTAssertEqual(calls, 1)
    }

    func testDisconnectFailsPendingRequestAndRemovesResponseHandler() {
        let conn = CompanionConnection()
        var result: Result<OPACK.Value, Swift.Error>?
        let xid = conn.sendRequestAwaitingResponse(eventName: "test", content: .dict([])) { result = $0 }
        conn.disconnect()
        guard case .failure(let error) = result else { return XCTFail("Disconnect must fail the request") }
        XCTAssertEqual(error as? AppleTVAppRequestError, .connectionClosed)
        XCTAssertFalse(conn.dispatchResponse(xid: xid, message: response(.dict([]))))
    }

    func testSuccessfulReplyCancelsTimeout() {
        let conn = CompanionConnection()
        var calls = 0
        let xid = conn.sendRequestAwaitingResponse(eventName: "test", content: .dict([]), timeout: 0.01) { result in
            calls += 1
            if case .failure(let error) = result { XCTFail("Unexpected failure: \(error)") }
        }
        XCTAssertTrue(conn.dispatchResponse(xid: xid, message: response(.dict([]))))
        let afterDeadline = expectation(description: "past deadline")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { afterDeadline.fulfill() }
        wait(for: [afterDeadline], timeout: 1)
        XCTAssertEqual(calls, 1)
    }
}
