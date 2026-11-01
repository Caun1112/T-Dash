import Foundation

@main enum TripTests {
    static func main() {
        var trip = TDTripMeter()
        let start = Date(timeIntervalSince1970: 1000)
        trip.ingest(speed: 36, at: start)
        for n in 1...10 { trip.ingest(speed: 36, at: start.addingTimeInterval(Double(n))) }
        precondition(abs(trip.distanceKm - 0.1) < 0.00001)
        precondition(trip.activeSeconds == 10)
        trip.ingest(speed: 100, at: start.addingTimeInterval(10)) // duplicate must not count
        trip.ingest(speed: 100, at: start.addingTimeInterval(9)) // out of order
        precondition(trip.maximumKph == 36)
        trip.ingest(speed: 36, at: start.addingTimeInterval(30)) // disconnect gap
        precondition(abs(trip.distanceKm - 0.1) < 0.00001)
        trip.ingest(speed: .nan, at: start.addingTimeInterval(31))
        trip.ingest(speed: 36, at: start.addingTimeInterval(32))
        precondition(abs(trip.distanceKm - 0.1) < 0.00001)
        trip.interrupt()
        trip.ingest(speed: 36, at: start.addingTimeInterval(33))
        precondition(abs(trip.distanceKm - 0.1) < 0.00001)
        trip.reset()
        precondition(trip.distanceKm == 0 && trip.activeSeconds == 0 && trip.maximumKph == 0)
        print("PASS: trip integration, duplicate/out-of-order samples, stale gaps, invalid speed, pause and reset")
    }
}
