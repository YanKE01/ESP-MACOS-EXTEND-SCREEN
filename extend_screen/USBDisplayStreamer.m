#import "USBDisplayStreamer.h"

#import <ImageIO/ImageIO.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

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

_Static_assert(sizeof(UDISPFrameHeader) == 16, "ESP udisp frame header must stay 16 bytes.");

static const uint8_t UDISPTypeJPG = 3;
static const NSUInteger USBWriteChunkSize = 16 * 1024;
static void *USBDisplayStreamerQueueKey = &USBDisplayStreamerQueueKey;

@interface USBDisplayStreamer ()
@property (nonatomic, readwrite) BOOL isConnected;
@property (nonatomic, readwrite) BOOL isStreaming;
@property (nonatomic, copy, readwrite, nullable) NSString *lastError;
@property (nonatomic, readwrite) uint64_t framesSent;
@property (nonatomic, readwrite) uint64_t bytesSent;
@property (nonatomic, readwrite) uint32_t droppedFrames;
@property (nonatomic, readwrite) uint16_t connectedVendorID;
@property (nonatomic, readwrite) uint16_t connectedProductID;
@property (nonatomic, copy, readwrite, nullable) NSString *displayDescriptor;
@property (nonatomic, readwrite) uint16_t displayWidth;
@property (nonatomic, readwrite) uint16_t displayHeight;
@property (nonatomic, readwrite) NSUInteger displayJPEGQuality;
@property (nonatomic, readwrite) NSUInteger displayMaxFPS;
@property (nonatomic, readwrite) NSUInteger displayFrameLimit;
@end

@implementation USBDisplayStreamer {
    IOUSBDeviceInterface **_deviceInterface;
    IOUSBInterfaceInterface **_interfaceInterface;
    UInt8 _outPipeRef;
    UInt16 _outMaxPacketSize;

    dispatch_queue_t _streamQueue;
    dispatch_source_t _streamTimer;
    BOOL _captureInFlight;

    CGDirectDisplayID _displayID;
    uint16_t _width;
    uint16_t _height;
    NSUInteger _jpegQuality;
    NSUInteger _fps;
    uint32_t _frameID;
    uint64_t _streamGeneration;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _streamQueue = dispatch_queue_create("linke.extend-screen.usb-stream", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_streamQueue, USBDisplayStreamerQueueKey, USBDisplayStreamerQueueKey, NULL);
        _jpegQuality = 6;
        _fps = 15;
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
}

- (NSString *)statusSummary {
    NSMutableString *summary =
        [NSMutableString stringWithFormat:@"%@%@", self.isConnected ? @"USB connected" : @"USB disconnected",
                                          self.isStreaming ? @", streaming" : @""];
    if (_outPipeRef != 0) {
        [summary appendFormat:@"\nOUT pipe: %u, max packet: %u", _outPipeRef, _outMaxPacketSize];
    }
    if (self.displayDescriptor.length > 0) {
        [summary appendFormat:@"\nDescriptor: %@", self.displayDescriptor];
    }
    if (self.displayWidth > 0 && self.displayHeight > 0) {
        [summary appendFormat:@"\nMode: %ux%u, JPEG: %lu, FPS: %lu, frame limit: %lu", self.displayWidth,
                              self.displayHeight, (unsigned long)self.displayJPEGQuality,
                              (unsigned long)self.displayMaxFPS, (unsigned long)self.displayFrameLimit];
    }
    [summary
        appendFormat:@"\nFrames: %llu, bytes: %llu, dropped: %u", self.framesSent, self.bytesSent, self.droppedFrames];
    if (self.lastError.length > 0) {
        [summary appendFormat:@"\nLast error: %@", self.lastError];
    }
    return summary;
}

- (BOOL)connectWithVendorID:(uint16_t)vendorID productID:(uint16_t)productID {
    if (self.isConnected) {
        return YES;
    }

    self.lastError = nil;
    io_iterator_t deviceIterator = IO_OBJECT_NULL;
    IOReturn kr = [self createDeviceIteratorForVendorID:vendorID productID:productID iterator:&deviceIterator];
    if (kr != kIOReturnSuccess) {
        self.lastError = [self message:@"USB device match failed" result:kr];
        return NO;
    }

    BOOL opened = NO;
    io_service_t usbDevice = IO_OBJECT_NULL;
    while ((usbDevice = IOIteratorNext(deviceIterator))) {
        opened = [self openDeviceService:usbDevice];
        IOObjectRelease(usbDevice);
        if (opened) {
            break;
        }
    }
    IOObjectRelease(deviceIterator);

    if (!opened) {
        if (self.lastError.length == 0) {
            self.lastError =
                [NSString stringWithFormat:@"No USB device found for VID 0x%04X PID 0x%04X.", vendorID, productID];
        }
        [self closeUSBInterfaces];
        return NO;
    }

    self.isConnected = YES;
    self.framesSent = 0;
    self.bytesSent = 0;
    self.droppedFrames = 0;
    self.connectedVendorID = vendorID;
    self.connectedProductID = productID;
    self.lastError = nil;
    return YES;
}

- (void)disconnect {
    [self stopStreaming];
    [self closeUSBInterfacesOnStreamQueue];
    self.isConnected = NO;
    self.connectedVendorID = 0;
    self.connectedProductID = 0;
    self.displayDescriptor = nil;
    self.displayWidth = 0;
    self.displayHeight = 0;
    self.displayJPEGQuality = 0;
    self.displayMaxFPS = 0;
    self.displayFrameLimit = 0;
}

- (BOOL)startStreamingDisplay:(CGDirectDisplayID)displayID
                        width:(uint16_t)width
                       height:(uint16_t)height
                  jpegQuality:(NSUInteger)jpegQuality
                          fps:(NSUInteger)fps {
    if (!self.isConnected || !_interfaceInterface || _outPipeRef == 0) {
        self.lastError = @"Connect to the ESP USB vendor interface before streaming.";
        return NO;
    }
    if (displayID == 0 || width == 0 || height == 0) {
        self.lastError = @"Create the virtual display before streaming.";
        return NO;
    }

    if (@available(macOS 10.15, *)) {
        if (!CGPreflightScreenCaptureAccess()) {
            CGRequestScreenCaptureAccess();
            if (!CGPreflightScreenCaptureAccess()) {
                self.lastError = @"Screen Recording permission is required before capture can start.";
                return NO;
            }
        }
    }

    [self stopStreaming];

    _displayID = displayID;
    _width = width;
    _height = height;
    _jpegQuality = MIN(MAX(jpegQuality, 1), 10);
    _fps = MIN(MAX(fps, 1), 60);
    _frameID = 0;
    _streamGeneration += 1;
    uint64_t generation = _streamGeneration;

    self.lastError = nil;
    self.isStreaming = YES;

    uint64_t intervalNsec = NSEC_PER_SEC / _fps;
    _streamTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _streamQueue);
    dispatch_source_set_timer(_streamTimer, dispatch_time(DISPATCH_TIME_NOW, 0), intervalNsec, intervalNsec / 4);

    __weak USBDisplayStreamer *weakSelf = self;
    dispatch_source_set_event_handler(_streamTimer, ^{
        [weakSelf captureAndSendFrameForGeneration:generation];
    });
    dispatch_source_set_cancel_handler(_streamTimer, ^{
                                       });
    dispatch_resume(_streamTimer);
    return YES;
}

- (void)stopStreaming {
    _streamGeneration += 1;
    if (_streamTimer) {
        dispatch_source_cancel(_streamTimer);
        _streamTimer = nil;
    }
    _captureInFlight = NO;
    self.isStreaming = NO;
}

- (IOReturn)createDeviceIteratorForVendorID:(uint16_t)vendorID
                                  productID:(uint16_t)productID
                                   iterator:(io_iterator_t *)iterator {
    CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchingDict) {
        return kIOReturnNoMemory;
    }

    uint32_t vendor = vendorID;
    uint32_t product = productID;
    CFNumberRef vendorRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vendor);
    CFNumberRef productRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &product);
    if (!vendorRef || !productRef) {
        if (vendorRef) {
            CFRelease(vendorRef);
        }
        if (productRef) {
            CFRelease(productRef);
        }
        CFRelease(matchingDict);
        return kIOReturnNoMemory;
    }

    CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), vendorRef);
    CFDictionarySetValue(matchingDict, CFSTR(kUSBProductID), productRef);
    CFRelease(vendorRef);
    CFRelease(productRef);

    return IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, iterator);
}

- (BOOL)openDeviceService:(io_service_t)usbDevice {
    IOCFPlugInInterface **plugInInterface = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
                                                    &plugInInterface, &score);
    if (kr != kIOReturnSuccess || !plugInInterface) {
        self.lastError = [self message:@"Create device plug-in failed" result:kr];
        return NO;
    }

    void *deviceInterface = NULL;
    HRESULT queryResult =
        (*plugInInterface)
            ->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), &deviceInterface);
    (*plugInInterface)->Release(plugInInterface);
    if (queryResult || !deviceInterface) {
        self.lastError =
            [NSString stringWithFormat:@"Query device interface failed: 0x%08x", (unsigned int)queryResult];
        return NO;
    }

    _deviceInterface = (IOUSBDeviceInterface **)deviceInterface;

    kr = (*_deviceInterface)->USBDeviceOpen(_deviceInterface);
    if (kr != kIOReturnSuccess) {
        self.lastError = [self message:@"USBDeviceOpen failed" result:kr];
        [self closeUSBInterfaces];
        return NO;
    }

    kr = [self configureDeviceIfNeeded];
    if (kr != kIOReturnSuccess) {
        self.lastError = [self message:@"Set USB configuration failed" result:kr];
        [self closeUSBInterfaces];
        return NO;
    }

    BOOL found = [self openVendorInterface];
    if (!found) {
        [self closeUSBInterfaces];
    }
    return found;
}

- (IOReturn)configureDeviceIfNeeded {
    UInt8 currentConfiguration = 0;
    IOReturn kr = (*_deviceInterface)->GetConfiguration(_deviceInterface, &currentConfiguration);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    if (currentConfiguration != 0) {
        return kIOReturnSuccess;
    }

    UInt8 configurationCount = 0;
    kr = (*_deviceInterface)->GetNumberOfConfigurations(_deviceInterface, &configurationCount);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    if (configurationCount == 0) {
        return kIOReturnNoDevice;
    }

    IOUSBConfigurationDescriptorPtr configDescriptor = NULL;
    kr = (*_deviceInterface)->GetConfigurationDescriptorPtr(_deviceInterface, 0, &configDescriptor);
    if (kr != kIOReturnSuccess || !configDescriptor) {
        return kr == kIOReturnSuccess ? kIOReturnNoDevice : kr;
    }

    return (*_deviceInterface)->SetConfiguration(_deviceInterface, configDescriptor->bConfigurationValue);
}

- (BOOL)openVendorInterface {
    IOUSBFindInterfaceRequest request;
    request.bInterfaceClass = kUSBVendorSpecificClass;
    request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    request.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t interfaceIterator = IO_OBJECT_NULL;
    IOReturn kr = (*_deviceInterface)->CreateInterfaceIterator(_deviceInterface, &request, &interfaceIterator);
    if (kr != kIOReturnSuccess) {
        self.lastError = [self message:@"CreateInterfaceIterator failed" result:kr];
        return NO;
    }

    BOOL found = NO;
    io_service_t usbInterface = IO_OBJECT_NULL;
    while ((usbInterface = IOIteratorNext(interfaceIterator))) {
        found = [self openInterfaceService:usbInterface];
        IOObjectRelease(usbInterface);
        if (found) {
            break;
        }
    }
    IOObjectRelease(interfaceIterator);

    if (!found && self.lastError.length == 0) {
        self.lastError = @"No vendor-specific USB interface with a bulk OUT endpoint was found.";
    }
    return found;
}

- (BOOL)openInterfaceService:(io_service_t)usbInterface {
    IOCFPlugInInterface **plugInInterface = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(usbInterface, kIOUSBInterfaceUserClientTypeID,
                                                    kIOCFPlugInInterfaceID, &plugInInterface, &score);
    if (kr != kIOReturnSuccess || !plugInInterface) {
        self.lastError = [self message:@"Create interface plug-in failed" result:kr];
        return NO;
    }

    void *interfaceInterface = NULL;
    HRESULT queryResult =
        (*plugInInterface)
            ->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), &interfaceInterface);
    (*plugInInterface)->Release(plugInInterface);
    if (queryResult || !interfaceInterface) {
        self.lastError = [NSString stringWithFormat:@"Query interface failed: 0x%08x", (unsigned int)queryResult];
        return NO;
    }

    IOUSBInterfaceInterface **candidate = (IOUSBInterfaceInterface **)interfaceInterface;
    kr = (*candidate)->USBInterfaceOpen(candidate);
    if (kr != kIOReturnSuccess) {
        self.lastError = [self message:@"USBInterfaceOpen failed" result:kr];
        (*candidate)->Release(candidate);
        return NO;
    }

    UInt8 outPipe = 0;
    UInt16 maxPacketSize = 0;
    if (![self findBulkOutPipeOnInterface:candidate pipeRef:&outPipe maxPacketSize:&maxPacketSize]) {
        (*candidate)->USBInterfaceClose(candidate);
        (*candidate)->Release(candidate);
        return NO;
    }

    _interfaceInterface = candidate;
    _outPipeRef = outPipe;
    _outMaxPacketSize = maxPacketSize;
    [self readAndParseVendorInterfaceDescriptorFrom:candidate];
    return YES;
}

- (void)readAndParseVendorInterfaceDescriptorFrom:(IOUSBInterfaceInterface **)interface {
    self.displayDescriptor = nil;
    self.displayWidth = 0;
    self.displayHeight = 0;
    self.displayJPEGQuality = 0;
    self.displayMaxFPS = 0;
    self.displayFrameLimit = 0;

    UInt8 stringIndex = 0;
    IOReturn kr = (*interface)->USBInterfaceGetStringIndex(interface, &stringIndex);
    if (kr != kIOReturnSuccess || stringIndex == 0) {
        return;
    }

    NSString *descriptor = [self stringDescriptorAtIndex:stringIndex languageID:0x0409];
    if (descriptor.length == 0) {
        descriptor = [self stringDescriptorAtIndex:stringIndex languageID:0x0000];
    }
    if (descriptor.length == 0) {
        return;
    }

    self.displayDescriptor = descriptor;
    [self parseDisplayDescriptor:descriptor];
}

- (nullable NSString *)stringDescriptorAtIndex:(UInt8)index languageID:(UInt16)languageID {
    if (!_deviceInterface || index == 0) {
        return nil;
    }

    UInt8 descriptorBytes[256] = {0};
    IOUSBDevRequest request;
    memset(&request, 0, sizeof(request));
    request.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
    request.bRequest = kUSBRqGetDescriptor;
    request.wValue = (UInt16)((kUSBStringDesc << 8) | index);
    request.wIndex = languageID;
    request.wLength = sizeof(descriptorBytes);
    request.pData = descriptorBytes;

    IOReturn kr = (*_deviceInterface)->DeviceRequest(_deviceInterface, &request);
    if (kr != kIOReturnSuccess || request.wLenDone < 2 || descriptorBytes[1] != kUSBStringDesc) {
        return nil;
    }

    NSUInteger byteLength = MIN((NSUInteger)descriptorBytes[0], (NSUInteger)request.wLenDone);
    if (byteLength < 2) {
        return nil;
    }

    NSUInteger characterCount = (byteLength - 2) / 2;
    unichar characters[127] = {0};
    characterCount = MIN(characterCount, (NSUInteger)127);
    for (NSUInteger index = 0; index < characterCount; index++) {
        NSUInteger byteIndex = 2 + index * 2;
        characters[index] = (unichar)(descriptorBytes[byteIndex] | (descriptorBytes[byteIndex + 1] << 8));
    }
    return [NSString stringWithCharacters:characters length:characterCount];
}

- (void)parseDisplayDescriptor:(NSString *)descriptor {
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"R(\\d+)x(\\d+)_Ejpg(\\d+)_Fps(\\d+)_Bl(\\d+)"
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:descriptor
                                                    options:0
                                                      range:NSMakeRange(0, descriptor.length)];
    if (!match || match.numberOfRanges < 6) {
        return;
    }

    self.displayWidth = (uint16_t)[[descriptor substringWithRange:[match rangeAtIndex:1]] integerValue];
    self.displayHeight = (uint16_t)[[descriptor substringWithRange:[match rangeAtIndex:2]] integerValue];
    self.displayJPEGQuality = (NSUInteger)[[descriptor substringWithRange:[match rangeAtIndex:3]] integerValue];
    self.displayMaxFPS = (NSUInteger)[[descriptor substringWithRange:[match rangeAtIndex:4]] integerValue];
    self.displayFrameLimit = (NSUInteger)[[descriptor substringWithRange:[match rangeAtIndex:5]] integerValue];
}

- (BOOL)findBulkOutPipeOnInterface:(IOUSBInterfaceInterface **)interface
                           pipeRef:(UInt8 *)pipeRef
                      maxPacketSize:(UInt16 *)maxPacketSize
{
    UInt8 endpointCount = 0;
    IOReturn kr = (*interface)->GetNumEndpoints(interface, &endpointCount);
    if (kr != kIOReturnSuccess) {
        self.lastError = [self message:@"GetNumEndpoints failed" result:kr];
        return NO;
    }

    for (UInt8 candidatePipe = 1; candidatePipe <= endpointCount; candidatePipe++) {
        UInt8 direction = 0;
        UInt8 number = 0;
        UInt8 transferType = 0;
        UInt16 packetSize = 0;
        UInt8 interval = 0;

        kr = (*interface)
                 ->GetPipeProperties(interface, candidatePipe, &direction, &number, &transferType, &packetSize,
                                     &interval);
        if (kr != kIOReturnSuccess) {
            continue;
        }

        if (direction == kUSBOut && transferType == kUSBBulk) {
            *pipeRef = candidatePipe;
            *maxPacketSize = packetSize;
            return YES;
        }
    }

    self.lastError = @"Vendor interface does not expose a bulk OUT endpoint.";
    return NO;
}

- (void)closeUSBInterfaces {
    if (_interfaceInterface) {
        (*_interfaceInterface)->USBInterfaceClose(_interfaceInterface);
        (*_interfaceInterface)->Release(_interfaceInterface);
        _interfaceInterface = NULL;
    }
    if (_deviceInterface) {
        (*_deviceInterface)->USBDeviceClose(_deviceInterface);
        (*_deviceInterface)->Release(_deviceInterface);
        _deviceInterface = NULL;
    }
    _outPipeRef = 0;
    _outMaxPacketSize = 0;
}

- (void)closeUSBInterfacesOnStreamQueue {
    if (dispatch_get_specific(USBDisplayStreamerQueueKey)) {
        [self closeUSBInterfaces];
        return;
    }

    dispatch_sync(_streamQueue, ^{
        [self closeUSBInterfaces];
    });
}

- (void)captureAndSendFrameForGeneration:(uint64_t)generation {
    if (!self.isStreaming || generation != _streamGeneration || !_interfaceInterface || _outPipeRef == 0) {
        return;
    }
    if (_captureInFlight) {
        return;
    }

    CGRect displayBounds = CGDisplayBounds(_displayID);
    if (CGRectIsEmpty(displayBounds)) {
        self.droppedFrames += 1;
        self.lastError = @"Virtual display bounds are empty.";
        return;
    }

    _captureInFlight = YES;
    __weak USBDisplayStreamer *weakSelf = self;
    [SCScreenshotManager captureImageInRect:displayBounds
                          completionHandler:^(CGImageRef _Nullable image, NSError *_Nullable error) {
                              USBDisplayStreamer *strongSelf = weakSelf;
                              if (!strongSelf) {
                                  return;
                              }

                              CGImageRef retainedImage = image ? CGImageRetain(image) : NULL;
                              NSString *errorMessage = error.localizedDescription;
                              dispatch_async(strongSelf->_streamQueue, ^{
                                  strongSelf->_captureInFlight = NO;
                                  if (!strongSelf.isStreaming || strongSelf->_streamGeneration != generation) {
                                      if (retainedImage) {
                                          CGImageRelease(retainedImage);
                                      }
                                      return;
                                  }
                                  if (!retainedImage) {
                                      strongSelf.droppedFrames += 1;
                                      strongSelf.lastError = errorMessage ?: @"ScreenCaptureKit returned no image.";
                                      return;
                                  }

                                  [strongSelf sendCapturedImage:retainedImage];
                                  CGImageRelease(retainedImage);
                              });
                          }];
}

- (void)sendCapturedImage:(CGImageRef)screenImage {
    @autoreleasepool {
        if (!screenImage) {
            self.droppedFrames += 1;
            self.lastError = @"ScreenCaptureKit returned no image.";
            return;
        }

        CGImageRef imageToEncode = screenImage;
        CGImageRef scaledImage = NULL;
        if (CGImageGetWidth(screenImage) != _width || CGImageGetHeight(screenImage) != _height) {
            scaledImage = [self copyImage:screenImage resizedToWidth:_width height:_height];
            if (!scaledImage) {
                self.droppedFrames += 1;
                self.lastError = @"Failed to scale captured display image.";
                return;
            }
            imageToEncode = scaledImage;
        }

        NSData *jpegData = [self jpegDataForImage:imageToEncode quality:_jpegQuality];
        if (scaledImage) {
            CGImageRelease(scaledImage);
        }

        if (!jpegData || jpegData.length == 0 || jpegData.length >= (1u << 22)) {
            self.droppedFrames += 1;
            self.lastError = [NSString
                stringWithFormat:@"JPEG frame is invalid or too large: %lu bytes.", (unsigned long)jpegData.length];
            return;
        }

        NSMutableData *packet = [NSMutableData dataWithLength:sizeof(UDISPFrameHeader)];
        UDISPFrameHeader *header = (UDISPFrameHeader *)packet.mutableBytes;
        header->crc16 = CFSwapInt16HostToLittle(0);
        header->type = UDISPTypeJPG;
        header->cmd = 0;
        header->x = CFSwapInt16HostToLittle(0);
        header->y = CFSwapInt16HostToLittle(0);
        header->width = CFSwapInt16HostToLittle(_width);
        header->height = CFSwapInt16HostToLittle(_height);
        uint32_t frameAndPayload = (((uint32_t)jpegData.length) << 10) | (_frameID & 0x3ff);
        header->frameAndPayload = CFSwapInt32HostToLittle(frameAndPayload);
        [packet appendData:jpegData];

        if ([self writeDataToBulkOutPipe:packet]) {
            _frameID = (_frameID + 1) & 0x3ff;
            self.framesSent += 1;
            self.bytesSent += packet.length;
            self.lastError = nil;
        } else {
            self.droppedFrames += 1;
        }
    }
}

- (CGImageRef)copyImage:(CGImageRef)image resizedToWidth:(size_t)width height:(size_t)height CF_RETURNS_RETAINED {
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) {
        return NULL;
    }

    CGContextRef context =
        CGBitmapContextCreate(NULL, width, height, 8, width * 4, colorSpace,
                              (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return NULL;
    }

    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGImageRef scaledImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return scaledImage;
}

- (nullable NSData *)jpegDataForImage:(CGImageRef)image quality:(NSUInteger)quality {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
    if (!destination) {
        return nil;
    }

    CGFloat normalizedQuality = (CGFloat)MIN(MAX(quality, 1), 10) / 10.0;
    NSDictionary *properties =
        @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @(normalizedQuality)};
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)properties);
    BOOL finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return finalized ? data : nil;
}

- (BOOL)writeDataToBulkOutPipe:(NSData *)data {
    const UInt8 *bytes = data.bytes;
    NSUInteger offset = 0;
    while (offset < data.length) {
        UInt32 chunkSize = (UInt32)MIN(USBWriteChunkSize, data.length - offset);
        IOReturn kr =
            (*_interfaceInterface)->WritePipe(_interfaceInterface, _outPipeRef, (void *)(bytes + offset), chunkSize);
        if (kr != kIOReturnSuccess) {
            self.lastError = [self message:@"WritePipe failed" result:kr];
            return NO;
        }
        offset += chunkSize;
    }
    return YES;
}

- (NSString *)message:(NSString *)message result:(IOReturn)result {
    return [NSString stringWithFormat:@"%@: 0x%08x", message, result];
}

@end
