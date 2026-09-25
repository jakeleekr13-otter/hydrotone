// Build: see build.sh. Modes: scan <c1|c2|c3>, noise
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "scan": for t in args.dropFirst() { try await scanClip(t) }
case "noise": noiseCheck()
case "gallery": try await gallery(args[1], Double(args[2])!)
case "run": try await runSegment(args[1], args[2], Double(args[3])!, Double(args[4])!, fish: args.count > 6 ? (Int(args[5])!, Int(args[6])!) : nil)
case "speed": try await speedTest(args[1], Double(args[2])!, size: args.count > 4 ? (Int(args[3])!, Int(args[4])!) : nil)
case "roundtrip": try await roundTrip()
case "removed": try await removedGallery(args[1], Double(args[2])!, args.count > 3 ? Int(args[3])! : 24)
case "cmp": try await compareWithV1(args[1], Double(args[2])!, Double(args[3])!)
case "mprof": try await motionProfile(args[1], Double(args[2])!, size: args.count > 4 ? (Int(args[3])!, Int(args[4])!) : nil)
case "kprof": try await kernelProfile(args[1], Double(args[2])!, size: args.count > 4 ? (Int(args[3])!, Int(args[4])!) : nil)
case "rprof": try await renderProfile(args[1], Double(args[2])!, v1: args.count > 3)
case "oprof": try await outputProfile(args[1], Double(args[2])!)
case "drift": try await driftProfile(args[1], Double(args[2])!, Int(args[3])!, newContext: args.count > 4)
case "pprof": try await peakProfile(args[1], Double(args[2])!)
case "leak": try await leakTest(args[1])
case "peek": try await peek(args[1], Double(args[2])!, Int(args[3])!, Int(args[4])!, Int(args[5])!, Int(args[6])!, args[7])
case "edges": try await edgeTest()
case "viz": try await vizFrame(args[1], Double(args[2])!, Int(args[3])!, Int(args[4])!)
default: print("modes: scan, noise")
}
