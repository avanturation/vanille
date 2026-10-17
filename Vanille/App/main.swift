import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var eq: EqualizerWindowController?
    private var settings: SettingsWindowController?
    private var terminationToken: NSObjectProtocol?
    #if VANILLE_DIAGNOSTICS
    private var verification: LiveVerification?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image = UI.symbol("speaker.wave.2",label:"Vanille")
        item.button?.image?.isTemplate = true
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
        item.button?.setAccessibilityLabel("Vanille audio controls")
        item.button?.toolTip = "Vanille"
        popover.behavior = .transient; popover.animates = false
        let controller = MenuBarViewController(state:state)
        controller.showEQ = { [weak self] in self?.showEqualizer() }
        controller.showSettings = { [weak self] in self?.showSettings() }
        controller.onSizeChange = { [weak self] in self?.popover.contentSize = $0 }
        popover.contentViewController = controller
        popover.contentSize = NSSize(width:348,height:430)
        state.start()
        if CommandLine.arguments.contains("--show") { showPopover() }
    }
    private func installMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(title:"Vanille"); appItem.submenu = appMenu
        appMenu.addItem(withTitle:"Settings…",action:#selector(showSettings),keyEquivalent:",").target = self
        #if VANILLE_DIAGNOSTICS
        appMenu.addItem(withTitle:"Run Audio Verification…",action:#selector(runVerification),keyEquivalent:"t").target = self
        appMenu.addItem(withTitle:"Toggle Test Appearance",action:#selector(toggleTestAppearance),keyEquivalent:"d").target = self
        #endif
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit Vanille",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title:"Edit"); editItem.submenu = edit
        edit.addItem(withTitle:"Undo",action:Selector(("undo:")),keyEquivalent:"z")
        edit.addItem(withTitle:"Cut",action:#selector(NSText.cut(_:)),keyEquivalent:"x")
        edit.addItem(withTitle:"Copy",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
        edit.addItem(withTitle:"Paste",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        NSApp.mainMenu = menu
    }
    @objc func togglePopover() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps:true)
        popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    private func showContextMenu() {
        let menu = NSMenu()
        let pause = NSMenuItem(title:state.saved.processingPaused ? "Start Processing" : "Pause Audio Processing",action:#selector(togglePause),keyEquivalent:"")
        pause.target = self; menu.addItem(pause)
        menu.addItem(withTitle:"Restore Default Audio",action:#selector(restore),keyEquivalent:"").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle:"Settings…",action:#selector(showSettings),keyEquivalent:",").target = self
        menu.addItem(withTitle:"Quit Vanille",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        if let button = item.button { menu.popUp(positioning:nil,at:NSPoint(x:0,y:button.bounds.minY),in:button) }
    }
    @objc private func togglePause() { state.setPaused(!state.saved.processingPaused) }
    @objc private func restore() { state.restoreOriginalAudio() }
    #if VANILLE_DIAGNOSTICS
    @objc private func runVerification() {
        popover.performClose(nil)
        verification = LiveVerification(state: state); verification?.run()
    }
    @objc private func toggleTestAppearance() {
        NSApp.appearance = NSApp.appearance?.name == .darkAqua ? nil : NSAppearance(named:.darkAqua)
    }
    #endif
    @objc func showEqualizer() {
        popover.performClose(nil)
        if eq == nil { eq = EqualizerWindowController(state:state) }
        eq?.showWindow(nil); NSApp.activate(ignoringOtherApps:true); eq?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func showSettings() {
        popover.performClose(nil)
        if settings == nil { settings = SettingsWindowController(state:state) }
        settings?.showWindow(nil); NSApp.activate(ignoringOtherApps:true); settings?.window?.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ notification:Notification) { state.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { showPopover(); return true }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
