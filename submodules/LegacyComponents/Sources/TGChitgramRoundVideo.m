#import <LegacyComponents/TGChitgramRoundVideo.h>

static bool TGChitgramRoundVideoRequested = false;

@implementation TGChitgramRoundVideo

+ (bool)requested
{
    return TGChitgramRoundVideoRequested;
}

+ (void)setRequested:(bool)requested
{
    TGChitgramRoundVideoRequested = requested;
}

@end
