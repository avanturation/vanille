import Foundation
import CoreAudio
import AVFAudio

/// Private aggregates only. No system route, physical latency, format, volume
/// or buffer property is changed. Starting a no-client clock is balanced before
/// destruction. This probes whether HAL can declare an existing downstream
/// processing latency to an unmodified source player.
enum SystemLatencyMatrix {
    static func run(primary:OutputDevice,secondary:OutputDevice?)->[String:Any] {
        let original=DeviceManager().defaultOutput()
        var rows:[[String:Any]]=[]
        struct Configuration { let name:String;let devices:[OutputDevice];let clock:OutputDevice;let extras:[Double];let stacked:Bool }
        let extra=primary.sampleRate*4
        var cases:[Configuration]=[
            .init(name:"single-baseline",devices:[primary],clock:primary,extras:[0],stacked:false),
            .init(name:"single-extra-main",devices:[primary],clock:primary,extras:[extra],stacked:false),
            .init(name:"single-stacked-extra-main",devices:[primary],clock:primary,extras:[extra],stacked:true)
        ]
        if let secondary,secondary.id != primary.id,abs(secondary.sampleRate-primary.sampleRate)<1,
           (try? HAL.channelCount(secondary.id,scope:kAudioObjectPropertyScopeInput))==0 {
            cases += [
                .init(name:"two-baseline",devices:[primary,secondary],clock:primary,extras:[0,0],stacked:false),
                .init(name:"two-extra-main",devices:[primary,secondary],clock:primary,extras:[extra,0],stacked:false),
                .init(name:"two-extra-secondary",devices:[primary,secondary],clock:primary,extras:[0,extra],stacked:false),
                .init(name:"two-other-clock-extra-primary",devices:[primary,secondary],clock:secondary,extras:[extra,0],stacked:false),
                .init(name:"two-stacked-extra-primary",devices:[primary,secondary],clock:secondary,extras:[extra,0],stacked:true)
            ]
        }
        for config in cases {
            var aggregate:AudioObjectID=0,running=false
            var row:[String:Any]=["case":config.name,"configuredExtraFrames":config.extras,"stacked":config.stacked]
            do {
                let subdevices=zip(config.devices,config.extras).map { device,frames -> [String:Any] in
                    [kAudioSubDeviceUIDKey:device.uid,kAudioSubDeviceExtraOutputLatencyKey:frames,kAudioSubDeviceDriftCompensationKey:device.id != config.clock.id]
                }
                let composition:[String:Any]=[
                    kAudioAggregateDeviceNameKey:"Vanille Private Timing Probe",
                    kAudioAggregateDeviceUIDKey:"com.avanturation.Vanille.latency-matrix.\(UUID().uuidString)",
                    kAudioAggregateDeviceIsPrivateKey:true,
                    kAudioAggregateDeviceIsStackedKey:config.stacked,
                    kAudioAggregateDeviceMainSubDeviceKey:config.clock.uid,
                    kAudioAggregateDeviceSubDeviceListKey:subdevices
                ]
                try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary,&aggregate),"Create timing matrix aggregate")
                Thread.sleep(forTimeInterval:0.15)
                row["stopped"]=describe(aggregate)
                var address=HAL.address(kAudioAggregateDevicePropertyComposition)
                var value:Unmanaged<CFDictionary>?,size=UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
                let read=AudioObjectGetPropertyData(aggregate,&address,0,nil,&size,&value)
                if read==noErr,let returned=value?.takeRetainedValue() as? [String:Any],let sub=returned[kAudioAggregateDeviceSubDeviceListKey] as? [[String:Any]] {
                    row["returnedExtraFrames"]=sub.map { ($0[kAudioSubDeviceExtraOutputLatencyKey] as? NSNumber)?.doubleValue ?? -1 }
                }
                let owned=(try? HAL.objects(aggregate,kAudioObjectPropertyOwnedObjects)) ?? []
                row["ownedObjects"]=owned.map { object -> [String:Any] in
                    let cls=(try? HAL.read(object,kAudioObjectPropertyClass,default:UInt32(0))) ?? 0
                    let owner=(try? HAL.read(object,kAudioObjectPropertyOwner,default:AudioObjectID(0))) ?? 0
                    return ["class":cls,"ownerIsAggregate":owner==aggregate,"privateSubdevice":cls==kAudioSubDeviceClassID && owner==aggregate]
                }
                // Only a genuine subdevice owned by this private aggregate may
                // be mutated. ActiveSubDeviceList IDs are not assumed private.
                for object in owned {
                    guard (try? HAL.read(object,kAudioObjectPropertyClass,default:UInt32(0)))==kAudioSubDeviceClassID,
                          (try? HAL.read(object,kAudioObjectPropertyOwner,default:AudioObjectID(0)))==aggregate,
                          HAL.isSettable(object,kAudioSubDevicePropertyExtraLatency,scope:kAudioObjectPropertyScopeOutput) else { continue }
                    let saved=try HAL.read(object,kAudioSubDevicePropertyExtraLatency,default:Double(0),scope:kAudioObjectPropertyScopeOutput)
                    defer { try? HAL.write(object,kAudioSubDevicePropertyExtraLatency,value:saved,scope:kAudioObjectPropertyScopeOutput) }
                    try HAL.write(object,kAudioSubDevicePropertyExtraLatency,value:extra,scope:kAudioObjectPropertyScopeOutput)
                    Thread.sleep(forTimeInterval:0.1)
                    row["ownedSubdeviceExtraReadback"]=try HAL.read(object,kAudioSubDevicePropertyExtraLatency,default:Double(0),scope:kAudioObjectPropertyScopeOutput)
                    row["afterOwnedSubdeviceWrite"]=describe(aggregate)
                }
                let start=AudioDeviceStart(aggregate,nil);row["startClockStatus"]=start;running=start==noErr
                if running {
                    Thread.sleep(forTimeInterval:0.15)
                    row["running"]=describe(aggregate)
                    let probe=HardwareTimingProbe()
                    do {
                        try probe.start(aggregate)
                        Thread.sleep(forTimeInterval:0.15)
                        row["ioTiming"]=probe.mailbox.consume().dictionary(frequency:AudioGetHostClockFrequency())
                        probe.stop();row["ioProbeCleanup"]=probe.cleanup
                    } catch { probe.stop();row["ioProbeError"]=error.localizedDescription }
                    if config.name=="single-baseline",HAL.isSettable(aggregate,kAudioAggregateDevicePropertyComposition) {
                        var changed=composition
                        changed[kAudioAggregateDeviceSubDeviceListKey]=[[kAudioSubDeviceUIDKey:primary.uid,kAudioSubDeviceExtraOutputLatencyKey:extra]]
                        do {
                            try HAL.write(aggregate,kAudioAggregateDevicePropertyComposition,value:changed as CFDictionary)
                            Thread.sleep(forTimeInterval:0.3)
                            row["afterLiveCompositionUpdate"]=describe(aggregate)
                            try HAL.write(aggregate,kAudioAggregateDevicePropertyComposition,value:composition as CFDictionary)
                        } catch { row["compositionUpdateError"]=error.localizedDescription }
                    }
                    var stamp=AudioTimeStamp();stamp.mFlags=[.sampleTimeValid,.hostTimeValid]
                    let current=AudioDeviceGetCurrentTime(aggregate,&stamp)
                    row["clockStatus"]=current
                    row["validClock"]=current==noErr && stamp.mHostTime>0 && stamp.mFlags.contains([.sampleTimeValid,.hostTimeValid])
                }
            } catch { row["error"]=error.localizedDescription }
            if running { row["stopStatus"]=AudioDeviceStop(aggregate,nil) }
            if aggregate != 0 { row["destroyStatus"]=AudioHardwareDestroyAggregateDevice(aggregate) }
            row["defaultPreserved"]=DeviceManager().defaultOutput()==original
            rows.append(row)
            if DeviceManager().defaultOutput() != original { break }
        }
        return ["scope":"Private aggregate latency declarations, before and while running; no default route change, no audio content, no physical property writes","fourSecondDeclarationFrames":extra,"cases":rows,"defaultPreserved":DeviceManager().defaultOutput()==original,"date":ISO8601DateFormatter().string(from:Date())]
    }
    private static func describe(_ id:AudioObjectID)->[String:Any] {
        var row:[String:Any]=[:]
        row["deviceLatencyFrames"]=try? HAL.read(id,kAudioDevicePropertyLatency,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
        row["latencySettable"]=HAL.isSettable(id,kAudioDevicePropertyLatency,scope:kAudioObjectPropertyScopeOutput)
        row["streamLatencyFrames"]=((try? HAL.objects(id,kAudioDevicePropertyStreams,scope:kAudioObjectPropertyScopeOutput)) ?? []).compactMap { try? HAL.read($0,kAudioStreamPropertyLatency,default:UInt32(0)) }
        row["safetyOffsetFrames"]=try? HAL.read(id,kAudioDevicePropertySafetyOffset,default:UInt32(0),scope:kAudioObjectPropertyScopeOutput)
        let engine=AVAudioEngine()
        do { try engine.outputNode.auAudioUnit.setDeviceID(id);row["auLatencyMS"]=engine.outputNode.auAudioUnit.deviceOutputLatency*1000;row["avPresentationLatencyMS"]=engine.outputNode.presentationLatency*1000 }
        catch { row["auQueryError"]=error.localizedDescription }
        return row
    }
}
