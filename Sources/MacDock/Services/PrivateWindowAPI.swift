import ApplicationServices
import Darwin
import Foundation

/// Optional wrappers around undocumented window-server functions.
///
/// Symbols are resolved at runtime with `dlsym`, so if a macOS update removes
/// them every call just returns `nil`/`false` and callers fall back to public
/// APIs. Approach follows AltTab (https://github.com/lwouis/alt-tab-macos).
@MainActor
enum PrivateWindowAPI {
    private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias GetProcessForPidFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// Mask for `SLSCopySpacesForWindows`: current, other and all Spaces.
    private static let intAllSpacesMask: Int32 = 7

    /// `kCPSUserGenerated`: treat the activation as if the user clicked the window.
    private static let intUserGeneratedMode: UInt32 = 0x200

    private static let objSkyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let objDefaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    private static let fnAXGetWindow: AXGetWindowFn? = symbol("_AXUIElementGetWindow", objHandle: objDefaultHandle)
    private static let fnGetProcessForPid: GetProcessForPidFn? = symbol("GetProcessForPID", objHandle: objDefaultHandle)
    private static let fnSetFrontProcess: SetFrontProcessFn? = symbol("_SLPSSetFrontProcessWithOptions", objHandle: objSkyLight)
    private static let fnPostEventRecord: PostEventRecordFn? = symbol("SLPSPostEventRecordTo", objHandle: objSkyLight)
    private static let fnMainConnection: MainConnectionFn? = symbol("SLSMainConnectionID", objHandle: objSkyLight)
    private static let fnCopySpacesForWindows: CopySpacesForWindowsFn? = symbol("SLSCopySpacesForWindows", objHandle: objSkyLight)

    private typealias GetActiveSpaceFn = @convention(c) (Int32) -> UInt64
    private static let fnGetActiveSpace: GetActiveSpaceFn? = symbol("SLSGetActiveSpace", objHandle: objSkyLight)

    /// Spaces a window belongs to. Real windows on other desktops have one;
    /// hidden helper windows and closed-but-cached windows have none.
    /// - Parameter intWindowId: Window to check.
    /// - Returns: Space IDs, or `nil` if the API is unavailable.
    static func spaces(for intWindowId: CGWindowID) -> [UInt64]? {
        guard let fnMainConnection, let fnCopySpacesForWindows else { return nil }
        let arrObjIds = [NSNumber(value: intWindowId)] as CFArray
        guard let objResult = fnCopySpacesForWindows(fnMainConnection(), intAllSpacesMask, arrObjIds)?.takeRetainedValue() else {
            return []
        }
        return (objResult as? [NSNumber])?.map(\.uint64Value) ?? []
    }

    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private static let fnCopyManagedDisplaySpaces: CopyManagedDisplaySpacesFn? = symbol("SLSCopyManagedDisplaySpaces", objHandle: objSkyLight)

    /// Space type the window server uses for full-screen app Spaces.
    private static let intFullScreenSpaceType = 4

    /// Human labels for every Space, numbered like Mission Control and the
    /// "Switch to Desktop N" shortcuts: regular desktops count up across all
    /// displays in order; full-screen app Spaces are labeled "Full Screen".
    /// - Returns: Label per Space ID (empty if the API is unavailable).
    static func desktopLabels() -> [UInt64: String] {
        guard let fnMainConnection, let fnCopyManagedDisplaySpaces,
              let arrDictDisplays = fnCopyManagedDisplaySpaces(fnMainConnection())?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }

        var dictStrLabels: [UInt64: String] = [:]
        var intDesktopNumber = 0
        for dictDisplay in arrDictDisplays {
            for dictSpace in dictDisplay["Spaces"] as? [[String: Any]] ?? [] {
                guard let intSpaceId = ((dictSpace["id64"] ?? dictSpace["ManagedSpaceID"]) as? NSNumber)?.uint64Value else { continue }
                if (dictSpace["type"] as? Int) == intFullScreenSpaceType {
                    dictStrLabels[intSpaceId] = "Full Screen"
                } else {
                    intDesktopNumber += 1
                    dictStrLabels[intSpaceId] = "Desktop \(intDesktopNumber)"
                }
            }
        }
        return dictStrLabels
    }

    /// ID of the Space currently shown on the active display.
    /// - Returns: Space ID, or `nil` if the API is unavailable.
    static func activeSpace() -> UInt64? {
        guard let fnMainConnection, let fnGetActiveSpace else { return nil }
        return fnGetActiveSpace(fnMainConnection())
    }

    private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let fnCreateWithRemoteToken: CreateWithRemoteTokenFn? = symbol("_AXUIElementCreateWithRemoteToken", objHandle: objDefaultHandle)

    /// Highest AX element ID probed when searching for an off-Space window.
    private static let intMaxProbedElementId: UInt64 = 1000

    /// Finds the AX element of a window on another Space. `kAXWindowsAttribute`
    /// only lists current-Space windows, but every window's element can still be
    /// rebuilt from a remote token (pid + "coco" marker + element ID) by probing
    /// element IDs, the way AltTab does. Raising that element makes macOS switch
    /// to the window's Space.
    /// - Parameters:
    ///   - intWindowId: Window to find.
    ///   - intPid: Owning process ID.
    /// - Returns: Its AX element, or `nil` if not found or the API is unavailable.
    static func axElement(forWindowId intWindowId: CGWindowID, intPid: pid_t) -> AXUIElement? {
        guard let fnCreateWithRemoteToken else { return nil }

        // Token layout: pid (4 bytes) | 0 (4) | "coco" (4) | element ID (8).
        var objToken = Data(count: 20)
        withUnsafeBytes(of: intPid.littleEndian) { objToken.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: Int32(0x636f_636f).littleEndian) { objToken.replaceSubrange(8..<12, with: $0) }

        for intElementId in 0..<intMaxProbedElementId {
            withUnsafeBytes(of: intElementId.littleEndian) { objToken.replaceSubrange(12..<20, with: $0) }
            guard let objElement = fnCreateWithRemoteToken(objToken as CFData)?.takeRetainedValue() else { continue }
            if windowId(for: objElement) == intWindowId {
                return objElement
            }
        }
        return nil
    }

    /// Maps an AX window element to its window-server ID.
    /// - Parameter objElement: An AX window.
    /// - Returns: The `CGWindowID`, or `nil` if unavailable.
    static func windowId(for objElement: AXUIElement) -> CGWindowID? {
        guard let fnAXGetWindow else { return nil }
        var intWindowId: CGWindowID = 0
        guard fnAXGetWindow(objElement, &intWindowId) == .success, intWindowId != 0 else { return nil }
        return intWindowId
    }

    /// Fronts the owning process with this exact window on top and makes it key.
    /// - Parameters:
    ///   - intWindowId: Target window ID.
    ///   - intPid: Owning process ID.
    /// - Returns: `true` if the private calls were available and issued.
    static func focus(intWindowId: CGWindowID, intPid: pid_t) -> Bool {
        guard let fnGetProcessForPid, let fnSetFrontProcess, let fnPostEventRecord else { return false }

        var objPsn = ProcessSerialNumber()
        guard fnGetProcessForPid(intPid, &objPsn) == noErr else { return false }

        _ = fnSetFrontProcess(&objPsn, intWindowId, intUserGeneratedMode)

        // Two synthetic window-server events that make the window key
        // (layout reverse-engineered by the AltTab project).
        for intEventType: UInt8 in [0x01, 0x02] {
            var arrIntBytes = [UInt8](repeating: 0, count: 0xF8)
            arrIntBytes[0x04] = 0xF8
            arrIntBytes[0x08] = intEventType
            arrIntBytes[0x3A] = 0x10
            for intOffset in 0x20..<0x30 {
                arrIntBytes[intOffset] = 0xFF
            }
            withUnsafeBytes(of: intWindowId.littleEndian) { objRaw in
                for (intIndex, intByte) in objRaw.enumerated() {
                    arrIntBytes[0x3C + intIndex] = intByte
                }
            }
            _ = arrIntBytes.withUnsafeMutableBufferPointer { objBuffer in
                fnPostEventRecord(&objPsn, objBuffer.baseAddress!)
            }
        }
        return true
    }

    /// Resolves a C symbol and casts it to a function type.
    /// - Parameters:
    ///   - strName: Symbol name.
    ///   - objHandle: `dlopen` handle (or RTLD_DEFAULT) to search.
    /// - Returns: The typed function pointer, or `nil` if not found.
    private static func symbol<T>(_ strName: String, objHandle: UnsafeMutableRawPointer?) -> T? {
        guard let objHandle, let objSymbol = dlsym(objHandle, strName) else { return nil }
        return unsafeBitCast(objSymbol, to: T.self)
    }
}
