#ifndef PAPowerTemperatureBridge_h
#define PAPowerTemperatureBridge_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char name[128];
    char identifier[128];
    double celsius;
} PATemperatureSensorReading;

/// Reads temperature services exposed by the Apple HID event system.
/// Returns the total number written to `buffer` (up to `capacity`).
int32_t PAReadTemperatureSensors(
    PATemperatureSensorReading *buffer,
    int32_t capacity
);

#ifdef __cplusplus
}
#endif

#endif /* PAPowerTemperatureBridge_h */
