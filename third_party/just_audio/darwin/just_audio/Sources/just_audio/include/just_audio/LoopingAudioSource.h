#import "AudioSource.h"
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface LoopingAudioSource : AudioSource

- (instancetype)initWithId:(NSString *)sid audioSources:(NSArray<AudioSource *> *)audioSources;

@end
