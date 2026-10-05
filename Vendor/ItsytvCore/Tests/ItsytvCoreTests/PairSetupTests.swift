import XCTest
@testable import ItsytvCore

final class PairSetupTests: XCTestCase {
    func testTruncatedEncryptedIdentityThrowsAfterChallenge() throws {
        let setup = PairSetup(connection: CompanionConnection())
        _ = setup.startPairing()
        let challenge = TLV8.encode([
            (.seqNo, Data([0x02])),
            (.salt, Data(repeating: 0x01, count: 16)),
            (.publicKey, Data([0x02]))
        ])
        _ = try setup.processChallengeAndProve(
            m2Frame: CompanionFrame(type: .pairSetupNext, payload: OPACK.pack(.dictionary([("_pd", .data(challenge))]))),
            pin: "1234"
        )
        let credentials = HAPCredentials(
            clientLTSK: Data(repeating: 0, count: 32), clientLTPK: Data(repeating: 0, count: 32),
            clientID: "test-client", serverLTPK: Data(), serverID: ""
        )
        for size in 0..<16 {
            let response = TLV8.encode([
                (.seqNo, Data([0x06])), (.encryptedData, Data(repeating: 0, count: size))
            ])
            let frame = CompanionFrame(type: .pairSetupNext, payload: OPACK.pack(.dictionary([("_pd", .data(response))])))
            XCTAssertThrowsError(try setup.processServerIdentity(m6Frame: frame, partialCredentials: credentials)) { error in
                guard case .invalidServerResponse = error as? PairSetup.Error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }
}
