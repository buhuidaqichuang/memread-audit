#import "FloatPanelController.h"
#import "memread_core.h"
#import "SavedAddressStore.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - 静默音频（后台保活）

static NSString *MemSilencePath(void) {
    NSString *p = @"/tmp/memread_silence.wav";
    if ([[NSFileManager defaultManager] fileExistsAtPath:p]) return p;

    uint32_t dataSize = 16000;              // 8000Hz * 1s * 16bit 单声道
    uint32_t riffSize = 36 + dataSize;
    uint32_t fmtSize = 16;
    uint16_t fmt = 1, ch = 1, bits = 16, align = 2;
    uint32_t sr = 8000, br = 16000;

    NSMutableData *d = [NSMutableData data];
    [d appendBytes:"RIFF" length:4];
    [d appendBytes:&riffSize length:4];
    [d appendBytes:"WAVEfmt " length:8];
    [d appendBytes:&fmtSize length:4];
    [d appendBytes:&fmt length:2];
    [d appendBytes:&ch length:2];
    [d appendBytes:&sr length:4];
    [d appendBytes:&br length:4];
    [d appendBytes:&align length:2];
    [d appendBytes:&bits length:2];
    [d appendBytes:"data" length:4];
    [d appendBytes:&dataSize length:4];
    [d increaseLengthBy:dataSize];
    [d writeToFile:p atomically:YES];
    return p;
}

#pragma mark - 帧转换

static CGColorSpaceRef MemRGBSpace(void) {
    static CGColorSpaceRef cs = NULL;
    if (!cs) cs = CGColorSpaceCreateDeviceRGB();
    return cs;
}

static CVPixelBufferRef MemPixelBufferFromImage(CGImageRef img) {
    if (!img) return NULL;
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    CVPixelBufferRef pb = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, MemRGBSpace(),
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
        CGContextRelease(ctx);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static CMSampleBufferRef MemSampleBufferFromPixelBuffer(CVPixelBufferRef pb, CMTime pts) {
    CMFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr) return NULL;
    CMSampleTimingInfo t;
    t.duration = CMTimeMake(1, 30);
    t.presentationTimeStamp = pts;
    t.decodeTimeStamp = kCMTimeInvalid;
    CMSampleBufferRef sb = NULL;
    if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &t, &sb) != noErr) sb = NULL;
    CFRelease(fmt);
    return sb;
}

static void MemDrawText(NSString *s, CGRect r, UIFont *font, UIColor *color) {
    NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
    p.lineBreakMode = NSLineBreakByClipping;
    [s drawInRect:r withAttributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: p
    }];
}

#pragma mark - 控制器

@interface FloatPanelController () <AVPictureInPictureControllerDelegate,
                                    AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic, strong) AVSampleBufferDisplayLayer *sbLayer;
@property (nonatomic, strong) AVPictureInPictureController *pip;
@property (nonatomic, weak) UIView *host;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) int vtype;
@property (nonatomic, assign) int cond;
@property (nonatomic, assign) double interval;
@property (nonatomic, assign) BOOL paused;
@property (nonatomic, assign) unsigned long long lastLeft;
@end

@implementation FloatPanelController {
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    BOOL _running;
}

+ (instancetype)shared {
    static FloatPanelController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[FloatPanelController alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _q = dispatch_queue_create("memread.floatpanel", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
}

- (BOOL)isRunning {
    return _running;
}

#pragma mark 预览层

- (void)attachPreviewTo:(UIView *)host {
    if (!host) return;
    self.host = host;
    if (!self.sbLayer) {
        self.sbLayer = [[AVSampleBufferDisplayLayer alloc] init];
        self.sbLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        // PiP 需要 layer 有可推进的时间轴，否则 startPictureInPicture 会失败
        CMTimebaseRef tb = NULL;
        if (CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &tb) == noErr && tb) {
            CMTimebaseSetTime(tb, kCMTimeZero);
            CMTimebaseSetRate(tb, 1.0);
            self.sbLayer.controlTimebase = tb;
            CFRelease(tb);
        }
    }
    self.sbLayer.frame = host.bounds;
    if (self.sbLayer.superlayer != host.layer) {
        [host.layer addSublayer:self.sbLayer];
    }
}

#pragma mark 启停

- (void)startAudio {
    NSError *e = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback
        withOptions:AVAudioSessionCategoryOptionMixWithOthers
              error:&e];
    [s setActive:YES error:&e];
    NSString *p = MemSilencePath();
    if (!p) return;
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:p] error:&e];
    self.player.numberOfLoops = -1;
    self.player.volume = 0.02;
    [self.player prepareToPlay];
    [self.player play];
}

- (BOOL)startWithPid:(pid_t)pid type:(int)type cond:(int)cond interval:(double)interval {
    if (pid <= 0) return NO;
    if (!self.sbLayer || !self.host) return NO;
    if (![AVPictureInPictureController isPictureInPictureSupported]) return NO;

    if (_running) [self stop];

    self.pid = pid;
    self.vtype = type;
    self.cond = cond;
    self.interval = (interval < 0.5) ? 0.5 : interval;
    self.paused = NO;
    self.lastLeft = memread_valscan_count();

    [self startAudio];

    if (!self.pip) {
        AVPictureInPictureControllerContentSource *src =
            [[AVPictureInPictureControllerContentSource alloc]
                initWithSampleBufferDisplayLayer:self.sbLayer
                                playbackDelegate:self];
        self.pip = [[AVPictureInPictureController alloc] initWithContentSource:src];
        self.pip.delegate = self;
    }
    self.pip.canStartPictureInPictureAutomaticallyFromInline = YES;

    _running = YES;
    [self renderLeft:self.lastLeft changed:0 rows:@[]];
    [self.pip startPictureInPicture];
    [self startTimer];
    return YES;
}

- (void)stop {
    _running = NO;
    [self stopTimer];
    if (self.pip.isPictureInPictureActive) [self.pip stopPictureInPicture];
    [self.player stop];
    self.player = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                  withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                        error:NULL];
}

#pragma mark 定时收敛

- (void)startTimer {
    [self stopTimer];
    if (!_q) _q = dispatch_queue_create("memread.floatpanel", DISPATCH_QUEUE_SERIAL);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    uint64_t ns = (uint64_t)(self.interval * NSEC_PER_SEC);
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns),
                              ns, (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_timer, ^{ [ws tick]; });
    dispatch_resume(_timer);
}

- (void)stopTimer {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

- (void)tick {
    if (!_running || self.paused) return;
    pid_t pid = self.pid;
    int type = self.vtype;
    int cond = self.cond;

    unsigned long long left = memread_valscan_count();
    int changed = 0;
    int rc = memread_valscan_autorefine(pid, type, cond, 0, &left, &changed);
    if (rc != 0) return;

    NSMutableArray *rows = [NSMutableArray array];
    unsigned long long n = memread_valscan_count();
    for (unsigned long long i = 0; i < n && i < 5; i++) {
        uint64_t addr = 0, prev = 0;
        double cur = 0;
        if (memread_valscan_get(i, &addr, &prev) != 0) continue;
        int prc = memread_valscan_peek(pid, type, i, NULL, &cur);
        NSString *v = (prc == 0) ? [SavedAddressStore formatValue:cur type:type] : @"?";
        [rows addObject:@{@"addr": @(addr), @"v": v}];
    }
    self.lastLeft = left;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self renderLeft:left changed:changed rows:rows];
    });
}

#pragma mark 渲染

- (void)renderLeft:(unsigned long long)left changed:(int)changed rows:(NSArray<NSDictionary *> *)rows {
    if (!self.sbLayer) return;
    UIImage *img = [self imageLeft:left changed:changed rows:rows];
    if (!img) return;
    CVPixelBufferRef pb = MemPixelBufferFromImage(img.CGImage);
    if (!pb) return;
    CMTime pts = kCMTimeZero;
    if (self.sbLayer.controlTimebase) pts = CMTimebaseGetTime(self.sbLayer.controlTimebase);
    CMSampleBufferRef sb = MemSampleBufferFromPixelBuffer(pb, pts);
    if (sb) {
        if (self.sbLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [self.sbLayer flush];
        }
        [self.sbLayer enqueueSampleBuffer:sb];
        CFRelease(sb);
    }
    CVPixelBufferRelease(pb);
}

- (UIImage *)imageLeft:(unsigned long long)left changed:(int)changed rows:(NSArray<NSDictionary *> *)rows {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1;
    f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(640, 360)
                                                                       format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGContextRef ctx = c.CGContext;
        [[UIColor colorWithRed:0.055 green:0.07 blue:0.09 alpha:1] setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, 640, 360));

        MemDrawText(@"MEMREAD  自动收敛", CGRectMake(24, 16, 560, 26),
                    [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold],
                    [UIColor colorWithWhite:0.58 alpha:1]);

        MemDrawText([NSString stringWithFormat:@"%llu", left], CGRectMake(22, 44, 520, 58),
                    [UIFont monospacedSystemFontOfSize:48 weight:UIFontWeightBold],
                    [UIColor whiteColor]);

        MemDrawText(@"候选剩余", CGRectMake(24, 102, 200, 24),
                    [UIFont systemFontOfSize:17],
                    [UIColor colorWithWhite:0.62 alpha:1]);

        NSString *condName = @"变小了";
        if (self.cond == MEMREAD_VALCOND_INCREASED) condName = @"变大了";
        else if (self.cond == MEMREAD_VALCOND_CHANGED) condName = @"变了";
        MemDrawText([NSString stringWithFormat:@"条件 %@   每 %.1f 秒一轮", condName, self.interval],
                    CGRectMake(24, 128, 560, 22),
                    [UIFont systemFontOfSize:16],
                    [UIColor colorWithWhite:0.55 alpha:1]);

        [[UIColor colorWithWhite:1 alpha:0.12] setFill];
        CGContextFillRect(ctx, CGRectMake(24, 154, 592, 1));

        NSUInteger i = 0;
        for (NSDictionary *row in rows) {
            uint64_t addr = [row[@"addr"] unsignedLongLongValue];
            NSString *hex = [NSString stringWithFormat:@"0x%08llX", (unsigned long long)addr];
            NSString *line = [NSString stringWithFormat:@"%@   = %@", hex, row[@"v"]];
            MemDrawText(line, CGRectMake(26, 164 + i * 30, 580, 26),
                        [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightMedium],
                        [UIColor colorWithWhite:0.93 alpha:1]);
            i++;
        }

        NSString *foot = changed ? [NSString stringWithFormat:@"刚收敛，剩余 %llu", left] : @"等待数值变化，候选保持不动";
        MemDrawText(foot, CGRectMake(24, 324, 580, 22),
                    [UIFont systemFontOfSize:15],
                    [UIColor colorWithWhite:0.5 alpha:1]);
    }];
}

#pragma mark - PiP 代理

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)c {
    [self renderLeft:memread_valscan_count() changed:0 rows:@[]];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)c {
    [self stop];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
        failedToStartPictureInPictureWithError:(NSError *)error {
    NSLog(@"[FloatPanel] PiP 启动失败: %@", error);
    _running = NO;
    [self stopTimer];
}

#pragma mark - 播放代理

- (void)pictureInPictureController:(AVPictureInPictureController *)c setPlaying:(BOOL)playing {
    self.paused = !playing;
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)c {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)c {
    return self.paused;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
             didTransitionToRenderSize:(CMVideoDimensions)newRenderSize {
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler {
    if (completionHandler) completionHandler();
}

@end
