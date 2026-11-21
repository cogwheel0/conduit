#import "AudioSource.h"
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface ConcatenatingAudioSource : AudioSource

@property (readonly, nonatomic) int count;

- (instancetype)initWithId:(NSString *)sid audioSources:(NSMutableArray<AudioSource *> *)audioSources shuffleOrder:(NSArray<NSNumber *> *)shuffleOrder lazyLoading:(NSNumber *)lazyLoading;
- (void)insertSource:(AudioSource *)audioSource atIndex:(int)index;
- (void)removeSourcesFromIndex:(int)start toIndex:(int)end;
- (void)moveSourceFromIndex:(int)currentIndex toIndex:(int)newIndex;
- (void)setShuffleOrder:(NSArray<NSNumber *> *)shuffleOrder;

@end
