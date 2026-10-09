#include <ApplicationServices/ApplicationServices.h>
#include "SkyLight.h"

// GetProcessForPID is unavailable to Swift but still works; SkyLight focus calls need a PSN.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus BSProcessForPID(pid_t pid, ProcessSerialNumber *psn)
{
    return GetProcessForPID(pid, psn);
}

OSStatus BSPIDForProcess(const ProcessSerialNumber *psn, pid_t *pid)
{
    return GetProcessPID(psn, pid);
}
#pragma clang diagnostic pop
