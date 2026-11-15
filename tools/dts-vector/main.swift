//
// main.swift —— 只在 CI 里跑的离线验证程序（不进 App）
//
// 目的：用**和 iOS 完全相同的编译标志**、在同一套 arm64 上，
// 把仓库里的 libdca 0.0.7 + App 里的 DTSDecoder.swift 真跑一遍，
// 解出一小段 DTS-CD 码流，打印「指纹」（各声道 RMS / 一阶差分能量比 / 开头样本），
// 再和本机 ffmpeg 的解码结果对比，判断解码器本身有没有问题。
//
// 一阶差分能量比 = sum((x[i]-x[i-1])^2) / sum(x[i]^2)
// 这个值对高频噪声特别敏感：解码里混进嘶声时会明显变大。
//

import Foundation

func rms(_ a: [Float]) -> Double {
    guard !a.isEmpty else { return 0 }
    var s = 0.0
    for v in a { s += Double(v) * Double(v) }
    return (s / Double(a.count)).squareRoot()
}

func diffRatio(_ a: [Float]) -> Double {
    guard a.count > 1 else { return 0 }
    var e = 0.0, d = 0.0
    for i in 0..<a.count {
        e += Double(a[i]) * Double(a[i])
        if i > 0 {
            let dv = Double(a[i]) - Double(a[i - 1])
            d += dv * dv
        }
    }
    return e > 0 ? d / e : 0
}

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/dts-vector/vector.wav"
let pcmPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
var pcmOut = Data()
guard let raw = FileManager.default.contents(atPath: path) else {
    print("ERR: 读不到 \(path)")
    exit(1)
}

// 找 data chunk
var pos = 12
var dataOff = -1
var dataLen = 0
while pos + 8 <= raw.count {
    let id = String(data: raw[pos..<(pos + 4)], encoding: .ascii) ?? ""
    let sz = UInt32(raw[pos + 4]) | (UInt32(raw[pos + 5]) << 8)
        | (UInt32(raw[pos + 6]) << 16) | (UInt32(raw[pos + 7]) << 24)
    if id == "data" {
        dataOff = pos + 8
        dataLen = Int(sz)
        break
    }
    pos += 8 + Int(sz) + (Int(sz) & 1)
}
guard dataOff >= 0 else { print("ERR: 没有 data chunk"); exit(1) }
if dataOff + dataLen > raw.count { dataLen = raw.count - dataOff }
print("data_off=\(dataOff) data_len=\(dataLen)")

guard let decoder = DTSDecoder() else { print("ERR: dca_init 失败"); exit(1) }

let bytes = [UInt8](raw)
var off = dataOff
let end = dataOff + dataLen
var frameIndex = 0
var peak: Float = 0
var frameRms: [[Double]] = []
var frameDiffRatio: [[Double]] = []
var sampleFrame15: [[Float]] = []
var badFrames = 0
var channelsSeen = 0

while off + 64 <= end {
    let header = Array(bytes[off..<(off + DTSDecoder.headerSize)])
    let frameBytes = decoder.syncInfo(header)
    if frameBytes <= 0 { off += 1; continue }
    if off + frameBytes > end { break }

    if frameIndex == 0 {
        print("frame0: \(frameBytes)B/帧 sampleRate=\(decoder.sampleRate) "
              + "bitRate=\(decoder.bitRate) samplesPerFrame=\(decoder.samplesPerFrame) amode=\(decoder.amode)")
    }

    let frame = Array(bytes[off..<(off + frameBytes)])
    guard let planar = decoder.decode(frame: frame) else {
        badFrames += 1
        off += frameBytes
        frameIndex += 1
        continue
    }
    channelsSeen = planar.count
    if !pcmPath.isEmpty {
        let n = planar[0].count
        for i in 0..<n {
            for ch in 0..<planar.count {
                var v = planar[ch][i]
                withUnsafeBytes(of: &v) { pcmOut.append(contentsOf: $0) }
            }
        }
    }
    if frameIndex < 40 {
        frameRms.append(planar.map(rms))
        frameDiffRatio.append(planar.map(diffRatio))
    }
    if frameIndex == 15 {
        sampleFrame15 = planar.map { Array($0.prefix(32)) }
    }
    for i in 0..<planar.count {
        for v in planar[i] where abs(v) > peak { peak = abs(v) }
    }
    off += frameBytes
    frameIndex += 1
}

print("frames=\(frameIndex) bad=\(badFrames) channels=\(channelsSeen) peak=\(String(format: "%.5f", peak))")
print("每帧 RMS（.8f，行=帧，列=声道）：")
for (i, row) in frameRms.enumerated() {
    var line = String(format: "  f%02d", i)
    for v in row { line += String(format: " %.8f", v) }
    print(line)
}
print("逐帧 diffRatio（帧 10..29）：")
for i in 10..<min(30, frameRms.count) {
    var line = String(format: "  f%02d", i)
    for v in frameDiffRatio[i] { line += String(format: " %.6f", v) }
    print(line)
}
if !pcmPath.isEmpty {
    try? pcmOut.write(to: URL(fileURLWithPath: pcmPath))
    print("pcm written: \(pcmPath) \(pcmOut.count) bytes")
}
print("第 15 帧前 32 个样本:")
for (i, s) in sampleFrame15.enumerated() {
    var line = String(format: "  ch%d", i)
    for v in s { line += String(format: " %.7f", v) }
    print(line)
}
