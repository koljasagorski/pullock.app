#ifndef PULLOCK_POWER_MESSAGES_H
#define PULLOCK_POWER_MESSAGES_H

#include <stdint.h>
#include <IOKit/IOMessage.h>

// Swift cannot import the function-like iokit_common_msg macros. Resolve them
// in the installed SDK, rather than copying their numeric values into Swift.
static const uint32_t PLCanSystemSleep = kIOMessageCanSystemSleep;
static const uint32_t PLSystemWillSleep = kIOMessageSystemWillSleep;
static const uint32_t PLSystemWillNotSleep = kIOMessageSystemWillNotSleep;
static const uint32_t PLSystemWillPowerOn = kIOMessageSystemWillPowerOn;
static const uint32_t PLSystemHasPoweredOn = kIOMessageSystemHasPoweredOn;

#endif
