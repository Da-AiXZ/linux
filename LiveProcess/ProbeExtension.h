#pragma once

#include <mach/mach.h>
#include <sys/types.h>

int ProbeExtensionRun(pid_t hostPid, mach_port_t servicePort);
