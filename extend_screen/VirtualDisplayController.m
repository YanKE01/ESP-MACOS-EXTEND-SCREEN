#import "VirtualDisplayController.h"

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) uint32_t hiDPI;
@property (nonatomic) uint32_t rotation;
@property (nonatomic, copy) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) uint32_t serialNumber;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_queue_t dispatchQueue;
@property (nonatomic, copy) void (^terminationHandler)(void);
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

@interface VirtualDisplayController ()
@property (nonatomic, strong, nullable) CGVirtualDisplay *virtualDisplay;
@property (nonatomic, readwrite) CGDirectDisplayID displayID;
@property (nonatomic, copy, readwrite, nullable) NSString *lastError;
@end

@implementation VirtualDisplayController

- (BOOL)isRunning {
    return self.virtualDisplay != nil;
}

- (BOOL)startWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate hiDPI:(BOOL)hiDPI {
    if (self.virtualDisplay) {
        return YES;
    }

    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");

    if (!descriptorClass || !displayClass || !modeClass || !settingsClass) {
        self.lastError = @"CGVirtualDisplay private classes are unavailable on this macOS version.";
        return NO;
    }

    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.name = @"ESP USB Virtual Display";
    descriptor.vendorID = 0x303A;
    descriptor.productID = 0x2987;
    descriptor.serialNum = 1;
    descriptor.serialNumber = 1;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(160, 96);
    descriptor.queue = dispatch_get_main_queue();
    descriptor.dispatchQueue = dispatch_get_main_queue();
    descriptor.terminationHandler = ^{
        NSLog(@"ESP USB Virtual Display terminated by system");
    };

    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display) {
        self.lastError = @"Failed to create CGVirtualDisplay.";
        return NO;
    }

    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refreshRate];
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.modes = @[ mode ];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.rotation = 0;

    if (![display applySettings:settings]) {
        self.lastError = @"Created virtual display, but applySettings failed.";
        return NO;
    }

    self.virtualDisplay = display;
    self.displayID = display.displayID;
    self.lastError = nil;
    return YES;
}

- (void)stop {
    self.virtualDisplay = nil;
    self.displayID = 0;
}

- (NSString *)currentDisplaySummary {
    uint32_t count = 0;
    CGError countError = CGGetOnlineDisplayList(0, NULL, &count);
    if (countError != kCGErrorSuccess) {
        return [NSString stringWithFormat:@"CGGetOnlineDisplayList count failed: %d", countError];
    }

    NSMutableString *summary = [NSMutableString stringWithFormat:@"Online displays: %u", count];
    if (self.displayID != 0) {
        [summary appendFormat:@"\nCreated display ID: %u", self.displayID];
    }

    if (count == 0) {
        return summary;
    }

    CGDirectDisplayID *displays = calloc(count, sizeof(CGDirectDisplayID));
    if (!displays) {
        [summary appendString:@"\nFailed to allocate display list."];
        return summary;
    }

    uint32_t actualCount = 0;
    CGError listError = CGGetOnlineDisplayList(count, displays, &actualCount);
    if (listError != kCGErrorSuccess) {
        free(displays);
        return [NSString stringWithFormat:@"CGGetOnlineDisplayList failed: %d", listError];
    }

    for (uint32_t index = 0; index < actualCount; index++) {
        CGDirectDisplayID displayID = displays[index];
        CGRect bounds = CGDisplayBounds(displayID);
        [summary appendFormat:@"\n%u: %.0fx%.0f at %.0f,%.0f%@", displayID, bounds.size.width, bounds.size.height,
                              bounds.origin.x, bounds.origin.y, displayID == self.displayID ? @" (created)" : @""];
    }

    free(displays);
    return summary;
}

@end
