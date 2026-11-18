import Foundation

/// `--detector-test`: drives MeetingDetector with a scripted timeline.
@MainActor
enum DetectorTest {
    static func run() {
        let detector = MeetingDetector()
        let zoom = MeetingDetector.CallApp(bundleID: "us.zoom.xos", name: "zoom.us")
        var apps: [MeetingDetector.CallApp] = []
        var now = Date(timeIntervalSince1970: 0)
        var events: [String] = []
        detector.appsProvider = { apps }
        detector.clock = { now }
        detector.onCallStarted = { events.append("t=\(Int(now.timeIntervalSince1970)) started \($0.name)") }
        detector.onCallEnded = { events.append("t=\(Int(now.timeIntervalSince1970)) ended") }

        func step(_ seconds: Int, _ using: [MeetingDetector.CallApp]) {
            apps = using
            now = now.addingTimeInterval(TimeInterval(seconds))
            detector.poll()
        }
        step(0, [])                    // idle
        detector.recordingStarted()    // recording before the call
        step(2, [zoom])                // call starts -> started
        step(2, [zoom]); step(2, [zoom])
        step(2, []); step(2, []); step(2, [zoom]) // brief mute (4 s) -> no end
        step(2, []); step(2, []); step(2, []); step(2, []); step(2, [])  // 8 s quiet -> ended (repeats until reset)
        step(2, [])
        detector.reset()
        step(2, []); step(2, [])       // after reset: nothing
        print(events.joined(separator: "\n"))
    }
}
