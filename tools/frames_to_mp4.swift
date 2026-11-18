// PNG 프레임 폴더(0000.png, 0001.png, …)를 H.264 MP4 로 묶는다. ffmpeg 없이 macOS 기본 기능만 쓴다.
// 사용: swiftc -O -o /tmp/frames_to_mp4 tools/frames_to_mp4.swift && /tmp/frames_to_mp4 <프레임 폴더> <fps> <결과.mp4>
import AVFoundation
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let fps = Int32(args[2]) else { print("usage: frames_to_mp4 <dir> <fps> <out.mp4>"); exit(2) }
let dir = URL(fileURLWithPath: args[1], isDirectory: true)
let out = URL(fileURLWithPath: args[3])
let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
guard let first = files.first.flatMap({ NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }) else {
    print("프레임이 없습니다"); exit(1)
}
let w = first.width, h = first.height
try? FileManager.default.removeItem(at: out)
let writer = try! AVAssetWriter(outputURL: out, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000],
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for (i, url) in files.enumerated() {
    guard let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let pb = buffer else { continue }
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    ctx?.interpolationQuality = .none
    ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "\(files.count)프레임 → \(out.path)" : "실패: \(writer.error?.localizedDescription ?? "?")")
