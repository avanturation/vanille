import Foundation

// Export numerical summaries only. Raw reports remain local; no device UIDs,
// remote names, audio, URLs or host uptime are copied into this document.
let args=Array(CommandLine.arguments.dropFirst())
guard args.count>=2 else { fputs("Usage: export-avsync output.json report.json ...\n",stderr);exit(64) }
var cases:[[String:Any]]=[]
do {
    for path in args.dropFirst() {
        let data=try Data(contentsOf:URL(fileURLWithPath:path))
        guard let report=try JSONSerialization.jsonObject(with:data) as? [String:Any],
              let rows=report["samples"] as? [[String:Any]],let label=report["case"] as? String else {
            throw NSError(domain:"Vanille.AVSyncExport",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid numerical report"])
        }
        func points(_ key:String,nested:String?=nil)->[TrendPoint] {
            rows.compactMap { row in
                guard row["playerPlaying"] as? Bool == true,let t=row["elapsed"] as? Double else { return nil }
                let object=nested.flatMap { row[$0] as? [String:Any] } ?? row
                if nested=="video",object["settling"] as? Bool == true || object["compensated"] as? Bool != true { return nil }
                guard let value=object[key] as? Double else { return nil }
                return TrendPoint(elapsed:t,valueMS:value)
            }
        }
        let metrics:[(String,String,String?)]=[
            ("commandToPlayerTimeline","commandToPlayerTimelineMS",nil),
            ("captureToPlayerTimeline","captureToPlayerTimelineMS",nil),
            ("clockSampleVsHost","hardwareSampleVsHostMS",nil),
            ("ioSampleVsHost","ioSampleVsHostMS",nil),
            ("outputSchedulingLead","outputMinusCallbackMS","deviceIO"),
            ("videoTimebaseResidual","timebaseResidualMS","video"),
            ("decodedVideoFrameResidual","decodedFrameResidualMS","video")]
        var steady:[String:Any]=[:]
        for (name,key,nested) in metrics { steady[name]=SyncTrend.summarize(points(key,nested:nested),warmup:30) }
        var device=report["device"] as? [String:Any] ?? [:]
        device["name"]=device["airPlay"] as? Bool == true ? "System AirPlay" : "MR4 via USB audio"
        var result:[String:Any]=["case":label,"date":report["date"] ?? "","status":report["status"] ?? "","durationSeconds":report["durationSeconds"] ?? 0,"device":device,"steadyWindowStartSeconds":30,"steadyWindow":steady,"cleanup":report["cleanup"] ?? [:],"playerDefaultDeviceClockMatches":report["playerDefaultDeviceClockMatches"] ?? 0,"rejectedHardwareClockSamples":report["rejectedHardwareClockSamples"] ?? 0,"hardwareClockResets":report["hardwareClockResets"] ?? 0]
        // Preserve the original 15-second analysis, including startup/route
        // transitions, rather than hiding buffer discontinuities.
        result["originalWindowStartSeconds"]=15
        result["originalWindow"]=Dictionary(uniqueKeysWithValues:metrics.map { ($0.0,report[$0.0] ?? [:]) })
        result["playerClockQueryStatuses"]=Array(Set(rows.compactMap { $0["playerDeviceClockStatus"] as? Int })).sorted()
        cases.append(result)
    }
    let export:[String:Any]=["schema":1,"cases":cases,"scope":"Numerical timelines only, not measured acoustic latency or end-to-end A/V certification. Steady analysis starts at 30 seconds; original 15-second analysis retains startup transitions.","audioSaved":false]
    try JSONSerialization.data(withJSONObject:export,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[0]),options:.atomic)
    print("Exported \(cases.count) numerical comparisons")
} catch { fputs("\(error.localizedDescription)\n",stderr);exit(1) }
