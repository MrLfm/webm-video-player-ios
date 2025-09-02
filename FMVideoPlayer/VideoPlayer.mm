//
//  VideoPlayer.m
//

#import "VideoPlayer.h"
#import "VideoTool.h"
#import <SDL2/SDL.h>
#include <vector>
#include <deque>

#ifdef __cplusplus
extern "C" {
#endif
#include <ffmpeg/libavcodec/avcodec.h>
#include <ffmpeg/libavformat/avformat.h>
#include <ffmpeg/libswresample/swresample.h>
#ifdef __cplusplus
}
#endif

@interface VideoPlayer ()
{
    AVFormatContext *fmtCtx;
    AVCodecContext *videoCodecCtx;
    AVCodecContext *audioCodecCtx;
    int videoStreamIndex;
    int audioStreamIndex;
    
    SwrContext *swrCtx;
    
    dispatch_queue_t decodeQueue;
    BOOL stopRequested;
    
    // 音频缓存
    std::vector<int16_t> audio_buffer;
    std::mutex buffer_mutex;
    
    // 添加暂停控制
    dispatch_semaphore_t pauseSemaphore;
}

@property (nonatomic, strong, readwrite) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, assign, readwrite) BOOL isPlaying;
@property (nonatomic, assign, readwrite) BOOL isPaused;
@property (nonatomic, copy)   NSString *currentURL;
@property (nonatomic, assign) BOOL isLoopPlay;
@property (nonatomic, assign) BOOL hasCache;
@end

@implementation VideoPlayer

- (instancetype)init {
    if (self = [super init]) {
        //        NSLog(@"ℹ️ 初始化视频播放器");
        _displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;// 全屏播放
        decodeQueue = dispatch_queue_create("video.decode.queue", DISPATCH_QUEUE_SERIAL);
        self.isPlaying = NO;
        stopRequested = NO;
        self.isPaused = NO;
        pauseSemaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)playWithURL:(NSString *)urlString repeats:(BOOL)repeats {
    self.isLoopPlay = repeats;
    self.currentURL = urlString;
    [self playWithURL:urlString];
}

- (void)playWithURL:(NSString *)urlString {
    if (self.isPlaying) {
        NSLog(@"⚠️ 播放失败！禁止重复播放");
        return;
    }
    
    if (!_displayLayer) {
        NSLog(@"❌ 显示层未初始化，无法播放视频");
        return;
    }
    stopRequested = NO;
    
    // 播放前清除旧数据
    [self clearCacheWithCompletion:^{
        __weak typeof(self) weakSelf = self;
        dispatch_async(decodeQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            
            NSLog(@"ℹ️ 开始播放视频：%@", urlString);
            [weakSelf decodeLoopWithURL:urlString];
        });
    }];
}

#pragma mark - 暂停和恢复控制

- (void)pause {
    if (!self.isPlaying) {
        NSLog(@"⚠️ 暂停失败！当前没有在播放视频");
        return;
    }
    
    if (self.isPaused) {
        NSLog(@"⚠️ 视频已经处于暂停状态，无需暂停");
        return;
    }
    
    NSLog(@"⏸️ 暂停视频播放");
    self.isPaused = YES;
    
    // 暂停音频
    SDL_PauseAudio(1);
    
    // 暂停视频显示层
    if (_displayLayer) {
        [_displayLayer.sampleBufferRenderer stopRequestingMediaData];
    }
}

- (void)resume {
    if (!self.isPlaying) {
        NSLog(@"⚠️ 恢复播放失败！没有在播放视频");
        return;
    }
    
    if (!self.isPaused) {
        NSLog(@"⚠️ 视频没有暂停，无需恢复");
        return;
    }
    
    NSLog(@"▶️ 恢复视频播放");
    self.isPaused = NO;
    
    // 恢复音频
    SDL_PauseAudio(0);
    
    // 恢复视频显示层
    if (_displayLayer) {
        [_displayLayer.sampleBufferRenderer requestMediaDataWhenReadyOnQueue:dispatch_get_main_queue() usingBlock:^{}];
    }
    
    // 发送信号，唤醒被暂停的解码线程
    dispatch_semaphore_signal(pauseSemaphore);
}

// 切换暂停/播放状态
- (void)togglePause {
    if (self.isPaused) {
        [self resume];
    }
    else {
        [self pause];
    }
}

// 注意📢这里只处理不耗时的操作！
- (void)stopWithCompletion:(void (^)())completion {
    if (!self.isPlaying) {
        if (completion) {
            completion();
        }
        NSLog(@"⚠️ 停止播放失败！没有在播放视频");
        return;
    }
    
    NSLog(@"ℹ️ 正在停止音频和视频播放...");
    
    // 如果当前是暂停状态，先恢复以便正常退出
    if (self.isPaused) {
        self.isPaused = NO;
        dispatch_semaphore_signal(pauseSemaphore);
    }
    
    SDL_PauseAudio(1);
    stopRequested = YES;
    self.isPlaying = NO;
    
    NSLog(@"✅ 已停止音频和视频播放");
    
    if (completion) {
        completion();
    }
}

- (void)clearCacheWithCompletion:(void (^)())completion {
    if (self.isPlaying) {
        if (completion) {
            completion();
        }
        NSLog(@"⚠️ 清除缓存失败！请先停止播放视频");
        return;
    }
    
    if (!self.hasCache) {
        if (completion) {
            completion();
        }
        return;
    }
    NSLog(@"ℹ️ 正在清理播放器缓存...");
    
    // 1、释放解码器，清除缓存
    if (videoCodecCtx) {
        avcodec_free_context(&videoCodecCtx);
        videoCodecCtx = NULL;
    }
    if (audioCodecCtx) {
        avcodec_free_context(&audioCodecCtx);
        audioCodecCtx = NULL;
    }
    if (fmtCtx) {
        avformat_close_input(&fmtCtx);
        fmtCtx = NULL;
    }
    if (swrCtx) {
        swr_free(&swrCtx);
        swrCtx = NULL;
    }
    
    [[VideoTool sharedInstance] clear];
    
    // 2、清空音频缓冲区
    {
        std::lock_guard<std::mutex> lock(buffer_mutex);
        audio_buffer.clear();
    }
    
    if (!_displayLayer) {
        self.hasCache = NO;
        if (completion) {
            completion();
        }
        return;
    }
    
    // 3、清空视频缓冲区
    // 停止接收新数据
    [_displayLayer.sampleBufferRenderer stopRequestingMediaData];
    dispatch_async(dispatch_get_main_queue(), ^{
        // 清除已显示的内容，必须在主线程执行
        [self.displayLayer.sampleBufferRenderer flushWithRemovalOfDisplayedImage:true completionHandler:^{
            NSLog(@"✅ 已清理播放器缓存");
            
            self.hasCache = NO;
            if (completion) {
                completion();
            }
        }];
    });
}

#pragma mark - Decode Loop
- (void)decodeLoopWithURL:(NSString *)urlString {
    if (!self) return;
    if (self.isPlaying) {
        //        NSLog(@"⚠️ decodeLoop 已经在执行，禁止重复进入");
        return;
    }
    self.isPlaying = YES;
    self.isPaused = NO; // 重置暂停状态
    BOOL playbackCompleted = NO;
    
    @autoreleasepool {
        if (!fmtCtx) {
            fmtCtx = avformat_alloc_context();
        }
        
        self.hasCache = YES;// 产生缓存
        
        if (avformat_open_input(&fmtCtx, urlString.UTF8String, NULL, NULL) != 0) {
            NSLog(@"❌ 打开视频文件失败，无法播放视频");
            self.isPlaying = NO;
            return;
        }
        if (avformat_find_stream_info(fmtCtx, NULL) < 0) {
            NSLog(@"❌ 查找视频流信息失败，无法播放视频");
            self.isPlaying = NO;
            return;
        }
        
        // 帧索引
        audioStreamIndex = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
        videoStreamIndex = av_find_best_stream(fmtCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
        
        for (unsigned i = 0; i < fmtCtx->nb_streams; i++) {
            if (fmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && videoStreamIndex < 0) {
                videoStreamIndex = i;
            }
            else if (fmtCtx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && audioStreamIndex < 0) {
                audioStreamIndex = i;
            }
        }
        if (videoStreamIndex < 0) {
            NSLog(@"❌ 未找到视频流，无法播放视频");
            self.isPlaying = NO;
            return;
        }
        
        // 视频解码器
        AVCodecParameters *videoCodecPar = fmtCtx->streams[videoStreamIndex]->codecpar;
        const AVCodec *videoCodec = avcodec_find_decoder(videoCodecPar->codec_id);
        videoCodecCtx = avcodec_alloc_context3(videoCodec);
        avcodec_parameters_to_context(videoCodecCtx, videoCodecPar);
        avcodec_open2(videoCodecCtx, videoCodec, NULL);
        
        // 音频解码器
        if (audioStreamIndex >= 0) {
            AVCodecParameters *audioCodecPar = fmtCtx->streams[audioStreamIndex]->codecpar;
            const AVCodec *audioCodec = avcodec_find_decoder(audioCodecPar->codec_id);
            audioCodecCtx = avcodec_alloc_context3(audioCodec);
            avcodec_parameters_to_context(audioCodecCtx, audioCodecPar);
            avcodec_open2(audioCodecCtx, audioCodec, NULL);
            
            // 初始化 SDL 音频
            [self initAudioPlayer];
        }
        
        // 获取视频帧率
        AVStream *videoStream = fmtCtx->streams[videoStreamIndex];
        AVRational fps = av_guess_frame_rate(fmtCtx, videoStream, NULL);
        double frameRate = (double)fps.num / fps.den;
        if (frameRate <= 0) {
            frameRate = 30.0; // 默认帧率
        }
        double frameDuration = 1.0 / frameRate;
        //    NSLog(@"🎥 视频帧率: %.2f fps, 帧间隔: %.3f秒", frameRate, frameDuration);
        [[VideoTool sharedInstance] setFPS:frameRate];// 设置帧率
        
        // Decode Loop
        AVPacket *pkt = av_packet_alloc();
        AVFrame *videoFrame = av_frame_alloc();
        AVFrame *audioFrame = av_frame_alloc();
        
        CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
        CFAbsoluteTime pauseStartTime = 0;
        CFAbsoluteTime totalPauseTime = 0;
        int frameIndex = 0;
        
        while (!stopRequested && av_read_frame(fmtCtx, pkt) >= 0) {
            if (stopRequested) break;// 每次发送新帧前检查 stopRequested，防止在调用stop方法后仍然enqueue老帧
            
            // 处理暂停逻辑
            if (self.isPaused) {
                pauseStartTime = CFAbsoluteTimeGetCurrent();
                NSLog(@"🔄 解码线程进入暂停状态");
                
                // 等待恢复信号
                dispatch_semaphore_wait(pauseSemaphore, DISPATCH_TIME_FOREVER);
                
                if (stopRequested) {
                    break;
                }
                
                // 计算暂停时间，调整播放时间基准
                CFAbsoluteTime pauseEndTime = CFAbsoluteTimeGetCurrent();
                totalPauseTime += (pauseEndTime - pauseStartTime);
                NSLog(@"🔄 解码线程恢复运行");
            }
            
            // 解码视频数据
            if (pkt->stream_index == videoStreamIndex) {
                avcodec_send_packet(videoCodecCtx, pkt);
                
                while (!stopRequested && !self.isPaused && avcodec_receive_frame(videoCodecCtx, videoFrame) == 0) {
                    // 调整时间计算，考虑暂停时间
                    CFAbsoluteTime expectedTime = startTime + frameIndex * frameDuration + totalPauseTime;
                    CFAbsoluteTime currentTime = CFAbsoluteTimeGetCurrent();
                    if (currentTime < expectedTime) {
                        usleep((expectedTime - currentTime) * 1000000);
                    }
                    
                    // 转 CMSampleBuffer
                    CMSampleBufferRef sbuf = [[VideoTool sharedInstance] getRenderDataWithFrame:videoFrame];
                    if (sbuf) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (!stopRequested && !self.isPaused && self.displayLayer) {
                                [self.displayLayer enqueueSampleBuffer:sbuf];
                            }
                            CFRelease(sbuf);
                        });
                    }
                    frameIndex++;
                    av_frame_unref(videoFrame);
                }
            }
            
            // 解码音频数据
            else if (pkt->stream_index == audioStreamIndex) {
                avcodec_send_packet(audioCodecCtx, pkt);
                while (!stopRequested && !self.isPaused && avcodec_receive_frame(audioCodecCtx, audioFrame) == 0) {
                    // 转 PCM 16bit
                    int out_channels = audioCodecCtx->channels;
                    int out_sample_rate = audioCodecCtx->sample_rate;
                    
                    // 初始化 SwrContext
                    if (!swrCtx) {
                        swrCtx = swr_alloc_set_opts(NULL,
                                                    av_get_default_channel_layout(out_channels),
                                                    AV_SAMPLE_FMT_S16,
                                                    out_sample_rate,
                                                    av_get_default_channel_layout(audioCodecCtx->channels),
                                                    audioCodecCtx->sample_fmt,
                                                    audioCodecCtx->sample_rate,
                                                    0, NULL);
                        swr_init(swrCtx);
                    }
                    
                    int nb_samples = audioFrame->nb_samples;
                    int16_t *outBuffer = (int16_t *)malloc(nb_samples * out_channels * sizeof(int16_t));
                    uint8_t *outPtr[1] = {(uint8_t *)outBuffer};
                    swr_convert(swrCtx, outPtr, nb_samples, (const uint8_t **)audioFrame->data, nb_samples);
                    
                    // 放入 SDL 缓冲区
                    {
                        std::lock_guard<std::mutex> lock(buffer_mutex);
                        audio_buffer.insert(audio_buffer.end(), outBuffer, outBuffer + nb_samples * out_channels);
                    }
                    free(outBuffer);
                    av_frame_unref(audioFrame);
                }
            }
            av_packet_unref(pkt);
        }
        
        av_frame_free(&videoFrame);
        av_frame_free(&audioFrame);
        av_packet_free(&pkt);
        
        // 检查是正常播放结束还是被停止
        if (!stopRequested) {
            playbackCompleted = YES;
        }
    }
    
    self.isPlaying = NO;
    self.isPaused = NO;
    
    if (playbackCompleted && self.isLoopPlay) {
        NSLog(@"ℹ️ 重新播放视频");
        [self playWithURL:self.currentURL];
    }
}

#pragma mark - SDL 音频
- (void)initAudioPlayer {
    SDL_SetMainReady();
    
    // 初始化音频解码器
    if (SDL_WasInit(SDL_INIT_AUDIO) == 0) {
        if (SDL_Init(SDL_INIT_AUDIO) < 0) {
            NSLog(@"❌ 音频解码器初始化失败，无法播放音频：%s", SDL_GetError());
            return;
        }
    }
    
    // 先关闭音频，再用新参数创建音频。如果不关闭，可能会导致音频解析错误（音频像是0.9倍速播放）
    if (SDL_GetAudioStatus() != SDL_AUDIO_STOPPED) {
//        NSLog(@"⚠️ 音频未停止，尝试关闭");
        SDL_CloseAudio();
    }
    
    SDL_AudioSpec spec;
    spec.freq = audioCodecCtx->sample_rate;
    spec.format = AUDIO_S16SYS;
    spec.channels = audioCodecCtx->channels;
    spec.samples = 1024;
    spec.callback = sdl_audio_callback;
    spec.userdata = (__bridge void *)self;// 代理
    
    if (SDL_OpenAudio(&spec, NULL) < 0) {
        NSLog(@"❌ 开启音频失败，无法播放音频：%s", SDL_GetError());
        return;
    }
//    NSLog(@"SDL 音频已开启，采样率：%d，通道数：%d", spec.freq, spec.channels);
    SDL_PauseAudio(0);
}

void sdl_audio_callback(void *userdata, Uint8 *stream, int len) {
    VideoPlayer *player = (__bridge VideoPlayer *)userdata;
    std::lock_guard<std::mutex> lock(player->buffer_mutex);
    
    if (player->audio_buffer.empty()) {
        SDL_memset(stream, 0, len);
        return;
    }
    
    int copy_size = len / 2;
    int available_size = player->audio_buffer.size();
    if (copy_size > available_size) copy_size = available_size;
    
    SDL_memcpy(stream, player->audio_buffer.data(), copy_size * 2);
    player->audio_buffer.erase(player->audio_buffer.begin(), player->audio_buffer.begin() + copy_size);
}

- (void)dealloc {
    NSLog(@"FMVideoPlayer dealloc");
    [self stopWithCompletion:nil];
}

@end
