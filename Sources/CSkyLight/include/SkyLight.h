// Private SkyLight/CGS declarations. Symbols resolve at load time from the
// SkyLight framework; each is verified on macOS 27.0.
// WindowSpaceMove.{c,h} are vendored unchanged from WhichSpace (MIT, see LICENSE-WhichSpace).

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>

typedef int CGSConnectionID;
typedef uint32_t CGSSymbolicHotKey;

extern CGSConnectionID SLSMainConnectionID(void);
extern CFArrayRef SLSCopyManagedDisplaySpaces(CGSConnectionID cid);
// The UUID of the display with the active menu bar, the one keyboard commands act on.
extern CFStringRef SLSCopyActiveMenuBarDisplayIdentifier(CGSConnectionID cid);
extern CFArrayRef SLSCopySpacesForWindows(CGSConnectionID cid, int selector, CFArrayRef windowIDs);
extern CGError CGSGetSymbolicHotKeyValue(CGSSymbolicHotKey hotKey, uint16_t *outKeyEquivalent, CGKeyCode *outVirtualKeyCode, uint32_t *outModifiers);
extern bool CGSIsSymbolicHotKeyEnabled(CGSSymbolicHotKey hotKey);
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outWindowID);

// Focus a specific window of another process (the path yabai uses without SIP).
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t windowID, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);

// Wraps GetProcessForPID, which Swift cannot call directly.
extern OSStatus BSProcessForPID(pid_t pid, ProcessSerialNumber *psn);

// The frontmost process as the window server sees it. Unlike NSWorkspace, this is current right
// after a kCPSNoWindows activation.
extern CGError _SLPSGetFrontProcess(ProcessSerialNumber *psn);
// Wraps GetProcessPID, which Swift cannot call directly.
extern OSStatus BSPIDForProcess(const ProcessSerialNumber *psn, pid_t *pid);
