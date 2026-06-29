# ESP USB Virtual Display for macOS

这是一个 macOS 端的 ESP USB 扩展屏原型应用。它的目标是：运行 app 之后自动检测指定 VID/PID 的 ESP USB 设备，读取设备描述符里的屏幕参数，在 macOS 上创建一个虚拟扩展屏，然后把这个虚拟屏的画面编码成 JPEG，通过 USB vendor bulk OUT 端点发送给设备。

协议参考的是：

```text
/Users/linke/project/esp-iot-solution/examples/usb/device/usb_extend_screen
```

当前实现已经在运行 `usb_extend_screen` firmware 的 ESP USB 设备上跑通基础显示链路。

## 当前行为

- app 启动后默认打开 `Auto` 模式。
- 每 1 秒扫描一次 ESP USB 设备。
- 自动扫描的 VID/PID：
  - VID: `0x303A`
  - PID: `0x2987`
  - PID: `0x2986`
- 连接成功后会打开 vendor-specific USB interface。
- 自动查找 bulk OUT endpoint。
- 读取 vendor interface 的 string descriptor。
- 从 descriptor 中解析分辨率、JPEG 质量、最大 FPS 和 frame limit。
- 按 descriptor 创建 macOS 虚拟屏。
- 使用 ScreenCaptureKit 捕获虚拟屏画面。
- 将画面缩放到设备分辨率，编码成 JPEG。
- 按 ESP `usb_extend_screen` 的 packet header 格式发送 `JPG` 帧。

正常使用时不需要手动设置分辨率。界面里的 `Width` / `Height` / `FPS` / `JPEG` 是 Debug 和手动测试用的；Auto 模式下会被设备 descriptor 覆盖。

## 技术路线

整体路线是“设备描述符驱动的 macOS 虚拟扩展屏”。ESP 固件负责声明自己是什么屏，macOS app 负责创建一个真实可用的系统扩展屏，再把这个扩展屏的画面编码后通过 USB vendor endpoint 发给 ESP。

```text
ESP USB device
  -> TinyUSB vendor interface
  -> interface string: R<width>x<height>_Ejpg<quality>_Fps<fps>_Bl<limit>
  -> macOS app parses mode
  -> CGVirtualDisplay creates an extended display
  -> ScreenCaptureKit captures that display
  -> cursor overlay is drawn in software
  -> ImageIO encodes JPEG
  -> USB bulk OUT sends header + JPEG payload
  -> ESP app_vendor receives frames
  -> ESP LCD task draws the JPEG frame
```

关键设计点：

- **分辨率由设备决定**：app 不要求用户手动选择分辨率，而是读取 vendor interface string descriptor。例如设备可以暴露 `<target>udisp0_R800x480_Ejpg6_Fps60_Bl300000` 这类字符串，macOS 端只关心其中的 `R...` 模式段，用它解析分辨率、JPEG 质量、FPS 和单帧大小上限。
- **macOS 侧创建真正的扩展屏**：通过 `CGVirtualDisplay` 创建 `ESP USB Virtual Display`，系统设置里能看到它，也可以像普通扩展屏一样排列位置、拖窗口、移动鼠标。
- **画面采集和传输解耦**：虚拟屏负责接收系统渲染，USB streamer 只负责采集这块屏幕、编码、发包。这样 USB 协议不需要理解窗口、图层或 AppKit 细节。
- **JPEG 优先**：当前协议只发送 ESP 示例工程已经支持的 `UDISP_TYPE_JPG`，避免 raw RGB 带宽过大，也方便直接复用设备端 `app_vendor.c` 的接收逻辑。
- **cursor 软件叠加**：`SCScreenshotManager captureImageInRect` 抓到的是屏幕内容，不一定包含鼠标指针；macOS 端会根据 `CGEventGetLocation` 判断鼠标是否在虚拟屏上，然后把 `NSCursor` 图像按 hotspot 画进 JPEG 前的帧里。
- **Auto 模式做最短闭环**：app 每秒扫描 VID/PID，连接后读取 descriptor，自动创建虚拟屏并开始 stream。Debug 区只作为手动排查入口。
- **权限和签名是 macOS 约束**：屏幕采集需要 Screen Recording 权限。ad-hoc 签名的 Debug app 可能因为每次 build 后 hash 变化而反复要求授权；稳定测试时应尽量复用同一个 build，或者配置稳定签名。

## macOS 端实现

主要文件：

```text
extend_screen/ContentView.swift
extend_screen/VirtualDisplayController.h
extend_screen/VirtualDisplayController.m
extend_screen/USBDisplayStreamer.h
extend_screen/USBDisplayStreamer.m
extend_screen/VirtualDisplayBridge.h
```

职责划分：

- `ContentView.swift`
  - SwiftUI 界面
  - 自动扫描状态机
  - Debug 控制
  - runtime 状态同步
- `VirtualDisplayController.m`
  - 使用 `CGVirtualDisplay` 创建/销毁 macOS 虚拟显示器
  - 当前使用的是 macOS private API，不适合 App Store 发布
- `USBDisplayStreamer.m`
  - 使用 IOKit 匹配 USB 设备
  - 打开 vendor interface
  - 查找 bulk OUT pipe
  - 从 IORegistry/USB string descriptor 读取并解析 display descriptor
  - 使用 ScreenCaptureKit 截屏
  - 将鼠标指针叠加到虚拟屏帧上
  - 使用 ImageIO 编码 JPEG
  - 通过 USB bulk OUT 写入 ESP 设备

## 依赖和权限

需要：

- Xcode
- macOS 15.2 或更新版本
- Screen Recording 权限
- 一个运行 ESP `usb_extend_screen` firmware 的 USB 设备

说明：

- 当前采集路径使用 `SCScreenshotManager captureImageInRect:completionHandler:`，本机 SDK 标注为 macOS 15.2 起可用。
- app sandbox 已关闭，因为当前实现需要 IOKit USB 访问和 private virtual display API。
- 第一次开始采集时，macOS 可能会弹出屏幕录制权限请求。授权后通常需要重新运行 app。

## 构建

在工程目录执行：

```bash
xcodebuild -project extend_screen.xcodeproj -scheme extend_screen -configuration Debug -derivedDataPath build build
```

也可以直接用 Xcode 打开：

```text
extend_screen.xcodeproj
```

当前验证过的构建命令：

```bash
xcodebuild -quiet -project extend_screen.xcodeproj -scheme extend_screen -configuration Debug -derivedDataPath build build
```

## 格式化

仓库里有一份本地 `pre-commit` 配置，用来做代码格式化：

- Swift 文件：`xcrun swift-format format --in-place --configuration .swift-format`
- Objective-C/C 文件：`xcrun clang-format -i`

安装并启用：

```bash
brew install pre-commit
pre-commit install
```

手动格式化全部文件：

```bash
pre-commit run --all-files
```

## 使用方式

1. 构建并运行 app。
2. 保持 `Auto` 开启。
3. 插入 ESP USB 扩展屏设备。
4. app 检测到设备后，会自动读取 descriptor。
5. app 自动创建名为 `ESP USB Virtual Display` 的 macOS 虚拟屏。
6. 在 macOS `System Settings` -> `Displays` 里可以看到这个扩展屏，并调整排列位置。
7. app 自动开始把虚拟屏画面发送到 USB 设备。
8. 点击 `Stop Extend` 可以停止 USB stream 并销毁虚拟屏。

## Debug 控制

Debug 区是手动测试和排查用的。

| 控件 | 作用 |
| --- | --- |
| `Auto` | 开启后自动扫描设备、创建虚拟屏、启动 stream |
| `Scan Now` | 立即执行一次自动扫描 |
| `Stop Extend` | 停止 stream，断开自动流程，并销毁虚拟屏 |
| `Width` / `Height` | 手动创建虚拟屏和 stream 时使用的分辨率 |
| `Refresh` | 虚拟屏刷新率 |
| `VID` / `PID` | 手动连接 USB 设备时使用 |
| `JPEG` | JPEG 编码质量，范围按 `1...10` 处理 |
| `FPS` | stream 目标 FPS，范围按 `1...60` 处理 |
| `HiDPI` | 手动创建虚拟屏时是否启用 HiDPI |
| `Start Display` / `Stop Display` | 手动创建或销毁虚拟屏 |
| `Connect USB` / `Disconnect` | 手动打开或关闭 USB vendor interface |
| `Start Stream` / `Stop Stream` | 手动启动或停止 JPEG stream |
| `Refresh Displays` | 刷新当前 macOS 在线显示器列表 |

## 设备 descriptor

macOS 端会读取 vendor interface 的 string descriptor，并匹配下面这段格式：

```text
R<width>x<height>_Ejpg<quality>_Fps<max_fps>_Bl<frame_limit>
```

ESP 示例工程当前构造 vendor interface string 的代码在：

```text
main/tusb/usb_descriptors.c
```

示例固件会生成类似这样的字符串：

```text
esp32s3udisp0_R480x800_Ejpg6_Fps15_Bl65536
```

macOS 端只关心其中的这段：

```text
R480x800_Ejpg6_Fps15_Bl65536
```

当前 app 按 `R<width>x<height>` 解释：

- `width = 480`
- `height = 800`
- `JPEG quality = 6`
- `max FPS = 15`
- `frame limit = 65536`

注意：ESP 示例工程里 Kconfig 名字可能和 LCD 横纵方向看起来相反。macOS 端不读取 Kconfig，只读取最终 USB descriptor 字符串；ESP firmware 最终也会用自己的 `EXAMPLE_LCD_H_RES` / `EXAMPLE_LCD_V_RES` 校验收到的 packet。所以如果设备端丢帧，优先检查 descriptor 里的 `R...x...` 是否和 firmware 端期待的 `width` / `height` 一致。

## USB frame 格式

当前只发送 JPEG 帧，也就是 ESP 示例里的：

```c
#define UDISP_TYPE_JPG 3
```

macOS 端发送的 header 是 16 bytes，小端序：

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

字段含义：

| 字段 | 当前值 |
| --- | --- |
| `crc16` | 当前填 `0` |
| `type` | `3`, JPEG |
| `cmd` | `0` |
| `x` | `0` |
| `y` | `0` |
| `width` | descriptor 或 Debug 里的 width |
| `height` | descriptor 或 Debug 里的 height |
| `frameAndPayload` | `(jpegLength << 10) \| (frameID & 0x3ff)` |

ESP 端结构里最后 32 bits 是 bitfield：

```c
uint32_t frame_id: 10;
uint32_t payload_total: 22;
```

macOS 端会把 header 和 JPEG payload 拼成一个 packet，再按 16 KB chunk 写入 bulk OUT pipe。

## 打包测试 DMG

如果只是本地测试或上传到 GitHub Release，且没有 Apple Developer 账号，可以运行：

```bash
scripts/package_unsigned_dmg.sh
```

脚本会构建 Release app、做 ad-hoc 签名，并生成：

```text
dist/ESP_USB_Display_unsigned.dmg
```

这个 DMG 没有 notarize。用户第一次运行时仍然需要绕过“无法验证开发者”的 Gatekeeper 提示，并手动授予 Screen Recording 权限。

## 已知限制

- 当前使用 `CGVirtualDisplay` private API，macOS 版本变化可能导致不可用。
- 当前采集路径是 screenshot-style capture，不是低延迟视频流；高 FPS 场景后面可能需要改成 `SCStream`。
- 当前只发送 JPEG，不支持 RGB565/RGB888/YUV420。
- 当前显示链路不处理 touch/HID/audio；固件可以同时枚举 HID touch/UAC audio，但 macOS app 目前只使用 vendor display interface。
- 当前没有严格按 `Bl` 提前限制 JPEG payload 大小；如果 JPEG 大于 ESP firmware 的 `CONFIG_USB_EXTEND_SCREEN_FRAME_LIMIT_B`，ESP 端会丢帧。可以先降低分辨率或 JPEG 质量排查。
- 当前 CRC 填 `0`，未做校验。
- 当前热插拔是 1 秒轮询，不是 IOKit notification。

## 排查

如果 macOS 设置里出现了虚拟屏，但设备没有显示：

- 检查 app 里 USB 状态是否显示 `USB connected, streaming`。
- 检查 descriptor 是否被正确解析。
- 检查 packet 的 `width` / `height` 是否和 ESP firmware 端期待一致。
- 降低 `JPEG` 或分辨率，避免 payload 超过 `Bl`。
- 确认 app 已获得 Screen Recording 权限。
- 看 ESP 串口日志是否有：
  - `Drop frame with unexpected area`
  - `Drop frame: payload_total`
  - `payload overflow`

如果用户第一次点了拒绝，或者后来在系统设置里取消了 Screen Recording 权限，可以清掉这个 app 的 TCC 记录：

```bash
tccutil reset ScreenCapture linke.extend-screen
```

然后完全退出 app，重新打开，再触发一次采集或 Auto 模式。macOS 只会在 app 再次调用屏幕采集 API 时重新弹授权窗口。

如果 Debug 里手动点 `Start Display`：

- 这只会创建 macOS 虚拟屏。
- 不会自动连接 USB，也不会自动开始 stream。
- 再点一次会变成 `Stop Display` 并销毁虚拟屏。
