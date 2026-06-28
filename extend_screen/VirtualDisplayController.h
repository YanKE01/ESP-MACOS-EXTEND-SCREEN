#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VirtualDisplayController : NSObject

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, copy, readonly, nullable) NSString *lastError;

- (BOOL)startWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate hiDPI:(BOOL)hiDPI;

- (void)stop;

- (NSString *)currentDisplaySummary;

@end

NS_ASSUME_NONNULL_END
