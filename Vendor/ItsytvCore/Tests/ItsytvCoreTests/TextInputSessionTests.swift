import XCTest
@testable import ItsytvCore

final class TextInputSessionTests: XCTestCase {

    private let testUUID = Data([
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    ])

    // MARK: - Insert text encoding

    func testEncodeInsertTextProducesValidArchive() throws {
        let data = TextInputSession.encodeInsertText("hello", sessionUUID: testUUID)
        let plist = try deserialize(data)

        XCTAssertEqual(plist["$archiver"] as? String, "RTIKeyedArchiver")
        XCTAssertEqual(plist["$version"] as? Int, 100000)

        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        XCTAssertTrue(objects.contains(where: { ($0 as? String) == "hello" }))
    }

    // MARK: - Replace text encoding

    func testEncodeReplaceTextProducesValidArchive() throws {
        let data = TextInputSession.encodeReplaceText("world", sessionUUID: testUUID)
        let plist = try deserialize(data)

        XCTAssertEqual(plist["$archiver"] as? String, "RTIKeyedArchiver")

        let objects = try XCTUnwrap(plist["$objects"] as? [Any])
        let textOps = try XCTUnwrap(objects[1] as? [String: Any])

        // Has both textToAssert (clear) and keyboardOutput (insert) in one operation
        XCTAssertNotNil(textOps["textToAssert"])
        XCTAssertNotNil(textOps["keyboardOutput"])

        // textToAssert should be empty string (clear)
        let assertIdx = try XCTUnwrap(TextInputSession.uidValue(textOps["textToAssert"]))
        XCTAssertEqual(objects[assertIdx] as? String, "")

        // keyboardOutput.insertionText should be the replacement text
        let kbIdx = try XCTUnwrap(TextInputSession.uidValue(textOps["keyboardOutput"]))
        let kbObj = try XCTUnwrap(objects[kbIdx] as? [String: Any])
        let textIdx = try XCTUnwrap(TextInputSession.uidValue(kbObj["insertionText"]))
        XCTAssertEqual(objects[textIdx] as? String, "world")
    }

    // MARK: - UUID preservation

    func testSessionUUIDBytesPreservedInPayload() throws {
        let data = TextInputSession.encodeInsertText("test", sessionUUID: testUUID)
        let plist = try deserialize(data)
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])

        // Follow targetSessionUUID UID ref from RTITextOperations to find the NSUUID
        let textOps = try XCTUnwrap(objects[1] as? [String: Any])
        let uuidIdx = try XCTUnwrap(TextInputSession.uidValue(textOps["targetSessionUUID"]))
        let uuidObj = try XCTUnwrap(objects[uuidIdx] as? [String: Any])
        let bytes = try XCTUnwrap(uuidObj["NS.uuidbytes"] as? Data)
        XCTAssertEqual(bytes, testUUID)
    }

    // MARK: - Decode start response

    func testDecodeStartResponse() throws {
        // Build a fixture that mimics what Apple TV sends back
        let contextText = "existing text"
        let fixture = buildStartResponseFixture(sessionUUID: testUUID, contextBefore: contextText)

        let result = try TextInputSession.decodeStartResponse(fixture)
        XCTAssertEqual(result.sessionUUID, testUUID)
        XCTAssertEqual(result.currentText, contextText)
    }

    // MARK: - Round-trip

    func testEncodeDecodeRoundtrip() throws {
        let text = "round trip test"
        let data = TextInputSession.encodeInsertText(text, sessionUUID: testUUID)
        let plist = try deserialize(data)
        let objects = try XCTUnwrap(plist["$objects"] as? [Any])

        // Walk the archive using uidValue helper (handles both dict and CFKeyedArchiverUID)
        let textOps = try XCTUnwrap(objects[1] as? [String: Any])
        let uuidIdx = try XCTUnwrap(TextInputSession.uidValue(textOps["targetSessionUUID"]))
        let uuidObj = try XCTUnwrap(objects[uuidIdx] as? [String: Any])
        let bytes = try XCTUnwrap(uuidObj["NS.uuidbytes"] as? Data)
        XCTAssertEqual(bytes, testUUID)

        // Extract inserted text via keyboardOutput -> insertionText
        let kbIdx = try XCTUnwrap(TextInputSession.uidValue(textOps["keyboardOutput"]))
        let kbObj = try XCTUnwrap(objects[kbIdx] as? [String: Any])
        let textIdx = try XCTUnwrap(TextInputSession.uidValue(kbObj["insertionText"]))
        let extractedText = try XCTUnwrap(objects[textIdx] as? String)
        XCTAssertEqual(extractedText, text)
    }

    func testKeyboardFocusAndInitialReplyOrdering() {
        let content = OPACK.Value.dictionary([("_tiD", .data(buildStartResponseFixture(
            sessionUUID: testUUID, contextBefore: "search")))])
        var state = CompanionKeyboardState()
        let requestRevision = state.revision
        state.receive(event: "_tiStarted", content: content)
        XCTAssertEqual(state.session?.text, "search")
        state.receiveInitial(nil, revision: requestRevision)
        XCTAssertEqual(state.session?.id, testUUID)
        state.receive(event: "_tiStopped", content: content)
        XCTAssertNil(state.session)
        state.receiveInitial(content, revision: requestRevision)
        XCTAssertNil(state.session)
    }

    func testInitialSubscriptionFindsAnAlreadyFocusedField() {
        let content = OPACK.Value.dictionary([("_tiD", .data(buildStartResponseFixture(
            sessionUUID: testUUID, contextBefore: "café 🔎")))])
        var state = CompanionKeyboardState()
        state.receiveInitial(content, revision: state.revision)
        XCTAssertEqual(state.session?.text, "café 🔎")
        let oldRevision = state.revision
        state.reset()
        state.receiveInitial(content, revision: oldRevision)
        XCTAssertNil(state.session)
    }

    func testMalformedKeyboardEventClearsPreviousField() {
        var state = CompanionKeyboardState()
        state.receive(event: "_tiStarted", content: .dictionary([("_tiD", .data(
            buildStartResponseFixture(sessionUUID: testUUID, contextBefore: "previous")))]))
        state.receive(event: "_tiStarted", content: .dictionary([("_tiD", .data(Data([1, 2, 3])))]))
        XCTAssertNil(state.session)
    }

    func testInvalidSessionUUIDLengthsAreRejected() {
        for count in [0, 1, 15, 17] {
            let fixture = buildStartResponseFixture(sessionUUID: Data(repeating: 1, count: count), contextBefore: "")
            XCTAssertThrowsError(try TextInputSession.decodeStartResponse(fixture))
        }
    }

    func testOutOfBoundsArchiveReferencesDoNotCrash() throws {
        for index in [-1, 100, Int.max] {
            var plist = try deserialize(buildStartResponseFixture(sessionUUID: testUUID, contextBefore: ""))
            plist["$top"] = ["sessionUUID": TextInputSession.uid(index)]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            XCTAssertThrowsError(try TextInputSession.decodeStartResponse(data))
        }
    }

    func testInvalidOptionalDocumentReferenceLeavesTextEmpty() throws {
        var plist = try deserialize(buildStartResponseFixture(sessionUUID: testUUID, contextBefore: ""))
        plist["$top"] = ["sessionUUID": TextInputSession.uid(6), "documentState": TextInputSession.uid(-1)]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        XCTAssertEqual(try TextInputSession.decodeStartResponse(data).currentText, "")
    }

    func testWritesWithoutAnActiveFieldFailImmediately() {
        let manager = AppleTVManager(enableMediaRemote: false)
        var completed = false
        manager.replaceText("never sent", sessionID: testUUID) { result in
            if case .success = result { XCTFail("An inactive field must reject text") }
            completed = true
        }
        XCTAssertTrue(completed)
    }

    // MARK: - Helpers

    private func deserialize(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    /// Build a binary plist that mimics the real `_tiD` response from `_tiStart`.
    /// Real structure: `$top` has `sessionUUID`, `documentState`, `documentTraits`.
    private func buildStartResponseFixture(sessionUUID: Data, contextBefore: String) -> Data {
        let uid = TextInputSession.uid
        let objects: [Any] = [
            "$null",
            // [1] RTIDocumentState (top-level, referenced by $top.documentState)
            [
                "docSt": uid(2),
                "originatedFromSource": 0,
                "$class": uid(5),
            ] as NSDictionary,
            // [2] TIDocumentState (inner, with contextBeforeInput)
            [
                "contextBeforeInput": uid(3),
                "$class": uid(4),
            ] as NSDictionary,
            // [3] context text
            contextBefore,
            // [4] TIDocumentState class
            [
                "$classname": "TIDocumentState",
                "$classes": ["TIDocumentState", "NSObject"],
            ] as NSDictionary,
            // [5] RTIDocumentState class
            [
                "$classname": "RTIDocumentState",
                "$classes": ["RTIDocumentState", "NSObject"],
            ] as NSDictionary,
            // [6] raw session UUID bytes
            sessionUUID,
        ]

        let archive: [String: Any] = [
            "$archiver": "RTIKeyedArchiver",
            "$version": 100000,
            "$top": [
                "documentState": uid(1),
                "sessionUUID": uid(6),
            ] as NSDictionary,
            "$objects": objects,
        ]

        return try! PropertyListSerialization.data(
            fromPropertyList: archive,
            format: .binary,
            options: 0
        )
    }
}
