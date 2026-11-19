import Foundation
import VoicePointerCore

@MainActor
enum ZoneHapticChecks {
    @MainActor private final class Clock {
        var now = 0
        var queued: [(Int, @MainActor @Sendable () -> Void)] = []
        func schedule(_ delay: Int, _ action: @escaping @MainActor @Sendable () -> Void) {
            queued.append((now + delay, action))
        }
        func advance(to time: Int) {
            while let index = queued.indices.min(by: { queued[$0].0 < queued[$1].0 }), queued[index].0 <= time {
                let event = queued.remove(at: index)
                now = event.0
                event.1()
            }
            now = time
        }
    }
    private final class Actuator: HapticActuatorPerforming {
        enum Availability { case available, symbolsMissing, openFailed, createNil }
        let availability: Availability
        let clock: Clock
        var openedIDs: [UInt64] = []
        var pulses: [(Int32, Int)] = []
        var deferOpen = false
        var pendingOpen: (@MainActor @Sendable (Bool) -> Void)?
        init(_ availability: Availability, clock: Clock) { self.availability = availability; self.clock = clock }
        func open(deviceID: UInt64, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
            openedIDs.append(deviceID)
            if deferOpen { pendingOpen = completion }
            else { completion(availability == .available) }
        }
        func actuate(id: Int32, lease: HapticPulseLease, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
            guard !lease.isCancelled else { completion(false); return }
            pulses.append((id, clock.now)); completion(true)
        }
        func close() {}
    }
    static func runAll() -> [String] {
        var failures: [String] = []
        func expect(_ ok: Bool, _ name: String) { if !ok { failures.append(name) } }
        do {
            let old = try JSONDecoder().decode(GestureConfiguration.self, from: Data("{\"magicMouseFingerCount\":4,\"trackpadEnabled\":false,\"magicMouseMinDensity\":1.8}".utf8))
            expect(old.hapticStrength == .strong && old.magicMouseFingerCount == 4 && !old.trackpadEnabled && old.magicMouseMinDensity == 1.8,
                   "haptic old settings default preserves explicit fields")
            for strength in HapticStrength.allCases {
                var explicit = old; explicit.hapticStrength = strength
                let decoded = try JSONDecoder().decode(GestureConfiguration.self, from: JSONEncoder().encode(explicit))
                expect(decoded == explicit, "haptic settings roundtrip \(strength.rawValue)")
            }
        } catch { failures.append("haptic settings decode/roundtrip") }
        let privateExpected: [[(Int32, Int)]] = [
            [(0, 0)], [(0, 0)], [(0, 0)],
            [(6, 0)], [(1, 0)], [(6, 0), (6, 60)],
            [(6, 0), (2, 35)], [(4, 0)], [(6, 0), (6, 45), (2, 90)]
        ]
        let zones: [HapticZone] = [.send, .center, .cancel]
        for (levelIndex, level) in HapticStrength.allCases.enumerated() {
            for (zoneIndex, zone) in zones.enumerated() {
                let actual = HapticPulsePlan.pulses(zone: zone, strength: level, privatePath: true)
                let expected = privateExpected[levelIndex * 3 + zoneIndex]
                expect(actual.map(\.id) == expected.map(\.0) && actual.map(\.delayMilliseconds) == expected.map(\.1),
                    "haptic private \(level.rawValue)/\(zone.rawValue)")
            }
        }
        for failure in [Actuator.Availability.symbolsMissing, .openFailed, .createNil] {
            for level in HapticStrength.allCases {
                for zone in zones {
                    let clock = Clock(); let actuator = Actuator(failure, clock: clock)
                    var systemTimes: [Int] = []
                    let player = ZoneHapticFeedback(actuator: actuator, schedule: { clock.schedule($0, $1) },
                        systemPerform: { systemTimes.append(clock.now) }, log: { _ in })
                    player.begin(deviceKind: .builtInTrackpad, deviceID: 17)
                    player.trigger(zone: zone, strength: level); clock.advance(to: 100)
                    let expected = HapticPulsePlan.pulses(zone: zone, strength: level, privatePath: false)
                    expect(systemTimes == expected.map(\.delayMilliseconds) && actuator.pulses.isEmpty,
                        "haptic unavailable \(failure) \(level.rawValue)/\(zone.rawValue)")
                }
            }
        }
        do {
            let clock = Clock(); let actuator = Actuator(.available, clock: clock)
            let player = ZoneHapticFeedback(actuator: actuator, schedule: { clock.schedule($0, $1) }, systemPerform: {}, log: { _ in })
            player.begin(deviceKind: .externalTrackpad, deviceID: 39)
            player.trigger(zone: .cancel, strength: .max)
            clock.advance(to: 20)
            player.trigger(zone: .center, strength: .max)
            clock.advance(to: 100)
            expect(actuator.pulses.map(\.0) == [6, 4] && actuator.pulses.map(\.1) == [0, 20], "haptic changing zone cancels remaining pulses")
            player.trigger(zone: .cancel, strength: .max); player.end(); clock.advance(to: 200)
            expect(actuator.pulses.map(\.0) == [6, 4, 6], "haptic gesture end cancels remaining pulses")
        }
        do {
            let clock = Clock(); let actuator = Actuator(.available, clock: clock)
            actuator.deferOpen = true
            var systems = 0
            let player = ZoneHapticFeedback(actuator: actuator, schedule: { clock.schedule($0, $1) }, systemPerform: { systems += 1 }, log: { _ in })
            player.begin(deviceKind: .builtInTrackpad, deviceID: 21)
            player.trigger(zone: .send, strength: .strong); clock.advance(to: 100)
            expect(systems == 2 && actuator.pulses.isEmpty, "haptic open pending uses fallback immediately")
            player.end(); actuator.pendingOpen?(true)
            player.trigger(zone: .send, strength: .strong)
            expect(actuator.pulses.isEmpty, "haptic late open cannot revive ended gesture")
        }
        for kind in [TouchDeviceKind.magicMouse, .unknown] {
            let clock = Clock(); let actuator = Actuator(.available, clock: clock)
            var systems = 0
            let player = ZoneHapticFeedback(actuator: actuator, schedule: { clock.schedule($0, $1) }, systemPerform: { systems += 1 }, log: { _ in })
            player.begin(deviceKind: kind, deviceID: 41); player.trigger(zone: .send, strength: .max); clock.advance(to: 100)
            expect(actuator.openedIDs.isEmpty && actuator.pulses.isEmpty && systems == 0, "haptic no trackpad no actuator \(kind.rawValue)")
        }
        return failures
    }
}
