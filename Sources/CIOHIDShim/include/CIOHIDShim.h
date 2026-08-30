// Declarations for the private IOKit HID event-system API used to read Apple
// Silicon temperature sensors.
//
// These symbols are exported by IOKit but absent from its public headers. There
// is no supported alternative: on Apple Silicon, CPU die temperatures are not
// available through SMC keys the way they were on Intel. Other open-source tools
// (Stats, smctemp, macmon) read them the same way.
//
// Everything here is read-only and unprivileged. If Apple removes or changes
// these symbols, the calls return NULL and the app reports temperature as
// unavailable — see Temperature.swift, which treats that as an expected state.
//
// The inline helpers at the bottom exist so CoreFoundation ownership stays on
// the C side: Swift cannot call CFRelease, and these functions return +1
// references that must be released.

#ifndef CIOHIDSHIM_H
#define CIOHIDSHIM_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

typedef struct __IOHIDEvent *CIOHIDEventRef;
typedef struct __IOHIDServiceClient *CIOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *CIOHIDEventSystemClientRef;

extern CIOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientSetMatching(CIOHIDEventSystemClientRef client,
                                              CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(CIOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(CIOHIDServiceClientRef service,
                                                CFStringRef key);
extern CIOHIDEventRef IOHIDServiceClientCopyEvent(CIOHIDServiceClientRef service,
                                                  int64_t type,
                                                  int32_t options,
                                                  int64_t timestamp);
extern double IOHIDEventGetFloatValue(CIOHIDEventRef event, int32_t field);

// Apple vendor HID usage page, and the usage identifying a temperature sensor.
#define kCIOHIDPageAppleVendor 0xff00
#define kCIOHIDUsageAppleVendorTemperatureSensor 0x0005

#define kCIOHIDEventTypeTemperature 15

// IOHIDEventFieldBase(type) — the field selector for an event type is the type
// shifted into the high half of the word.
static inline int32_t CIOHIDEventFieldBase(int32_t type) { return type << 16; }

// MARK: - Ownership-safe wrappers

/// Read one sensor's temperature in Celsius. Returns 0 on failure, 1 on success.
static inline int CIOHIDReadTemperature(CIOHIDServiceClientRef service, double *outCelsius) {
    CIOHIDEventRef event = IOHIDServiceClientCopyEvent(
        service, kCIOHIDEventTypeTemperature, 0, 0);
    if (!event) return 0;
    *outCelsius = IOHIDEventGetFloatValue(
        event, CIOHIDEventFieldBase(kCIOHIDEventTypeTemperature));
    CFRelease((CFTypeRef)event);
    return 1;
}

/// Copy a sensor's product name into `buffer`. Returns 0 on failure, 1 on success.
static inline int CIOHIDCopySensorName(CIOHIDServiceClientRef service,
                                       char *buffer,
                                       long bufferSize) {
    CFTypeRef property = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
    if (!property) return 0;

    int ok = 0;
    if (CFGetTypeID(property) == CFStringGetTypeID()) {
        ok = CFStringGetCString((CFStringRef)property, buffer, bufferSize,
                                kCFStringEncodingUTF8) ? 1 : 0;
    }
    CFRelease(property);
    return ok;
}

/// The SMC key backing a sensor, as a four-character code.
///
/// `LocationID` holds the SMC key: "NAND CH0 temp" reports 'TN0n', "PMU tdie1"
/// reports 'TP1b'. That is genuine identifying information, unlike the display
/// name, which repeats across services.
/// Returns 0 when unavailable.
static inline uint32_t CIOHIDCopySensorKey(CIOHIDServiceClientRef service) {
    CFTypeRef property = IOHIDServiceClientCopyProperty(service, CFSTR("LocationID"));
    if (!property) return 0;

    uint32_t value = 0;
    if (CFGetTypeID(property) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)property, kCFNumberSInt32Type, &value);
    }
    CFRelease(property);
    return value;
}

/// Release a client created by IOHIDEventSystemClientCreate.
static inline void CIOHIDReleaseClient(CIOHIDEventSystemClientRef client) {
    if (client) CFRelease((CFTypeRef)client);
}

#endif /* CIOHIDSHIM_H */
