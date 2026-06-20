// Command cmio-capture records the iOS device screen through the
// CoreMediaIO bridge on macOS.
//
// Usage:
//
//	cmio-capture [-d duration] [-o output.mov] [-av] [-device name|index]
//	cmio-capture -list
//
// Flags:
//
//	-d       Recording duration in seconds (default 10)
//	-o       Output .mov path (default /tmp/cmio-capture.mov)
//	-av      Include audio track (default: video-only)
//	-device  Device name substring or 0-based index (default: first device)
//	-list    List available muxed iOS devices and exit
//
// Multi-device: each paired iPhone appears as a separate device with a unique
// ID.  Use -list to enumerate them and -device to select one.  With only one
// iPhone connected, -device is unnecessary.
//
// The device must be paired, connected via USB, and have camera access
// authorized for the terminal in System Settings → Privacy & Security → Camera.
//
// Examples:
//
//	cmio-capture -list
//	cmio-capture -d 15 -o ~/Desktop/screen.mov
//	cmio-capture -d 30 -av -device "iPhone 14" -o capture.mov
package main

import (
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"

	"devicekit/tools/cmio-capture/cmio"
)

func main() {
	duration := flag.Float64("d", 10, "recording duration in seconds")
	output := flag.String("o", "/tmp/cmio-capture.mov", "output .mov path")
	withAudio := flag.Bool("av", false, "include audio track (default: video-only)")
	device := flag.String("device", "", "device name substring or 0-based index")
	listFlag := flag.Bool("list", false, "list muxed iOS devices and exit")
	flag.Parse()

	if *listFlag {
		listAndExit()
		return
	}

	uid, err := resolveDevice(*device)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmio-capture: %v\n", err)
		os.Exit(1)
	}

	mode := cmio.VideoOnly
	if *withAudio {
		mode = cmio.AudioVideo
	}

	if err := cmio.RecordDevice(uid, *output, *duration, mode); err != nil {
		fmt.Fprintf(os.Stderr, "cmio-capture: %v\n", err)
		switch {
		case cmio.Is(err, 2):
			fmt.Fprintln(os.Stderr, "  Hint: Is the iPhone paired and connected via USB?")
		}
		os.Exit(1)
	}

	info, _ := os.Stat(*output)
	fmt.Printf("wrote %s (%d bytes)\n", *output, info.Size())
}

func listAndExit() {
	devs, err := cmio.ListDevices()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmio-capture: list: %v\n", err)
		os.Exit(1)
	}
	if len(devs) == 0 {
		fmt.Println("no muxed iOS devices found")
		return
	}
	fmt.Printf("%d device(s) found:\n", len(devs))
	for i, d := range devs {
		fmt.Printf("  [%d] %-30s  model=%-10s  uid=%s\n", i, d.Name, d.ModelID, d.UniqueID)
	}
}

func resolveDevice(spec string) (string, error) {
	if spec == "" {
		return "", nil // first device
	}
	// Try integer index.
	if idx, err := strconv.Atoi(spec); err == nil {
		devs, listErr := cmio.ListDevices()
		if listErr != nil {
			return "", listErr
		}
		if idx < 0 || idx >= len(devs) {
			return "", fmt.Errorf("device index %d out of range (0–%d)", idx, len(devs)-1)
		}
		return devs[idx].UniqueID, nil
	}
	// Match by name substring.
	devs, err := cmio.ListDevices()
	if err != nil {
		return "", err
	}
	lower := strings.ToLower(spec)
	for _, d := range devs {
		if strings.Contains(strings.ToLower(d.Name), lower) {
			return d.UniqueID, nil
		}
	}
	return "", fmt.Errorf("no device matching %q", spec)
}
