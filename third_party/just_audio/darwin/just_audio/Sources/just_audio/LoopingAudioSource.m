#import "./include/just_audio/AudioSource.h"
#import "./include/just_audio/LoopingAudioSource.h"
#import <AVFoundation/AVFoundation.h>

@implementation LoopingAudioSource {
    // An array of duplicates
    NSArray<AudioSource *> *_audioSources; // <AudioSource *>
}

- (instancetype)initWithId:(NSString *)sid audioSources:(NSArray<AudioSource *> *)audioSources {
    self = [super initWithId:sid];
    NSAssert(self, @"super init cannot be nil");
    _audioSources = audioSources;
    return self;
}

- (BOOL)lazyLoading {
    return [_audioSources count] > 0 ? _audioSources[0].lazyLoading : NO;
}

- (void)setLazyLoading:(BOOL)lazyLoading {
    for (int i = 0; i < [_audioSources count]; i++) {
        _audioSources[i].lazyLoading = lazyLoading;
    }
}

- (int)buildSequence:(NSMutableArray *)sequence treeIndex:(int)treeIndex {
    for (int i = 0; i < [_audioSources count]; i++) {
        treeIndex = [_audioSources[i] buildSequence:sequence treeIndex:treeIndex];
    }
    return treeIndex;
}

- (void)findById:(NSString *)sourceId matches:(NSMutableArray<AudioSource *> *)matches {
    [super findById:sourceId matches:matches];
    for (int i = 0; i < [_audioSources count]; i++) {
        [_audioSources[i] findById:sourceId matches:matches];
    }
}

- (NSArray<NSNumber *> *)getShuffleIndices {
    NSMutableArray<NSNumber *> *order = [NSMutableArray new];
    int offset = (int)[order count];
    for (int i = 0; i < [_audioSources count]; i++) {
        AudioSource *audioSource = _audioSources[i];
        NSArray<NSNumber *> *childShuffleOrder = [audioSource getShuffleIndices];
        for (int j = 0; j < [childShuffleOrder count]; j++) {
            [order addObject:@([childShuffleOrder[j] integerValue] + offset)];
        }
        offset += [childShuffleOrder count];
    }
    return order;
}

- (void)decodeShuffleOrder:(NSDictionary *)dict {
    NSDictionary *dictChild = (NSDictionary *)dict[@"child"];
    for (int i = 0; i < [_audioSources count]; i++) {
        AudioSource *child = _audioSources[i];
        [child decodeShuffleOrder:dictChild];
    }
}

@end
