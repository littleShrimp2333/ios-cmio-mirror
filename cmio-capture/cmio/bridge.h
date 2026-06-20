// bridge.h — C interface for the CoreMediaIO capture bridge.
// Called from Go via CGO; implementation in bridge_darwin.m.
#ifndef CMIO_BRIDGE_H
#define CMIO_BRIDGE_H

#include <stdint.h>

// ---- device discovery ----

// cmio_list_devices writes a JSON array of muxed iOS device objects into
// *json.  Each object has keys: "uniqueID", "name", "modelID".  Caller must
// free with cmio_free_str.  Returns the number of devices (0 if none).
// Gate lifecycle is managed internally (sets allow-gates, pokes HAL, waits
// for devices to surface, restores gates).
int cmio_list_devices(char **json);

// ---- recording ----

// cmio_record captures the screen of the muxed iOS device identified by
// uniqueID to a QuickTime .mov file.
//
//   uniqueID    — device uniqueID from cmio_device_info (or "" for first device)
//   outputPath  — destination .mov file (overwritten if exists)
//   duration    — target media duration in seconds (actual, not wall-clock)
//   captureAudio — 1 to include the muxed audio track, 0 for video-only
//
// Returns 0 on success.  On failure returns a non-zero code and sets *errMsg.
int cmio_record(const char *uniqueID, const char *outputPath, double duration,
                int captureAudio, char **errMsg);

// ---- cleanup ----

void cmio_free_str(char *s);

#endif
