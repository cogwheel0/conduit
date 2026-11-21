#import "AudioSource.h"
#import "UriAudioSource.h"
#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface ClippingAudioSource : IndexedAudioSource

@property (readonly, nonatomic) UriAudioSource* audioSource;

- (instancetype)initWithId:(NSString *)sid audioSource:(UriAudioSource *)audioSource start:(NSNumber *)start end:(NSNumber *)end;

@end
