#include "PAPowerTemperatureBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

// These event-reading functions are exported by IOKit but are not part of
// the public umbrella header. PAPower already relies on AppleSMC for board
// power, so the temperature path has the same non-App-Store compatibility
// boundary documented by the project.
typedef const void *PAIOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(
    CFAllocatorRef allocator
);
extern int IOHIDEventSystemClientSetMatching(
    IOHIDEventSystemClientRef client,
    CFDictionaryRef matching
);
extern PAIOHIDEventRef IOHIDServiceClientCopyEvent(
    IOHIDServiceClientRef service,
    int64_t eventType,
    int32_t options,
    int64_t timeout
);
extern double IOHIDEventGetFloatValue(
    PAIOHIDEventRef event,
    int64_t field
);

static const int32_t kPATemperatureEventType = 15;
static const int32_t kPAAppleVendorUsagePage = 0xff00;
static const int32_t kPATemperatureSensorUsage = 0x0005;

static void PACopyPropertyString(
    IOHIDServiceClientRef service,
    CFStringRef key,
    char *destination,
    CFIndex destinationSize
) {
    destination[0] = '\0';
    CFTypeRef value = IOHIDServiceClientCopyProperty(service, key);
    if (value == NULL) {
        return;
    }

    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString(
            (CFStringRef)value,
            destination,
            destinationSize,
            kCFStringEncodingUTF8
        );
    } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int64_t number = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number)) {
            snprintf(destination, (size_t)destinationSize, "%lld", number);
        }
    }
    CFRelease(value);
}

int32_t PAReadTemperatureSensors(
    PATemperatureSensorReading *buffer,
    int32_t capacity
) {
    if (buffer == NULL || capacity <= 0) {
        return 0;
    }

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(
        kCFAllocatorDefault
    );
    if (client == NULL) {
        return 0;
    }

    int32_t usagePage = kPAAppleVendorUsagePage;
    int32_t usage = kPATemperatureSensorUsage;
    CFNumberRef usagePageNumber = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt32Type,
        &usagePage
    );
    CFNumberRef usageNumber = CFNumberCreate(
        kCFAllocatorDefault,
        kCFNumberSInt32Type,
        &usage
    );
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { usagePageNumber, usageNumber };
    CFDictionaryRef matching = CFDictionaryCreate(
        kCFAllocatorDefault,
        keys,
        values,
        2,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    if (matching != NULL) {
        IOHIDEventSystemClientSetMatching(client, matching);
        CFRelease(matching);
    }
    if (usagePageNumber != NULL) {
        CFRelease(usagePageNumber);
    }
    if (usageNumber != NULL) {
        CFRelease(usageNumber);
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services == NULL) {
        CFRelease(client);
        return 0;
    }

    int32_t written = 0;
    CFIndex serviceCount = CFArrayGetCount(services);
    for (CFIndex index = 0; index < serviceCount && written < capacity; index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)
            CFArrayGetValueAtIndex(services, index);
        PAIOHIDEventRef event = IOHIDServiceClientCopyEvent(
            service,
            kPATemperatureEventType,
            0,
            0
        );
        if (event == NULL) {
            continue;
        }

        double celsius = IOHIDEventGetFloatValue(
            event,
            ((int64_t)kPATemperatureEventType) << 16
        );
        CFRelease(event);
        if (!isfinite(celsius) || celsius < -20 || celsius > 150) {
            continue;
        }

        PATemperatureSensorReading reading = {0};
        PACopyPropertyString(
            service,
            CFSTR("Product"),
            reading.name,
            sizeof(reading.name)
        );
        PACopyPropertyString(
            service,
            CFSTR("SerialNumber"),
            reading.identifier,
            sizeof(reading.identifier)
        );
        reading.celsius = celsius;
        buffer[written++] = reading;
    }

    CFRelease(services);
    CFRelease(client);
    return written;
}
