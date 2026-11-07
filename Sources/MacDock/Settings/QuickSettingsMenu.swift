import AppKit

/// The most-used dock settings as menu items, shared by the menu bar icon and the
/// dock's right-click menu. Items read the store when built, so build them each time
/// a menu opens to keep checkmarks current.
@MainActor
enum QuickSettingsMenu {
    /// Appends the quick settings to a menu.
    /// - Parameters:
    ///   - objMenu: Menu to extend.
    ///   - objSettings: Store the items read and write.
    static func add(to objMenu: NSMenu, objSettings: SettingsStore) {
        objMenu.addItem(submenuItem("Position on Screen", strSymbol: "dock.rectangle") { objSubmenu in
            for enmPosition in DockPosition.allCases {
                objSubmenu.addItem(ClosureMenuItem(enmPosition.strTitle,
                                                   objState: objSettings.enmPosition == enmPosition ? .on : .off) {
                    objSettings.enmPosition = enmPosition
                })
            }
        })

        objMenu.addItem(ClosureMenuItem("Automatically Hide Dock", objState: objSettings.blnAutoHide ? .on : .off) {
            objSettings.blnAutoHide.toggle()
        })
        objMenu.addItem(ClosureMenuItem("Magnification", objState: objSettings.blnMagnificationOn ? .on : .off) {
            objSettings.blnMagnificationOn.toggle()
        })

        // Only meaningful with more than one display.
        if NSScreen.screens.count > 1 {
            objMenu.addItem(submenuItem("Show Dock On", strSymbol: "display") { objSubmenu in
                for enmMode in DockDisplayMode.allCases {
                    objSubmenu.addItem(ClosureMenuItem(enmMode.strTitle,
                                                       objState: objSettings.enmDisplayMode == enmMode ? .on : .off) {
                        objSettings.enmDisplayMode = enmMode
                    })
                }
            })
        }

        objMenu.addItem(submenuItem("Widgets", strSymbol: "square.grid.2x2") { objSubmenu in
            objSubmenu.addItem(ClosureMenuItem("Now Playing", objState: objSettings.blnShowNowPlaying ? .on : .off) {
                objSettings.blnShowNowPlaying.toggle()
            })
            objSubmenu.addItem(ClosureMenuItem("Battery", objState: objSettings.blnShowBattery ? .on : .off) {
                objSettings.blnShowBattery.toggle()
            })
            objSubmenu.addItem(.separator())

            // Player options apply only while the Now Playing widget is on.
            let objSizeItem = submenuItem("Now Playing Size", strSymbol: nil) { objSizeMenu in
                for enmSize in NowPlayingSize.allCases {
                    objSizeMenu.addItem(ClosureMenuItem(enmSize.strTitle,
                                                        objState: objSettings.enmNowPlayingSize == enmSize ? .on : .off) {
                        objSettings.enmNowPlayingSize = enmSize
                    })
                }
            }
            let objSeekItem = submenuItem("Seek Bar", strSymbol: nil) { objSeekMenu in
                for enmStyle in SeekBarStyle.allCases {
                    objSeekMenu.addItem(ClosureMenuItem(enmStyle.strTitle,
                                                        objState: objSettings.enmSeekBarStyle == enmStyle ? .on : .off) {
                        objSettings.enmSeekBarStyle = enmStyle
                    })
                }
            }
            objSizeItem.isEnabled = objSettings.blnShowNowPlaying
            objSeekItem.isEnabled = objSettings.blnShowNowPlaying
            objSubmenu.addItem(objSizeItem)
            objSubmenu.addItem(objSeekItem)
        })

        objMenu.addItem(ClosureMenuItem("Hide Native Dock", objState: objSettings.blnHideNativeDock ? .on : .off) {
            objSettings.blnHideNativeDock.toggle()
        })
    }

    /// Builds a menu item that opens a submenu.
    /// - Parameters:
    ///   - strTitle: Item title.
    ///   - strSymbol: Optional SF Symbol shown beside the title.
    ///   - fnFill: Populates the submenu.
    /// - Returns: The item.
    private static func submenuItem(_ strTitle: String, strSymbol: String?, _ fnFill: (NSMenu) -> Void) -> NSMenuItem {
        let objItem = NSMenuItem(title: strTitle, action: nil, keyEquivalent: "")
        let objSubmenu = NSMenu(title: strTitle)
        // Submenu items are enabled by their own targets, not by responder-chain validation.
        objSubmenu.autoenablesItems = false
        fnFill(objSubmenu)
        objItem.submenu = objSubmenu
        if let strSymbol {
            objItem.image = NSImage(systemSymbolName: strSymbol, accessibilityDescription: nil)
        }
        return objItem
    }
}
