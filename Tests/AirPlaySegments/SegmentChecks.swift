import Foundation
import AVFoundation

func runAirPlaySegmentChecks() throws -> (failures:Int,report:String) {
var failures=0
var report:[String]=[]
func check(_ condition:Bool,_ name:String) {
    report.append("\(condition ? "PASS" : "FAIL") \(name)")
    if !condition { failures += 1 }
}
let stream=try LiveSegments(sampleRate:48_000)
let pcm=UnsafeMutablePointer<Float>.allocate(capacity:4096)
defer { stream.stop();pcm.deallocate() }
var frame=0
// Encode generated samples only. This test neither opens audio hardware nor saves audio.
let end=Date().addingTimeInterval(20)
while frame<48_000*24 && Date()<end {
    for i in 0..<2048 {
        let value=Float(0.02*sin(2*Double.pi*440*Double(frame+i)/48_000))
        pcm[i*2]=value;pcm[i*2+1]=value
    }
    if try stream.append(pcm,frames:2048) { frame += 2048 }
    else { Thread.sleep(forTimeInterval:0.001) }
}
let flushEnd=Date().addingTimeInterval(2)
var previousCount = -1
var stableSince=Date()
while Date()<flushEnd {
    let count=stream.snapshot["totalSegments"] as? Int ?? 0
    if count != previousCount { previousCount=count;stableSince=Date() }
    if count>=72 && Date().timeIntervalSince(stableSince)>0.1 { break }
    Thread.sleep(forTimeInterval:0.005)
}
let snapshot=stream.snapshot
check(stream.ready && (snapshot["initializationBytes"] as? Int ?? 0)>0,"Real AAC writer produces in-memory initialization and live parts")
check((snapshot["maximumPartDuration"] as? Double ?? 1)<=0.35,"Encoded part duration fits the advertised 350 ms target")
check((snapshot["totalSegments"] as? Int ?? 0)>60 && (snapshot["segmentCount"] as? Int ?? 0)<=60 && (snapshot["retainedEncodedBytes"] as? Int ?? Int.max)<512_000,"Live encoded retention remains bounded after 24 seconds")
let response=stream.resource("live.m3u8")
let manifest=response.map { String(decoding:$0.data,as:UTF8.self) } ?? ""
check(manifest.contains("#EXT-X-VERSION:9") && manifest.contains("PART-HOLD-BACK=1.05") && manifest.contains("PART-TARGET=0.35") && manifest.contains("CAN-BLOCK-RELOAD=YES"),"Manifest advertises the implemented partial-segment controls")
let lines=manifest.split(separator:"\n").map(String.init)
let durations=lines.filter { $0.hasPrefix("#EXTINF:") }.compactMap { Double($0.dropFirst(8).dropLast()) }
check(!durations.isEmpty && durations.allSatisfy { $0>0 && $0.rounded()<=1 },"Every full segment obeys the one-second HLS target duration")
let fullName=lines.first { $0.hasPrefix("s") && $0.hasSuffix(".m4s") } ?? ""
let group=Int(fullName.dropFirst().dropLast(4)) ?? -1
let first=stream.resource("p\(group*3).m4s")?.data ?? Data()
let second=stream.resource("p\(group*3+1).m4s")?.data ?? Data()
let third=stream.resource("p\(group*3+2).m4s")?.data ?? Data()
check(!first.isEmpty && stream.resource(fullName)?.data == first+second+third,"Full segment consists of the exact three advertised fMP4 parts")
let next=snapshot["totalSegments"] as? Int ?? 0
check(stream.resource("p\(next).m4s")?.pending == true && stream.resource("live.m3u8?_HLS_msn=\(next/3)&_HLS_part=\(next%3)")?.pending == true,"Preload and blocking reload wait for an unpublished part")
check(stream.resource("live.m3u8?_HLS_msn=\(Int.max)&_HLS_part=0")?.status == 400 && stream.resource("s\(Int.max).m4s") == nil && stream.resource("p-1.m4s") == nil,"Invalid and overflowing media requests fail safely")
report.append("\(8-failures)/8 live segment checks passed")
return (failures,report.joined(separator:"\n"))
}
