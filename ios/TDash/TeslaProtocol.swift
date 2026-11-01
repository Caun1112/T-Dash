// T-Dash iOS adaptation, 2026. Apache-2.0; see LICENSE and NOTICE.
// Tesla BLE protocol port from this repository's Kotlin implementation and .proto contracts.
import Foundation
import CryptoKit
import Security

enum TDProtocolError: Error, LocalizedError {
    case malformed(String), vehicleFault(UInt64), keyNotPaired, mismatchedResponse
    case authentication, expiredRequest, replay, noSession, keychain(Int32)
    var errorDescription: String? {
        switch self {
        case .malformed(let why): return "车辆协议数据无效：\(why)"
        case .vehicleFault(let n): return "车辆协议错误 \(n)"
        case .keyNotPaired: return "本机钥匙尚未配对，请刷实体钥匙卡并在车机确认"
        case .mismatchedResponse: return "响应与本次请求不匹配"
        case .authentication: return "车辆响应认证失败"
        case .expiredRequest: return "车辆响应已超时"
        case .replay: return "已丢弃重复车辆响应"
        case .noSession: return "车辆加密会话尚未建立"
        case .keychain(let code): return "钥匙串读取或保存失败（\(code)），未覆盖原有钥匙"
        }
    }
}

struct TDTelemetry {
    var speedKph: Double? = nil
    var batteryPercent: Double? = nil
    var gear: String? = nil
    var powerKW: Double? = nil
    var odometerKm: Double? = nil
    var receivedAt = Date()
}

/// Minimal proto3 wire codec. Unknown fields survive re-encoding byte for byte.
/// Bounds, varint overflow, field zero and unsupported group wire types are rejected.
enum TDProto {
    struct Field {
        let number: Int
        let wire: UInt8
        let value: Data
        let raw: Data
    }
    struct Message {
        let fields: [Field]
        var encoded: Data { fields.reduce(into: Data()) { $0.append($1.raw) } }
        func field(_ number: Int, wire: UInt8) throws -> Field? {
            let matching = fields.filter { $0.number == number }
            guard matching.count <= 1 else { throw TDProtocolError.malformed("duplicate field \(number)") }
            guard let f = matching.first else { return nil }
            guard f.wire == wire else { throw TDProtocolError.malformed("wire type \(number)") }
            return f
        }
        func bytes(_ number: Int) throws -> Data? { try field(number, wire: 2)?.value }
        func uint(_ number: Int) throws -> UInt64? {
            guard let f = try field(number, wire: 0) else { return nil }
            var p = 0
            return try TDProto.readVarint(Array(f.value), &p)
        }
        func fixed32(_ number: Int) throws -> UInt32? {
            guard let f = try field(number, wire: 5) else { return nil }
            return f.value.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
        }
        func nested(_ number: Int) throws -> Message? {
            guard let data = try bytes(number) else { return nil }
            return try TDProto.decode(data)
        }
    }
    private static func readVarint(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard offset < bytes.count else { throw TDProtocolError.malformed("truncated varint") }
            let b = bytes[offset]; offset += 1
            if shift == 63 && b > 1 { throw TDProtocolError.malformed("varint overflow") }
            result |= UInt64(b & 127) << shift
            if b < 128 { return result }
        }
        throw TDProtocolError.malformed("varint overflow")
    }
    static func decode(_ data: Data) throws -> Message {
        guard data.count <= 65_535 else { throw TDProtocolError.malformed("oversize frame") }
        let b = Array(data)
        var p = 0, fields: [Field] = []
        while p < b.count {
            let start = p, key = try readVarint(b, &p)
            let number = Int(key >> 3), wire = UInt8(key & 7)
            guard number > 0 && number <= 0x1fff_ffff else { throw TDProtocolError.malformed("field number") }
            var value: Data
            switch wire {
            case 0:
                let v = p; _ = try readVarint(b, &p); value = Data(b[v..<p])
            case 1, 5:
                let length = wire == 1 ? 8 : 4
                guard b.count - p >= length else { throw TDProtocolError.malformed("truncated fixed value") }
                value = Data(b[p..<(p + length)]); p += length
            case 2:
                let length = try readVarint(b, &p)
                guard length <= UInt64(b.count - p) else { throw TDProtocolError.malformed("truncated bytes") }
                value = Data(b[p..<(p + Int(length))]); p += Int(length)
            default: throw TDProtocolError.malformed("unsupported wire type")
            }
            fields.append(Field(number: number, wire: wire, value: value, raw: Data(b[start..<p])))
        }
        return Message(fields: fields)
    }
    static func varint(_ input: UInt64) -> Data {
        var v = input, result = Data()
        repeat {
            var b = UInt8(v & 127); v >>= 7
            if v != 0 { b |= 128 }; result.append(b)
        } while v != 0
        return result
    }
    static func uint(_ number: Int, _ value: UInt64) -> Data {
        varint(UInt64(number) << 3) + varint(value)
    }
    static func bytes(_ number: Int, _ value: Data) -> Data {
        varint((UInt64(number) << 3) | 2) + varint(UInt64(value.count)) + value
    }
    static func fixed32(_ number: Int, _ value: UInt32) -> Data {
        varint((UInt64(number) << 3) | 5) + Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func big32(_ value: UInt32) -> Data {
        Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func randomBytes(_ count: Int) throws -> Data {
        guard count > 0 && count <= 65535 else { throw TDProtocolError.malformed("random length") }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TDProtocolError.keychain(status) }
        return data
    }
    static func advertisedName(vin: String) -> String {
        "S" + Insecure.SHA1.hash(data: Data(vin.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + "C"
    }
    /// Raw VCSEC PRESENT_KEY envelope; caller must only send after an explicit pairing action.
    static func pairingRequest(publicKey: Data) throws -> Data {
        _ = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        let permission = bytes(1, bytes(1, publicKey)) + uint(4, 2) // owner, same as Android
        let whitelist = bytes(5, permission) + bytes(6, uint(1, 6)) // iOS form factor
        let unsigned = bytes(16, whitelist)
        return bytes(1, bytes(2, unsigned) + uint(3, 2))
    }
    static func telemetryPayload() -> Data {
        bytes(2, bytes(1, bytes(4, Data())))
    }
    static func chargePayload() -> Data {
        // One category per message: combined DRIVE+CHARGE exceeds some vehicles' BLE response MTU.
        bytes(2, bytes(1, bytes(2, Data())))
    }
    static func parseTelemetry(_ data: Data) throws -> TDTelemetry {
        let response = try decode(data)
        if let status = try response.nested(1), (try status.uint(1) ?? 0) != 0 {
            throw TDProtocolError.malformed("车辆拒绝遥测读取")
        }
        guard let vehicle = try response.nested(2) else { throw TDProtocolError.malformed("missing VehicleData") }
        var result = TDTelemetry()
        if let drive = try vehicle.nested(5) {
            if let bits = try drive.fixed32(106) {
                let mph = Double(Float(bitPattern: bits))
                if mph.isFinite && mph >= 0 && mph <= 300 { result.speedKph = mph * 1.609344 }
            } else if let mph = try drive.uint(102), mph <= 300 { result.speedKph = Double(mph) * 1.609344 }
            if let power = try drive.uint(103) { result.powerKW = Double(Int32(truncatingIfNeeded: power)) }
            if let odo = try drive.uint(105) {
                let value = Int32(truncatingIfNeeded: odo)
                if value >= 0 { result.odometerKm = Double(value) * 0.0160934 }
            }
            if let shift = try drive.nested(1) {
                let gears = [2: "P", 3: "R", 4: "N", 5: "D"]
                if shift.fields.count == 1, let item = shift.fields.first, item.wire == 2 {
                    result.gear = gears[item.number]
                }
            }
        }
        if let charge = try vehicle.nested(3), let battery = try charge.uint(114), battery <= 100 {
            result.batteryPercent = Double(battery)
        }
        return result
    }
    static func metadata(_ fields: [(UInt8, Data)]) throws -> Data {
        var result = Data(), previous: Int = -1
        for (tag, value) in fields {
            guard Int(tag) > previous, tag < 255, value.count <= 255 else { throw TDProtocolError.malformed("metadata") }
            result.append(tag); result.append(UInt8(value.count)); result.append(value); previous = Int(tag)
        }
        result.append(255)
        return result
    }
}

/// A single per-installation key. Never silently replace a key that cannot be read.
final class TDKeyStore {
    let privateKey: P256.KeyAgreement.PrivateKey
    var publicKey: Data { privateKey.publicKey.x963Representation }
    init() throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tdash.gaode.tesla-key.v1", kSecAttrAccount as String: "vehicle-key"]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        if status == errSecSuccess {
            guard let data = item as? Data else { throw TDProtocolError.keychain(errSecDecode) }
            privateKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        } else if status == errSecItemNotFound {
            let key = P256.KeyAgreement.PrivateKey()
            var add = query
            add[kSecValueData as String] = key.rawRepresentation
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let saved = SecItemAdd(add as CFDictionary, nil)
            guard saved == errSecSuccess else { throw TDProtocolError.keychain(saved) }
            privateKey = key
        } else { throw TDProtocolError.keychain(status) }
    }
}

final class TDRequest {
    let bytes: Data
    let uuid: Data
    let address: Data
    let requestHash: Data?
    let sentAt: Date
    fileprivate let sentUptime: TimeInterval
    fileprivate let kind: Kind
    fileprivate enum Kind { case session, telemetry }
    fileprivate var consumed = false
    fileprivate init(bytes: Data, uuid: Data, address: Data, requestHash: Data?, kind: Kind) {
        self.bytes = bytes; self.uuid = uuid; self.address = address
        self.requestHash = requestHash; self.kind = kind
        sentAt = Date(); sentUptime = ProcessInfo.processInfo.systemUptime
    }
}

/// Confined to the BLE client's serial queue. Sessions are never restored without a fresh HMAC handshake.
final class TDSession {
    private let vin: Data
    private let privateKey: P256.KeyAgreement.PrivateKey
    private let address: Data
    private var key: SymmetricKey?
    private var epoch = Data()
    private var counter: UInt32 = 0
    private var clock: UInt32 = 0
    private var importedUptime: TimeInterval = 0
    var isReady: Bool { key != nil }
    init(vin: String, privateKey: P256.KeyAgreement.PrivateKey) throws {
        let normalized = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.utf8.count == 17, normalized.unicodeScalars.allSatisfy({
            (48...57).contains($0.value) || (65...90).contains($0.value) && ![73, 79, 81].contains($0.value)
        }) else { throw TDProtocolError.malformed("VIN 必须为 17 位且不含 I/O/Q") }
        self.vin = Data(normalized.utf8); self.privateKey = privateKey
        address = try TDProto.randomBytes(16)
    }
    private func envelope(payload: Data, uuid: Data, flags: UInt64 = 0) -> Data {
        TDProto.bytes(6, TDProto.uint(1, 3)) + TDProto.bytes(7, TDProto.bytes(2, address)) + payload +
            TDProto.bytes(51, uuid) + (flags == 0 ? Data() : TDProto.uint(52, flags))
    }
    func makeSessionRequest() throws -> TDRequest {
        let uuid = try TDProto.randomBytes(16)
        let data = envelope(payload: TDProto.bytes(14, TDProto.bytes(1, privateKey.publicKey.x963Representation)), uuid: uuid)
        return TDRequest(bytes: data, uuid: uuid, address: address, requestHash: nil, kind: .session)
    }
    func matchesResponse(_ data: Data, request: TDRequest) throws -> Bool {
        let response = try TDProto.decode(data)
        return try response.nested(6)?.bytes(2) == request.address &&
            response.nested(7)?.uint(1) == 3 && response.bytes(50) == request.uuid
    }
    private func validated(_ data: Data, request: TDRequest) throws -> TDProto.Message {
        guard try matchesResponse(data, request: request) else { throw TDProtocolError.mismatchedResponse }
        let age = ProcessInfo.processInfo.systemUptime - request.sentUptime
        guard age >= 0 && age <= (request.kind == .session ? 4 : 10) else { throw TDProtocolError.expiredRequest }
        guard !request.consumed else { throw TDProtocolError.replay }
        return try TDProto.decode(data)
    }
    private func checkFault(_ response: TDProto.Message) throws {
        let fault = try response.nested(12)?.uint(2) ?? 0
        if fault == 3 { throw TDProtocolError.keyNotPaired }
        if fault != 0 { throw TDProtocolError.vehicleFault(fault) }
        if try response.nested(12)?.uint(1) == 1 { throw TDProtocolError.vehicleFault(1) }
    }
    func acceptSessionResponse(_ data: Data, request: TDRequest) throws {
        guard request.kind == .session else { throw TDProtocolError.mismatchedResponse }
        let response = try validated(data, request: request)
        guard let encoded = try response.bytes(15),
              let tag = try response.nested(13)?.nested(6)?.bytes(1), tag.count == 32 else {
            try checkFault(response)
            throw TDProtocolError.malformed("missing signed session info")
        }
        let info = try TDProto.decode(encoded)
        guard let publicBytes = try info.bytes(2), let epoch = try info.bytes(3), epoch.count == 16 else {
            throw TDProtocolError.malformed("session public key/epoch")
        }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: publicBytes)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let candidate = SymmetricKey(data: Data(Insecure.SHA1.hash(data: sharedData)).prefix(16))
        let sessionKey = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data("session info".utf8), using: candidate)))
        let metadata = try TDProto.metadata([(0, Data([6])), (2, vin), (6, request.uuid)])
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: metadata + encoded, using: sessionKey) else {
            throw TDProtocolError.authentication
        }
        guard try info.uint(5) ?? 0 == 0 else { throw TDProtocolError.keyNotPaired }
        try checkFault(response)
        let count = try info.uint(1) ?? 0
        guard count <= UInt32.max else { throw TDProtocolError.malformed("session counter") }
        self.counter = UInt32(count); self.epoch = epoch; self.clock = try info.fixed32(4) ?? 0
        self.importedUptime = ProcessInfo.processInfo.systemUptime; self.key = candidate
        request.consumed = true
    }
    func makeTelemetryRequest() throws -> TDRequest {
        try makeReadRequest(TDProto.telemetryPayload())
    }
    func makeChargeRequest() throws -> TDRequest {
        try makeReadRequest(TDProto.chargePayload())
    }
    private func makeReadRequest(_ plaintext: Data) throws -> TDRequest {
        guard let key = key else { throw TDProtocolError.noSession }
        guard counter < UInt32.max else { throw TDProtocolError.noSession }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - importedUptime)
        guard elapsed < Double(UInt32.max - clock) - 5 else { throw TDProtocolError.noSession }
        let expires = clock + UInt32(elapsed) + 5
        counter += 1
        let metadata = try TDProto.metadata([(0, Data([5])), (1, Data([3])), (2, vin), (3, epoch),
            (4, TDProto.big32(expires)), (5, TDProto.big32(counter)), (7, TDProto.big32(2))])
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Data(SHA256.hash(data: metadata)))
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        let signature = TDProto.bytes(1, TDProto.bytes(1, privateKey.publicKey.x963Representation)) +
            TDProto.bytes(5, TDProto.bytes(1, epoch) + TDProto.bytes(2, nonce) + TDProto.uint(3, UInt64(counter)) +
                TDProto.fixed32(4, expires) + TDProto.bytes(5, sealed.tag))
        let uuid = try TDProto.randomBytes(16)
        let payload = TDProto.bytes(10, sealed.ciphertext) + TDProto.bytes(13, signature)
        return TDRequest(bytes: envelope(payload: payload, uuid: uuid, flags: 2), uuid: uuid, address: address,
                         requestHash: Data([5]) + sealed.tag, kind: .telemetry)
    }
    func decryptResponse(_ data: Data, request: TDRequest) throws -> Data {
        guard let key = key, let requestHash = request.requestHash, request.kind == .telemetry else {
            throw TDProtocolError.noSession
        }
        let response = try validated(data, request: request)
        guard let encrypted = try response.bytes(10), let signature = try response.nested(13)?.nested(9),
              let nonce = try signature.bytes(1), let tag = try signature.bytes(3), nonce.count == 12, tag.count == 16 else {
            // Fault-only responses are useful for reconnecting, but can never produce telemetry.
            try checkFault(response)
            throw TDProtocolError.authentication
        }
        let count = try signature.uint(2) ?? 0
        let flags = try response.uint(52) ?? 0
        let fault = try response.nested(12)?.uint(2) ?? 0
        guard count <= UInt32.max && flags <= UInt32.max && fault <= UInt32.max else { throw TDProtocolError.malformed("response metadata") }
        let metadata = try TDProto.metadata([(0, Data([9])), (1, Data([3])), (2, vin),
            (5, TDProto.big32(UInt32(count))), (7, TDProto.big32(UInt32(flags))),
            (8, requestHash), (9, TDProto.big32(UInt32(fault)))])
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: encrypted, tag: tag)
            plaintext = try AES.GCM.open(box, using: key, authenticating: Data(SHA256.hash(data: metadata)))
        } catch { throw TDProtocolError.authentication }
        // One-shot read requests accept exactly one authenticated reply. This is stricter than
        // the upstream sliding window, and prevents duplicates even with changed outer UUIDs.
        request.consumed = true
        try checkFault(response)
        return plaintext
    }
}
