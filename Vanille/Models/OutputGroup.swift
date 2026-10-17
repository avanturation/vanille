import Foundation

struct DeviceRoute: Codable, Equatable, Identifiable {
    var id: String // Core Audio Device UID, or an explicitly unassigned configuration slot.
    var name: String
    var enabled = true
    var volume: Float = 1
    var muted = false
    var delayMS: Double = 0
    var isAssigned: Bool { !id.hasPrefix("unassigned.") }
    mutating func sanitize() {
        volume = volume.isFinite ? min(1,max(0,volume)) : 1
        delayMS = delayMS.isFinite ? min(3_000,max(0,delayMS)) : 0
    }
}

struct OutputGroup: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var devices: [DeviceRoute]
    static var defaults: [OutputGroup] {
        let wired = DeviceRoute(id:"unassigned.wired",name:"MR4 / Wired Output")
        let homepod = DeviceRoute(id:"unassigned.homepod",name:"HomePod Stereo Pair")
        let mini = DeviceRoute(id:"unassigned.mini",name:"HomePod mini Stereo Pair")
        return [OutputGroup(id:"group.desktop",name:"Desktop",devices:[wired]),
                OutputGroup(id:"group.homepods",name:"HomePods",devices:[homepod,mini]),
                OutputGroup(id:"group.immersive",name:"Immersive",devices:[wired,homepod]),
                OutputGroup(id:"group.fullroom",name:"Full Room",devices:[wired,homepod,mini])]
    }
}
