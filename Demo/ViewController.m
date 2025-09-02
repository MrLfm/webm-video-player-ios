//
//  ViewController.m
//  Demo
//
//  Created by FM on 2025/8/20.
//

#import "ViewController.h"
#import <FMVideoPlayer/FMVideoPlayer.h>

@interface ViewController ()
@property (nonatomic, strong) VideoPlayer *player;
@property (weak, nonatomic) IBOutlet UIView *bgView1;
@property (weak, nonatomic) IBOutlet UIView *bgView2;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.player = [[VideoPlayer alloc] init];
    
    // 设置默认播放的父视图
    targetView = self.bgView1;
    self.player.displayLayer.frame = targetView.bounds;
    [targetView.layer addSublayer:self.player.displayLayer];
}

- (IBAction)btnActionPlay:(id)sender {
    [self switchVideoURL];
    
    [self.player playWithURL:currentURL repeats:true];
}

- (IBAction)btnActionPause:(id)sender {
    [self.player pause];
}

- (IBAction)btnActionResume:(id)sender {
    [self.player resume];
}

- (IBAction)btnActionStop:(id)sender {
    [self.player stopWithCompletion:nil];
}

- (IBAction)btnActionSwitchBgView:(id)sender {
    [self switchVideoURL];
    [self switchBgView];
    
    /** 步骤
     1、停止当前播放
     2、把displayLayer从当前父视图移除
     3、把displayLayer添加到目标父视图
     4、重新播放
     */
    [self.player stopWithCompletion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.player.displayLayer removeFromSuperlayer];
            
            self.player.displayLayer.frame = targetView.bounds;
            [targetView.layer addSublayer:self.player.displayLayer];
            
            [self.player playWithURL:currentURL repeats:true];
        });
    }];
}

NSInteger count = -1;
NSString *currentURL = @"";
UIView *targetView = nil;
- (void)switchVideoURL {
    if (count > 3) {
        count = -1;
    }
    count ++;
    
    switch (count) {
        case 0:
            currentURL = @"http://video.akamai.steamstatic.com/store_trailers/257157552/movie480.mp4?t=1750178947";
            break;
        case 1:
            currentURL = @"https://v.3304399.net/yxh/media/49672/a6b914ced19011efa9221866da4d1cd2.mp4?w=1920x1080&t=58&s=25594021";
            break;
        case 2:
            currentURL = @"https://uxdl.bigeyes.com/ux-landscape/st/en/video/6875/96/a2/687596a2a84a59d830a5ae05441dd9c6.webm";
            break;
        case 3:
            currentURL = @"http://video.akamai.steamstatic.com/store_trailers/256814537/movie480.mp4?t=1669135900";
        default:
            break;
    }
}

- (void)switchBgView {
    targetView = (count % 2 == 0) ? self.bgView1 : self.bgView2;
}

@end
