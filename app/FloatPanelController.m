#import "FloatPanelController.h"
#import "memread_core.h"
#import "SavedAddressStore.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#include <stdarg.h>

#pragma mark - 静默音频（后台保活）

static void *MemPipPossibleCtx = &MemPipPossibleCtx;

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

static void MemDrawTextRight(NSString *s, CGRect r, UIFont *font, UIColor *color) {
    NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
    p.lineBreakMode = NSLineBreakByClipping;
    p.alignment = NSTextAlignmentRight;
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
@property (nonatomic, assign) BOOL watchSaved;   // YES：监控已保存地址；NO：收敛候选
@property (nonatomic, assign) BOOL retried;
@property (nonatomic, assign) int frames;
@property (nonatomic, assign) BOOL kvoAdded;
@property (nonatomic, assign) int ticks;
- (void)logMsg:(NSString *)fmt, ...;
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
    if (self.kvoAdded) {
        @try { [self.pip removeObserver:self forKeyPath:@"pictureInPicturePossible"]; } @catch (NSException *e) {}
    }
}

- (void)logMsg:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[PiP] %@", msg);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];
    NSString *path = @"/var/mobile/Media/memread_pip.log";
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (NSException *e) {}
    } else {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }

    void (^h)(NSString *) = self.statusHandler;
    if (h) dispatch_async(dispatch_get_main_queue(), ^{ h(msg); });
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
    [self logMsg:@"挂载预览 host=%.0fx%.0f layer=%.0fx%.0f window=%@",
             host.bounds.size.width, host.bounds.size.height,
             self.sbLayer.frame.size.width, self.sbLayer.frame.size.height,
             host.window ? @"有" : @"无"];
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
    if (![self beginWithPid:pid interval:interval]) return NO;
    self.watchSaved = NO;
    self.vtype = type;
    self.cond = cond;
    self.lastLeft = memread_valscan_count();
    [self renderLeft:self.lastLeft changed:0 rows:@[]];
    [self.pip startPictureInPicture];
    [self logMsg:@"已请求 startPictureInPicture（候选模式）active=%d possible=%d",
             (int)self.pip.isPictureInPictureActive, (int)self.pip.isPictureInPicturePossible];
    [self startTimer];
    return YES;
}

- (BOOL)startWatchSavedWithPid:(pid_t)pid interval:(double)interval {
    if ([[SavedAddressStore shared] count] == 0) return NO;
    if (![self beginWithPid:pid interval:interval]) return NO;
    self.watchSaved = YES;
    [self renderSaved:[self savedRowsWithPid:pid]];
    [self.pip startPictureInPicture];
    [self logMsg:@"已请求 startPictureInPicture（地址监控）active=%d possible=%d",
             (int)self.pip.isPictureInPictureActive, (int)self.pip.isPictureInPicturePossible];
    [self startTimer];
    return YES;
}

- (BOOL)beginWithPid:(pid_t)pid interval:(double)interval {
    [self logMsg:@"开始: pid=%d layer=%@ host=%@ supported=%d possible=%d window=%@",
             (int)pid, self.sbLayer ? @"Y" : @"N", self.host ? @"Y" : @"N",
             (int)[AVPictureInPictureController isPictureInPictureSupported],
             (int)self.pip.isPictureInPicturePossible,
             self.host.window ? @"有" : @"无"];
    if (pid <= 0) return NO;
    if (!self.sbLayer || !self.host) return NO;
    if (![AVPictureInPictureController isPictureInPictureSupported]) return NO;

    if (_running) [self stop];

    self.pid = pid;
    self.interval = (interval < 0.5) ? 0.5 : interval;
    self.paused = NO;
    self.retried = NO;
    self.frames = 0;
    self.ticks = 0;

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

    if (!self.kvoAdded) {
        [self.pip addObserver:self forKeyPath:@"pictureInPicturePossible"
                      options:NSKeyValueObservingOptionNew context:MemPipPossibleCtx];
        self.kvoAdded = YES;
    }
    _running = YES;
    return YES;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if (context == MemPipPossibleCtx) {
        [self logMsg:@"pictureInPicturePossible=%d",
                 (int)[(AVPictureInPictureController *)object isPictureInPicturePossible]];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
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

    if (self.watchSaved) {
        NSArray<NSDictionary *> *savedRows = [self savedRowsWithPid:pid];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self renderSaved:savedRows];
        });
        return;
    }

    int type = self.vtype;
    int cond = self.cond;

    unsigned long long left = memread_valscan_count();
    int changed = 0;
    int rc = memread_valscan_autorefine(pid, type, cond, 0, &left, &changed);
    self.ticks++;
    if (self.ticks % 10 == 0 || changed) {
        [self logMsg:@"tick#%d 候选=%llu changed=%d rc=%d type=%d cond=%d",
                 self.ticks, left, changed, rc, type, cond];
    }
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

- (NSArray<NSDictionary *> *)savedRowsWithPid:(pid_t)pid {
    NSArray<SavedAddress *> *items = [[SavedAddressStore shared] allItems];
    NSMutableArray *rows = [NSMutableArray array];
    for (SavedAddress *it in items) {
        double v = 0;
        int rc = memread_read_scalar(pid, it.addr, it.type, &v);
        NSString *val = (rc == 0) ? [SavedAddressStore formatValue:v type:it.type] : @"?";
        [rows addObject:@{@"label": (it.label.length ? it.label : @"(未命名)"), @"v": val}];
    }
    return rows;
}

- (void)enqueueImage:(UIImage *)img {
    if (!img || !self.sbLayer) return;
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
        self.frames++;
        if (self.frames <= 3 || self.frames % 20 == 0) {
            [self logMsg:@"入队第 %d 帧 layer.status=%ld ready=%d",
                     self.frames, (long)self.sbLayer.status, (int)self.sbLayer.readyForMoreMediaData];
        }
    }
    CVPixelBufferRelease(pb);
}

- (void)renderLeft:(unsigned long long)left changed:(int)changed rows:(NSArray<NSDictionary *> *)rows {
    if (!self.sbLayer) return;
    [self enqueueImage:[self imageLeft:left changed:changed rows:rows]];
}

- (void)renderSaved:(NSArray<NSDictionary *> *)rows {
    if (!self.sbLayer) return;
    [self enqueueImage:[self imageSaved:rows]];
}

- (NSString *)stampText {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    return [df stringFromDate:[NSDate date]];
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

        MemDrawTextRight([self stampText], CGRectMake(430, 20, 186, 20),
                         [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular],
                         [UIColor colorWithWhite:0.45 alpha:1]);

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

- (UIImage *)imageSaved:(NSArray<NSDictionary *> *)rows {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1;
    f.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(640, 360)
                                                                       format:f];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *c) {
        CGContextRef ctx = c.CGContext;
        [[UIColor colorWithRed:0.055 green:0.07 blue:0.09 alpha:1] setFill];
        CGContextFillRect(ctx, CGRectMake(0, 0, 640, 360));

        MemDrawText(@"MEMREAD  地址监控", CGRectMake(24, 16, 560, 26),
                    [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold],
                    [UIColor colorWithWhite:0.58 alpha:1]);

        MemDrawTextRight([self stampText], CGRectMake(430, 20, 186, 20),
                         [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular],
                         [UIColor colorWithWhite:0.45 alpha:1]);

        MemDrawText([NSString stringWithFormat:@"%lu 条", (unsigned long)rows.count],
                    CGRectMake(22, 44, 520, 44),
                    [UIFont monospacedSystemFontOfSize:34 weight:UIFontWeightBold],
                    [UIColor whiteColor]);

        MemDrawText([NSString stringWithFormat:@"已保存地址   每 %.1f 秒刷新", self.interval],
                    CGRectMake(24, 88, 560, 22),
                    [UIFont systemFontOfSize:16],
                    [UIColor colorWithWhite:0.55 alpha:1]);

        [[UIColor colorWithWhite:1 alpha:0.12] setFill];
        CGContextFillRect(ctx, CGRectMake(24, 114, 592, 1));

        NSUInteger n = MIN(rows.count, (NSUInteger)8);
        for (NSUInteger i = 0; i < n; i++) {
            NSDictionary *row = rows[i];
            CGFloat y = 122 + i * 26;
            MemDrawText(row[@"label"], CGRectMake(26, y, 380, 24),
                        [UIFont systemFontOfSize:17 weight:UIFontWeightMedium],
                        [UIColor colorWithWhite:0.9 alpha:1]);
            MemDrawTextRight(row[@"v"], CGRectMake(410, y, 208, 24),
                             [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightBold],
                             [UIColor colorWithWhite:1 alpha:1]);
        }

        NSString *foot = rows.count > 8
            ? [NSString stringWithFormat:@"只显示前 8 条，共 %lu 条", (unsigned long)rows.count]
            : @"切枪不影响，各枪弹匣各自一条";
        MemDrawText(foot, CGRectMake(24, 332, 580, 20),
                    [UIFont systemFontOfSize:14],
                    [UIColor colorWithWhite:0.5 alpha:1]);
    }];
}

#pragma mark - PiP 代理

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)c {
    [self logMsg:@"PiP 已启动 active=%d", (int)c.isPictureInPictureActive];
    [self renderLeft:memread_valscan_count() changed:0 rows:@[]];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)c {
    [self logMsg:@"PiP 已被系统关闭"];
    [self stop];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)c
        failedToStartPictureInPictureWithError:(NSError *)error {
    [self logMsg:@"PiP 启动失败: %@ code=%ld %@", error.domain, (long)error.code, error.localizedDescription];
    if (!self.retried) {
        self.retried = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (!_running) return;
            [self logMsg:@"重试 startPictureInPicture possible=%d", (int)self.pip.isPictureInPicturePossible];
            [self.pip startPictureInPicture];
        });
    } else {
        _running = NO;
        [self stopTimer];
    }
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
