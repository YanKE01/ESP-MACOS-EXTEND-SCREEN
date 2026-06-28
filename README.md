# ESP USB Virtual Display for macOS

Chinese version: [README_ZH.md](README_ZH.md)

This is a prototype macOS host app for an ESP USB extended display. After the app starts, it can automatically detect a matching ESP USB device, read the display parameters from the device's USB descriptor, create a macOS virtual display, capture that display, encode frames as JPEG, and send them to the device through a USB vendor bulk OUT endpoint.

The protocol follows the ESP example:

```text
/Users/linke/project/esp-iot-solution/examples/usb/device/usb_extend_screen
```

The current implementation has not been fully tested with real hardware yet. Without the device, only virtual display creation, UI state, and builds have been verified.

## Behavior

- The app starts with `Auto` mode enabled.
- It scans for an ESP USB device every 1 second.
- Default VID/PID scan list:
  - VID: `0x303A`
  - PID: `0x2987`
  - PID: `0x2986`
- After connection, it opens the vendor-specific USB interface.
- It finds the bulk OUT endpoint automatically.
- It reads the vendor interface string descriptor.
- It parses resolution, JPEG quality, max FPS, and frame limit from the descriptor.
- It creates a macOS virtual display from the parsed mode.
- It captures the virtual display with ScreenCaptureKit.
- It scales the captured image to the device resolution and encodes it as JPEG.
- It sends `JPG` frames using the ESP `usb_extend_screen` packet format.

In the normal path, users do not need to choose a resolution manually. `Width`, `Height`, `FPS`, and `JPEG` in the UI are for Debug and manual testing. Auto mode overwrites them with values parsed from the USB descriptor.

## Implementation

Main files:

```text
extend_screen/ContentView.swift
extend_screen/VirtualDisplayController.h
extend_screen/VirtualDisplayController.m
extend_screen/USBDisplayStreamer.h
extend_screen/USBDisplayStreamer.m
extend_screen/VirtualDisplayBridge.h
```

Responsibilities:

- `ContentView.swift`
  - SwiftUI UI
  - Auto scan state machine
  - Debug controls
  - Runtime state sync
- `VirtualDisplayController.m`
  - Creates and destroys the macOS virtual display with `CGVirtualDisplay`
  - Uses private macOS APIs, so this is not App Store friendly
- `USBDisplayStreamer.m`
  - Matches USB devices with IOKit
  - Opens the vendor interface
  - Finds the bulk OUT pipe
  - Reads and parses the interface string descriptor
  - Captures the virtual display with ScreenCaptureKit
  - Encodes JPEG with ImageIO
  - Writes packets to the ESP device over USB bulk OUT

## Requirements

- Xcode
- macOS 15.2 or newer
- Screen Recording permission
- An ESP USB device running the `usb_extend_screen` firmware

Notes:

- The current capture path uses `SCScreenshotManager captureImageInRect:completionHandler:`, which is available from macOS 15.2 in the local SDK.
- App sandboxing is disabled because the current implementation needs IOKit USB access and private virtual display APIs.
- macOS may ask for Screen Recording permission the first time capture starts. After granting it, restart the app if capture still fails.

## Build

From the project directory:

```bash
xcodebuild -project extend_screen.xcodeproj -scheme extend_screen -configuration Debug -derivedDataPath build build
```

Or open the project in Xcode:

```text
extend_screen.xcodeproj
```

Verified build command:

```bash
xcodebuild -quiet -project extend_screen.xcodeproj -scheme extend_screen -configuration Debug -derivedDataPath build build
```

## Formatting

This repository has a local `pre-commit` configuration for code formatting:

- Swift files: `xcrun swift-format format --in-place --configuration .swift-format`
- Objective-C/C files: `xcrun clang-format -i`

Install and enable it:

```bash
brew install pre-commit
pre-commit install
```

Run it manually on all files:

```bash
pre-commit run --all-files
```

## Usage

1. Build and run the app.
2. Keep `Auto` enabled.
3. Plug in the ESP USB display device.
4. The app reads the descriptor after detecting the device.
5. The app creates a macOS virtual display named `ESP USB Virtual Display`.
6. Open macOS `System Settings` -> `Displays` to arrange the extended display.
7. The app starts sending the virtual display image to the USB device.
8. Click `Stop Extend` to stop streaming and destroy the virtual display.

## Debug Controls

The Debug section is for manual testing and troubleshooting.

| Control | Purpose |
| --- | --- |
| `Auto` | Automatically scan, create the virtual display, and start streaming |
| `Scan Now` | Run one auto scan immediately |
| `Stop Extend` | Stop the stream, leave auto flow, and destroy the virtual display |
| `Width` / `Height` | Resolution used for manual display creation and stream start |
| `Refresh` | Virtual display refresh rate |
| `VID` / `PID` | USB IDs used by manual connection |
| `JPEG` | JPEG quality, clamped to `1...10` |
| `FPS` | Target stream FPS, clamped to `1...60` |
| `HiDPI` | Enables HiDPI for manually created virtual displays |
| `Start Display` / `Stop Display` | Manually create or destroy the virtual display |
| `Connect USB` / `Disconnect` | Manually open or close the USB vendor interface |
| `Start Stream` / `Stop Stream` | Manually start or stop the JPEG stream |
| `Refresh Displays` | Refresh the current macOS display list |

## Device Descriptor

The macOS app reads the vendor interface string descriptor and matches this format:

```text
R<width>x<height>_Ejpg<quality>_Fps<max_fps>_Bl<frame_limit>
```

The ESP example builds this string in:

```text
main/tusb/usb_descriptors.c
```

Example descriptor:

```text
esp32s3udisp0_R480x800_Ejpg6_Fps15_Bl65536
```

The macOS app only uses this part:

```text
R480x800_Ejpg6_Fps15_Bl65536
```

It interprets `R<width>x<height>` as:

- `width = 480`
- `height = 800`
- `JPEG quality = 6`
- `max FPS = 15`
- `frame limit = 65536`

The ESP example's Kconfig names may look swapped relative to the LCD orientation. The macOS app only reads the final USB descriptor string. The ESP firmware also checks incoming packets against its own `EXAMPLE_LCD_H_RES` and `EXAMPLE_LCD_V_RES`, so if the device drops frames, first verify that the descriptor's `R...x...` matches the width and height expected by the firmware.

## USB Frame Format

The app currently sends only JPEG frames:

```c
#define UDISP_TYPE_JPG 3
```

The macOS header is 16 bytes, little-endian:

```c
typedef struct __attribute__((packed)) {
    uint16_t crc16;
    uint8_t type;
    uint8_t cmd;
    uint16_t x;
    uint16_t y;
    uint16_t width;
    uint16_t height;
    uint32_t frameAndPayload;
} UDISPFrameHeader;
```

Fields:

| Field | Current value |
| --- | --- |
| `crc16` | `0` |
| `type` | `3`, JPEG |
| `cmd` | `0` |
| `x` | `0` |
| `y` | `0` |
| `width` | Width from descriptor or Debug |
| `height` | Height from descriptor or Debug |
| `frameAndPayload` | `(jpegLength << 10) \| (frameID & 0x3ff)` |

The ESP side treats the last 32 bits as:

```c
uint32_t frame_id: 10;
uint32_t payload_total: 22;
```

The macOS app concatenates the header and JPEG payload, then writes the packet to the bulk OUT pipe in 16 KB chunks.

## Known Limits

- Real ESP USB display hardware has not been tested yet.
- `CGVirtualDisplay` is a private macOS API and may break across macOS releases.
- The current capture path is screenshot-style capture, not a low-latency stream. Higher FPS use cases may need `SCStream`.
- Only JPEG frames are sent. RGB565, RGB888, and YUV420 are not implemented.
- Touch, HID, and audio are not implemented.
- The app does not proactively enforce the `Bl` frame limit before sending. If the JPEG payload exceeds `CONFIG_USB_EXTEND_SCREEN_FRAME_LIMIT_B`, the ESP firmware will drop the frame. Lower resolution or JPEG quality first when debugging this.
- CRC is currently sent as `0`.
- Hotplug handling uses 1-second polling instead of IOKit notifications.

## Troubleshooting

If the macOS virtual display appears but the device does not show an image:

- Check whether the app status says `USB connected, streaming`.
- Check that the descriptor was parsed correctly.
- Check that packet `width` and `height` match the ESP firmware expectation.
- Lower `JPEG` or resolution to keep the payload below `Bl`.
- Confirm that the app has Screen Recording permission.
- Check ESP serial logs for:
  - `Drop frame with unexpected area`
  - `Drop frame: payload_total`
  - `payload overflow`

If you manually click `Start Display` in Debug:

- It only creates the macOS virtual display.
- It does not automatically connect USB or start streaming.
- Clicking it again changes it to `Stop Display` and destroys the virtual display.
