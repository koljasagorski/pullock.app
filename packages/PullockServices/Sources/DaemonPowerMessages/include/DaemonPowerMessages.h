#ifndef PULLOCK_DAEMON_POWER_MESSAGES_H
#define PULLOCK_DAEMON_POWER_MESSAGES_H
#include <stdint.h>
#include <IOKit/IOMessage.h>
// Resolve function-like SDK macros in C rather than hard-coding IOKit values.
static const uint32_t PLDaemonCanSleep = kIOMessageCanSystemSleep;
static const uint32_t PLDaemonWillSleep = kIOMessageSystemWillSleep;
static const uint32_t PLDaemonWillWake = kIOMessageSystemWillPowerOn;
static const uint32_t PLDaemonDidWake = kIOMessageSystemHasPoweredOn;
#endif
