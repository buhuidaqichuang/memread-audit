#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <OpenGLES/EAGL.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <dlfcn.h>
#import "AppDelegate.h"

// 启动自检：把进程身份与 GPU 能力写盘，便于从电脑侧 AFC 直接取回分析
static NSString *MemReadEnvFilePath(void) {
    static NSString *path = nil;
    if (path) return path;
    if ([[NSFileManager defaultManager] isWritableFileAtPath:@"/var/mobile/Media"]) {
        path = @"/var/mobile/Media/memread_env.txt";
    } else {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        path = [docs stringByAppendingPathComponent:@"memread_env.txt"];
    }
    return path;
}

static void MemReadEnvLine(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *path = MemReadEnvFilePath();
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSString *s = old ? [old stringByAppendingFormat:@"%@\n", line] : [line stringByAppendingString:@"\n"];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void MemReadEnvSelfCheck(void) {
    MemReadEnvLine(@"========== launch %@", [NSDate date]);
    MemReadEnvLine(@"uid=%d euid=%d gid=%d pid=%d", getuid(), geteuid(), getgid(), getpid());
    MemReadEnvLine(@"bundle=%@", [[NSBundle mainBundle] bundlePath]);
    MemReadEnvLine(@"exe=%@", [[NSBundle mainBundle] executablePath]);

    uint32_t n = _dyld_image_count();
    int jbCount = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *p = [NSString stringWithUTF8String:nm];
        NSString *low = p.lowercaseString;
        if ([low containsString:@"jbroot"] || [low containsString:@"libroot"] ||
            [low containsString:@"libhooker"] || [low containsString:@"substrate"] ||
            [low containsString:@"ellekit"] || [low containsString:@"/var/jb"]) {
            MemReadEnvLine(@"jb_image=%@", p);
            jbCount++;
        }
    }
    MemReadEnvLine(@"jb_images=%d dyld_total=%u", jbCount, n);

    EAGLContext *gl = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    MemReadEnvLine(@"eagl_es2=%@", gl ? @"OK" : @"NIL");

    // CoreImage 走的是 OpenGL ES；这里记录能否加载驱动与拿到 glGetString
    void *hGL = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_GLOBAL);
    MemReadEnvLine(@"opengles_dlopen=%s", hGL ? "OK" : (dlerror() ?: "NULL"));
    if (hGL) {
        MemReadEnvLine(@"glGetString=%p", dlsym(hGL, "glGetString"));
        MemReadEnvLine(@"glCreateShader=%p", dlsym(hGL, "glCreateShader"));
    }

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    MemReadEnvLine(@"metal_device=%@", dev ? dev.name : @"NIL");

    // 图标资源是否真的进包
    NSString *b = [[NSBundle mainBundle] bundlePath];
    NSArray *files = @[@"Assets.car", @"AppIcon60x60@2x.png", @"AppIcon76x76@2x~ipad.png",
                       @"AppIcon83.5x83.5@2x~ipad.png", @"AppIcon1024.png"];
    for (NSString *f in files) {
        BOOL e = [[NSFileManager defaultManager] fileExistsAtPath:[b stringByAppendingPathComponent:f]];
        MemReadEnvLine(@"file %@=%d", f, e ? 1 : 0);
    }
    MemReadEnvLine(@"CFBundleIconName=%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIconName"] ?: @"(none)");

    MemReadEnvLine(@"========== end");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        @try { MemReadEnvSelfCheck(); } @catch (id e) { }
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
