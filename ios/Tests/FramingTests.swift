import Foundation

@main struct FramingTests {
    static func main() throws {
        let first = Data((0..<255).map(UInt8.init))
        let second = Data([0x44, 0x00, 0xff, 0x99])
        let encoded = try TDFrameDecoder.encode(first)
        var decoder = TDFrameDecoder()
        var decoded: [Data] = []
        for byte in encoded { decoded += try decoder.append(Data([byte])) }
        precondition(decoded == [first] && !decoder.hasPartialFrame)
        let joined = try TDFrameDecoder.encode(first) + TDFrameDecoder.encode(second)
        let joinedResult = try decoder.append(joined)
        precondition(joinedResult == [first, second])
        let partialResult = try decoder.append(Data([0]))
        precondition(partialResult == [])
        precondition(decoder.hasPartialFrame)
        decoder.reset()
        precondition(!decoder.hasPartialFrame)
        for invalid in [Data([0, 0]), Data([0xff, 0xff])] {
            do { _ = try decoder.append(invalid); fatalError("accepted invalid frame") }
            catch is TDFrameError { precondition(!decoder.hasPartialFrame) }
        }
        do { _ = try TDFrameDecoder.encode(Data()); fatalError("accepted empty TX") }
        catch is TDFrameError {}
        do { _ = try decoder.append(Data(repeating: 1, count: 100_000)); fatalError("accepted overflow") }
        catch is TDFrameError { precondition(!decoder.hasPartialFrame) }
        let recovered = try decoder.append(TDFrameDecoder.encode(second))
        precondition(recovered == [second])
        print("Framing tests passed: fragmented / joined / partial / malformed / overflow / recovery")
    }
}
