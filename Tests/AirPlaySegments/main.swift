import Foundation
do {
    let result=try runAirPlaySegmentChecks()
    print(result.report)
    exit(result.failures == 0 ? 0 : 1)
} catch let failure as AudioFailure where failure.status == 1970171760 {
    // Some shell sandboxes cannot reach Apple's AAC encoder service. The native
    // experiment runs these same checks through its Playback menu in that case.
    print("SKIP Native AAC service unavailable in this shell; run Native Stream Checks in the app")
    exit(0)
} catch {
    print("FAIL \(error.localizedDescription)")
    exit(1)
}
