// 영상(MP4)에 소리(WAV 등)를 입혀 새 MP4 로 내보낸다. ffmpeg 없이 macOS 기본 기능만 쓴다.
// 사용: swiftc -O -o /tmp/mux_audio tools/mux_audio.swift && /tmp/mux_audio <영상.mp4> <소리.wav> <결과.mp4>
import AVFoundation

let args = CommandLine.arguments
guard args.count == 4 else { print("usage: mux_audio <video.mp4> <audio> <out.mp4>"); exit(2) }
let video = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let audio = AVURLAsset(url: URL(fileURLWithPath: args[2]))
let out = URL(fileURLWithPath: args[3])
try? FileManager.default.removeItem(at: out)

let mix = AVMutableComposition()
guard let vSrc = video.tracks(withMediaType: .video).first, let aSrc = audio.tracks(withMediaType: .audio).first,
      let vDst = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let aDst = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
    print("영상이나 소리 트랙을 읽지 못했습니다"); exit(1)
}
let range = CMTimeRange(start: .zero, duration: video.duration)
try! vDst.insertTimeRange(range, of: vSrc, at: .zero)
try! aDst.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(video.duration, audio.duration)), of: aSrc, at: .zero)

guard let export = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetHighestQuality) else { print("내보내기를 만들지 못했습니다"); exit(1) }
export.outputURL = out
export.outputFileType = .mp4
let done = DispatchSemaphore(value: 0)
export.exportAsynchronously { done.signal() }
done.wait()
print(export.status == .completed ? "→ \(out.path)" : "실패: \(export.error?.localizedDescription ?? "?")")
