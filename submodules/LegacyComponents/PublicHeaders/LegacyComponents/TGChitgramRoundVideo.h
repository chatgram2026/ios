#import <Foundation/Foundation.h>

/// Chitgram: "send as round video" in the gallery (Android PhotoViewer's round-video toggle). The gallery's button sets
/// it; the send path turns the video into a round video note and clears it. Main thread.
@interface TGChitgramRoundVideo : NSObject

+ (bool)requested;
+ (void)setRequested:(bool)requested;

@end
