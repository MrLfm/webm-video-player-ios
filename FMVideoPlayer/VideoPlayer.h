//
//  VideoPlayer.h
//  VideoPlayer
//
//  Created by FM on 2025/8/20.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VideoPlayer : NSObject

/// 视频帧渲染层
@property (nonatomic, strong, readonly) AVSampleBufferDisplayLayer *displayLayer;
/// 正在播放
@property (nonatomic, assign, readonly) BOOL isPlaying;
/// 已暂停
@property (nonatomic, assign, readonly) BOOL isPaused;

/**
 播放线上或本地视频
 @param url 视频地址
 @param repeats 是否循环播放
 */
- (void)playWithURL:(NSString *)url repeats:(BOOL)repeats;

/// 暂停播放
- (void)pause;

/// 恢复播放
- (void)resume;

/// 切换暂停/播放状态
- (void)togglePause;

/**
 停止播放（非耗时操作)
 @param completion 完成回调
 此操作会停止音频和视频的解码和播放，但会保留缓存和缓冲区数据
 */
- (void)stopWithCompletion:(nullable void(^)(void))completion;

/**
 清空缓存（耗时操作)
 此操作会清空音视频缓存和缓冲区数据，并把未播放的视频帧清除（在主线程执行）
 @param completion 完成回调
 */
- (void)clearCacheWithCompletion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
