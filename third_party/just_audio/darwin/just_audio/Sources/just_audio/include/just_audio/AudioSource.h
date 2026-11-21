#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

@interface AudioSource : NSObject

@property (readonly, nonatomic) NSString* sourceId;
@property (readwrite, nonatomic) BOOL lazyLoading;

- (instancetype)initWithId:(NSString *)sid;
- (int)buildSequence:(NSMutableArray *)sequence treeIndex:(int)treeIndex;
- (void)findById:(NSString *)sourceId matches:(NSMutableArray<AudioSource *> *)matches;
- (NSArray<NSNumber *> *)getShuffleIndices;
- (void)decodeShuffleOrder:(NSDictionary *)dict;

@end
