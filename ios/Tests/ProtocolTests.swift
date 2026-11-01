// Run: swiftc ios/TDash/TeslaProtocol.swift ios/Tests/ProtocolTests.swift -o /tmp/tdash-protocol-tests && /tmp/tdash-protocol-tests
import Foundation
import CryptoKit

@main
enum ProtocolTests {
    static func hex(_ s: String) -> Data {
        let chars = Array(s); return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
    static func check(_ value: Bool) { precondition(value) }
    static func reject(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected failure") } catch { }
    }
    static func main() throws {
        // Official Tesla vehicle-command protocol documentation vectors, also used by Android tests.
        let vin = "5YJ30123456789ABC"
        let client = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex("2538cdc29a97c19c1e99a637d6cf4f8c970c118b56ede1e6323e6d162c4b30db"))
        let vehiclePublic = hex("04c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3d877d3a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d97")
        let shared = try client.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: vehiclePublic))
        let k = Data(Insecure.SHA1.hash(data: shared.withUnsafeBytes { Data($0) })).prefix(16)
        assert(k == hex("1b2fce19967b79db696f909cff89ea9a"))
        let sessionKeyData = Data(HMAC<SHA256>.authenticationCode(for: Data("session info".utf8), using: SymmetricKey(data: k)))
        assert(sessionKeyData == hex("fceb679ee7bca756fcd441bf238bf2f338629b41d9eb9c67be1b32c9672ce300"))
        let info = hex("0806124104c7a1f47138486aa4729971494878d33b1a24e39571f748a6e16c5955b3d877d3a6aaa0e955166474af5d32c410f439a2234137ad1bb085fd4e8813c958f11d971a104c463f9cc0d3d26906e982ed224adde6255a0a0000")
        let metadata = try TDProto.metadata([(0, Data([6])), (2, Data(vin.utf8)), (6, hex("1588d5a30eabc6f8fc9a951b11f6fd11"))])
        let hmac = Data(HMAC<SHA256>.authenticationCode(for: metadata + info, using: SymmetricKey(data: sessionKeyData)))
        assert(hmac == hex("996c1fe38331be138f8039c194b14db2198846ed7d8251e6749284d7b32ea002"))
        let epoch = hex("4c463f9cc0d3d26906e982ed224adde6")
        let aadMetadata = try TDProto.metadata([(0, Data([5])), (1, Data([3])), (2, Data(vin.utf8)), (3, epoch),
            (4, TDProto.big32(2655)), (5, TDProto.big32(7)), (7, TDProto.big32(2))])
        assert(aadMetadata == hex("000105010103021135594a333031323334353637383941424303104c463f9cc0d3d26906e982ed224adde6040400000a5f050400000007070400000002ff"))
        check(try TDProto.decode(info).encoded == info)
        let unknown = TDProto.bytes(12345, Data([1, 2, 3])) + TDProto.uint(99, UInt64.max)
        check(try TDProto.decode(unknown).encoded == unknown)
        for bad in [Data([0]), Data([0x0a, 0xff]), Data([0x08] + Array(repeating: UInt8(0xff), count: 10)), Data([0x0d, 1]), Data([0x0b])] {
            reject { _ = try TDProto.decode(bad) }
        }
        reject { _ = try TDProto.decode(TDProto.uint(1, 1) + TDProto.uint(1, 2)).uint(1) }
        let pairing = try TDProto.decode(TDProto.pairingRequest(publicKey: client.publicKey.x963Representation))
        let signedPairing = try pairing.nested(1)!
        check(try signedPairing.uint(3) == 2)
        let unsignedPairing = try TDProto.decode(signedPairing.bytes(2)!)
        let whitelist = try unsignedPairing.nested(16)!
        check(try whitelist.nested(5)?.nested(1)?.bytes(1) == client.publicKey.x963Representation)
        check(try whitelist.nested(5)?.uint(4) == 2)
        check(try whitelist.nested(6)?.uint(1) == 6)

        // Simulate the vehicle with a fresh ECDH key; exercise actual public session API end to end.
        let car = P256.KeyAgreement.PrivateKey()
        let session = try TDSession(vin: vin, privateKey: client)
        let request = try session.makeSessionRequest()
        let secret = try car.sharedSecretFromKeyAgreement(with: client.publicKey)
        let key = SymmetricKey(data: Data(Insecure.SHA1.hash(data: secret.withUnsafeBytes { Data($0) })).prefix(16))
        let infoKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("session info".utf8), using: key)))
        let encodedInfo = TDProto.uint(1, 6) + TDProto.bytes(2, car.publicKey.x963Representation) + TDProto.bytes(3, epoch) + TDProto.fixed32(4, 2650)
        let sessionMetadata = try TDProto.metadata([(0, Data([6])), (2, Data(vin.utf8)), (6, request.uuid)])
        let infoTag = Data(HMAC<SHA256>.authenticationCode(for: sessionMetadata + encodedInfo, using: infoKey))
        func route(_ request: TDRequest) -> Data {
            TDProto.bytes(6, TDProto.bytes(2, request.address)) + TDProto.bytes(7, TDProto.uint(1, 3)) + TDProto.bytes(50, request.uuid)
        }
        let response = route(request) + TDProto.bytes(15, encodedInfo) + TDProto.bytes(13, TDProto.bytes(6, TDProto.bytes(1, infoTag)))
        let unpairedInfo = encodedInfo + TDProto.uint(5, 1)
        let unpairedTag = Data(HMAC<SHA256>.authenticationCode(for: sessionMetadata + unpairedInfo, using: infoKey))
        let unpairedResponse = route(request) + TDProto.bytes(15, unpairedInfo) + TDProto.bytes(13, TDProto.bytes(6, TDProto.bytes(1, unpairedTag)))
        do {
            try session.acceptSessionResponse(unpairedResponse, request: request)
            fatalError("A correctly signed non-whitelisted key must not become ready")
        } catch TDProtocolError.keyNotPaired { }
        assert(!session.isReady)
        var corrupted = response; corrupted[corrupted.count - 1] ^= 1
        reject { try session.acceptSessionResponse(corrupted, request: request) }
        assert(!session.isReady)
        try session.acceptSessionResponse(response, request: request)
        assert(session.isReady)
        reject { try session.acceptSessionResponse(response, request: request) }
        // Literal wire encodings independently checked against car_server.proto field numbers.
        assert(TDProto.telemetryPayload() == hex("12040a022200"))
        assert(TDProto.chargePayload() == hex("12040a021200"))
        let command = try session.makeTelemetryRequest()
        let sent = try TDProto.decode(command.bytes)
        let sig = try sent.nested(13)!.nested(5)!
        check(try sig.uint(3) == 7)
        check(try sent.uint(52) == 2)
        let commandMetadata = try TDProto.metadata([(0, Data([5])), (1, Data([3])), (2, Data(vin.utf8)), (3, epoch),
            (4, TDProto.big32(sig.fixed32(4)!)), (5, TDProto.big32(7)), (7, TDProto.big32(2))])
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: sig.bytes(2)!), ciphertext: sent.bytes(10)!, tag: sig.bytes(5)!)
        let decodedCommand = try AES.GCM.open(box, using: key, authenticating: Data(SHA256.hash(data: commandMetadata)))
        assert(decodedCommand == hex("12040a022200"))
        let drive = TDProto.bytes(1, TDProto.bytes(5, Data())) + TDProto.fixed32(106, Float(50.5).bitPattern) +
            TDProto.uint(103, UInt64(bitPattern: Int64(-12))) + TDProto.uint(105, 100_000)
        let payload = TDProto.bytes(2, TDProto.bytes(5, drive) + TDProto.bytes(3, TDProto.uint(114, 72)))
        let responseMetadata = try TDProto.metadata([(0, Data([9])), (1, Data([3])), (2, Data(vin.utf8)),
            (5, TDProto.big32(1)), (7, TDProto.big32(2)), (8, command.requestHash!), (9, TDProto.big32(0))])
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: Data(SHA256.hash(data: responseMetadata)))
        let responseSig = TDProto.bytes(9, TDProto.bytes(1, sealed.nonce.withUnsafeBytes { Data($0) }) + TDProto.uint(2, 1) + TDProto.bytes(3, sealed.tag))
        let telemetryResponse = route(command) + TDProto.bytes(10, sealed.ciphertext) + TDProto.bytes(13, responseSig) + TDProto.uint(52, 2)
        reject { _ = try session.decryptResponse(route(command) + TDProto.bytes(10, payload), request: command) }
        let other = try session.makeTelemetryRequest()
        check(try !session.matchesResponse(telemetryResponse, request: other))
        reject { _ = try session.decryptResponse(telemetryResponse, request: other) }
        var tampered = telemetryResponse; tampered[tampered.count - 1] ^= 1
        reject { _ = try session.decryptResponse(tampered, request: command) }
        let telemetry = try TDProto.parseTelemetry(session.decryptResponse(telemetryResponse, request: command))
        assert(abs(telemetry.speedKph! - 50.5 * 1.609344) < 0.0001)
        assert(telemetry.powerKW == -12 && telemetry.gear == "D" && telemetry.batteryPercent == 72)
        assert(abs(telemetry.odometerKm! - 1609.34) < 0.0001)
        reject { _ = try session.decryptResponse(telemetryResponse, request: command) }
        let sparse = try TDProto.parseTelemetry(TDProto.bytes(2, TDProto.bytes(3, TDProto.uint(114, 0))))
        assert(sparse.batteryPercent == 0 && sparse.speedKph == nil && sparse.gear == nil)
        func rangeSample(_ miles: Float) throws -> TDTelemetry {
            try TDProto.parseTelemetry(TDProto.bytes(2, TDProto.bytes(3, TDProto.fixed32(111, miles.bitPattern))))
        }
        let ranged = try rangeSample(264.7)
        assert(abs(ranged.rangeKm! - Double(Float(264.7)) * 1.609344) < 0.0001)
        check(try rangeSample(0).rangeKm == 0)
        for invalid: Float in [-1, .nan, .infinity, 2000] {
            check(try rangeSample(invalid).rangeKm == nil)
        }
        assert(sparse.rangeKm == nil) // missing range must not become a false zero
        print("PASS: official ECDH/HMAC/TLV vectors, protobuf bounds/unknowns, pairing envelope, authenticated handshake, encrypted telemetry roundtrip, UUID match, tamper/replay rejection, sparse telemetry")
    }
}
