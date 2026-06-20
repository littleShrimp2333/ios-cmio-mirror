// Package cmio provides Go bindings for iOS screen capture via the
// CoreMediaIO bridge on macOS.
//
// It wraps the proven CoreMediaIO + AVFoundation recipe (see
// docs/ios-host-screen-capture-options.md). The bridge requires a paired and
// connected iPhone.
//
// Multi-device: each paired iPhone surfaces as a separate AVCaptureDevice
// (different uniqueID). Use ListDevices to enumerate them and RecordDevice to
// capture a specific device. Record is a convenience that captures the first
// available device.
//
// Audio: capturing the muxed audio track takes over the device audio channel
// (on-device playback is interrupted during capture, recovers after stop).
// Pass AudioVideo to include the audio track, or VideoOnly to leave it out of
// the file. Even with VideoOnly, the bridge still briefly activates the muxed
// audio path internally — the only way to fully avoid audio-channel takeover is
// to use a different capture route (e.g. Instruments screenshots or AirPlay).
package cmio

/*
#cgo LDFLAGS: -framework Foundation -framework CoreMediaIO -framework AVFoundation -framework CoreMedia
#include "bridge.h"
*/
import "C"

import (
	"encoding/json"
	"errors"
	"fmt"
)

// DevInfo describes a discovered muxed iOS device.
type DevInfo struct {
	UniqueID string `json:"uniqueID"`
	Name     string `json:"name"`
	ModelID  string `json:"modelID"`
}

// Mode selects whether the recorded .mov includes the muxed audio track.
type Mode int

const (
	// VideoOnly records video only (the audio connection on the movie output
	// is disabled).
	VideoOnly Mode = iota
	// AudioVideo records both video and audio. The device audio channel is
	// taken over for the duration of the capture.
	AudioVideo
)

// ListDevices returns all muxed iOS devices currently visible to the
// CoreMediaIO bridge. It sets the allow-gates, pokes the HAL, waits for
// devices to surface, then restores the gates. This is a short blocking call
// (~0.5–25 s).
func ListDevices() ([]DevInfo, error) {
	var cJSON *C.char
	n := C.cmio_list_devices(&cJSON)
	defer C.cmio_free_str(cJSON)
	raw := C.GoString(cJSON)
	var list []DevInfo
	if err := json.Unmarshal([]byte(raw), &list); err != nil {
		return nil, fmt.Errorf("cmio: parse device list: %w", err)
	}
	_ = n // count is len(list)
	return list, nil
}

// RecordDevice captures the screen of a specific muxed iOS device (identified
// by its uniqueID from ListDevices) to a QuickTime .mov file.
//
//   - uniqueID: device uniqueID from ListDevices
//   - output: destination path (overwritten if it already exists)
//   - duration: target media duration in seconds (actual recorded media
//     duration, not wall-clock; warm-up overhead is handled internally)
//   - mode: VideoOnly or AudioVideo
//
// RecordDevice is a blocking call. It returns nil on success, or an error.
func RecordDevice(uniqueID, output string, duration float64, mode Mode) error {
	cUID := C.CString(uniqueID)
	cPath := C.CString(output)

	audio := 0
	if mode == AudioVideo {
		audio = 1
	}

	var cErr *C.char
	code := C.cmio_record(cUID, cPath, C.double(duration), C.int(audio), &cErr)
	if code == 0 {
		return nil
	}

	msg := C.GoString(cErr)
	C.cmio_free_str(cErr)
	return &Error{Code: int(code), Message: msg}
}

// Record captures the first available muxed iOS device.  Convenience wrapper
// around RecordDevice.
func Record(output string, duration float64, mode Mode) error {
	return RecordDevice("", output, duration, mode)
}

// Error is the error type returned by Record / RecordDevice.
type Error struct {
	Code    int
	Message string
}

func (e *Error) Error() string {
	return fmt.Sprintf("cmio: [%d] %s", e.Code, e.Message)
}

// Is reports whether err is a cmio.Error with the given code.
func Is(err error, code int) bool {
	var e *Error
	if errors.As(err, &e) {
		return e.Code == code
	}
	return false
}
