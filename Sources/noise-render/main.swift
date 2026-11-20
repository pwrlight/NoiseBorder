import Foundation
import NoiseKit

// Использование: noise-render <папка> [секунды=60] [targetRMSdBFS=-32]
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: noise-render <outdir> [seconds] [rmsDbfs]\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
var o = RenderOptions()
if args.count > 2, let s = Double(args[2]) { o.seconds = s }
if args.count > 3, let t = Double(args[3]) { o.targetRMSdBFS = t }
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for type in NoiseType.allCases {
    let url = dir.appendingPathComponent("\(type.rawValue).wav")
    try WavWriter.write(NoiseRenderer.render(type, options: o), sampleRate: o.sampleRate, to: url)
    print("wrote \(url.path)")
}
