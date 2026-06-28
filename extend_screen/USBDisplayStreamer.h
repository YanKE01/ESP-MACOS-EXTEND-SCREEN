#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface USBDisplayStreamer : NSObject

@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) BOOL isStreaming;
@property (nonatomic, copy, readonly, nullable) NSString *lastError;
@property (nonatomic, copy, readonly) NSString *statusSummary;
@property (nonatomic, readonly) uint64_t framesSent;
@property (nonatomic, readonly) uint64_t bytesSent;
@property (nonatomic, readonly) uint32_t droppedFrames;
@property (nonatomic, readonly) uint16_t connectedVendorID;
@property (nonatomic, readonly) uint16_t connectedProductID;
@property (nonatomic, copy, readonly, nullable) NSString *displayDescriptor;
@property (nonatomic, readonly) uint16_t displayWidth;
@property (nonatomic, readonly) uint16_t displayHeight;
@property (nonatomic, readonly) NSUInteger displayJPEGQuality;
@property (nonatomic, readonly) NSUInteger displayMaxFPS;
@property (nonatomic, readonly) NSUInteger displayFrameLimit;

- (BOOL)connectWithVendorID:(uint16_t)vendorID productID:(uint16_t)productID;

- (void)disconnect;

- (BOOL)startStreamingDisplay:(CGDirectDisplayID)displayID
                        width:(uint16_t)width
                       height:(uint16_t)height
                  jpegQuality:(NSUInteger)jpegQuality
                          fps:(NSUInteger)fps;

- (void)stopStreaming;

@end

NS_ASSUME_NONNULL_END
