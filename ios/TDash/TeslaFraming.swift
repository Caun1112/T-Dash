// Copyright 2026 T-Dash Authors. SPDX-License-Identifier: Apache-2.0
// iOS port: bounded Tesla BLE stream framing; independent of CoreBluetooth.
import Foundation

enum TDFrameError: Error, LocalizedError {
    case invalidLength(Int)
    case bufferOverflow
    var errorDescription: String? {
        switch self {
        case .invalidLength: return "车辆蓝牙数据帧长度无效"
        case .bufferOverflow: return "车辆蓝牙接收缓冲区超限"
        }
    }
}

struct TDFrameDecoder {
    static let maximumBodyLength = 8192
    private var buffer: [UInt8] = []
    var hasPartialFrame: Bool { !buffer.isEmpty }

    mutating func reset() { buffer.removeAll(keepingCapacity: false) }

    mutating func append(_ bytes: Data) throws -> [Data] {
        // A BLE notification is small. Bound even malformed caller input before allocation.
        guard bytes.count <= 65536, buffer.count + bytes.count <= 73730 else {
            reset()
            throw TDFrameError.bufferOverflow
        }
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        var offset = 0
        while buffer.count - offset >= 2 {
            let length = Int(buffer[offset]) << 8 | Int(buffer[offset + 1])
            guard length > 0, length <= Self.maximumBodyLength else {
                reset()
                throw TDFrameError.invalidLength(length)
            }
            guard buffer.count - offset >= length + 2 else { break }
            frames.append(Data(buffer[(offset + 2)..<(offset + 2 + length)]))
            offset += length + 2
        }
        if offset > 0 { buffer.removeFirst(offset) }
        return frames
    }

    static func encode(_ body: Data) throws -> Data {
        guard !body.isEmpty, body.count <= 65535 else {
            throw TDFrameError.invalidLength(body.count)
        }
        var framed = Data([UInt8(body.count >> 8), UInt8(body.count & 0xff)])
        framed.append(body)
        return framed
    }
}
