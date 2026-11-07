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

    /// Whether a window belongs to any Space. Real windows on other desktops do;
    /// hidden helper windows and closed-but-cached windows don't.
    /// - Parameter intWindowId: Window to check.
    /// - Returns: `true` if it lives on a Space, `nil` if the API is unavailable.
    static func isOnAnySpace(_ intWindowId: CGWindowID) -> Bool? {
        guard let fnMainConnection, let fnCopySpacesForWindows else { return nil }
        let arrObjIds = [NSNumber(value: intWindowId)] as CFArray
        guard let objResult = fnCopySpacesForWindows(fnMainConnection(), intAllSpacesMask, arrObjIds)?.takeRetainedValue() else {
            return false
        }
        return CFArrayGetCount(objResult) > 0
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
