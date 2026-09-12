#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <objc/runtime.h>
#import "../LiveContainer/utils.h"
#include "../LiveContainer/LCDebugLog.h"
#include "../litehook/src/litehook.h"

static NSString *const kDisabledTweaksKey = @"disabledItems";
static NSString *const kContainerInfoFileName = @"LCContainerInfo.plist";
static NSString *const kStrictSessionMarkerFileName = @".lc_strict_session_active";
static BOOL strictTestModeEnabled = NO;
static BOOL strictAutoWipeOnExitEnabled = NO;
static BOOL strictAutoWipePerformed = NO;
static NSString *strictContainerHomePath = nil;
static id strictWillTerminateObserver = nil;

static void LCStrictAutoWipeOnExit(void);

static void LCStrictEnsureContainerDirectories(NSString *homePath) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *directories = @[@"Library/Caches", @"Library/Cookies", @"Documents", @"SystemData", @"tmp"];
    for(NSString *directory in directories) {
        NSString *path = [homePath stringByAppendingPathComponent:directory];
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

static NSString *LCStrictSessionMarkerPath(NSString *homePath) {
    if(homePath.length == 0) {
        return nil;
    }
    return [homePath stringByAppendingPathComponent:kStrictSessionMarkerFileName];
}

static void LCStrictWriteSessionMarker(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return;
    }
    [NSFileManager.defaultManager createFileAtPath:markerPath contents:[NSData data] attributes:nil];
}

static void LCStrictRemoveSessionMarker(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:markerPath error:nil];
}

static BOOL LCStrictSessionMarkerExists(NSString *homePath) {
    NSString *markerPath = LCStrictSessionMarkerPath(homePath);
    if(markerPath.length == 0) {
        return NO;
    }
    return [NSFileManager.defaultManager fileExistsAtPath:markerPath];
}

static void LCStrictWipeContainerContentsIfNeeded(void) {
    if(!strictTestModeEnabled || !strictAutoWipeOnExitEnabled) {
        return;
    }
    NSString *homePath = strictContainerHomePath;
    if(homePath.length == 0 || [homePath isEqualToString:@"/"]) {
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *containerInfoPath = [homePath stringByAppendingPathComponent:kContainerInfoFileName];
    if(![fm fileExistsAtPath:containerInfoPath]) {
        return;
    }

    NSError *listError = nil;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:homePath error:&listError];
    if(!entries) {
        NSLog(@"[LC][StrictMode] Failed to enumerate container for auto-wipe: %@", listError.localizedDescription);
        return;
    }

    for(NSString *entry in entries) {
        if([entry isEqualToString:kContainerInfoFileName]) {
            continue;
        }
        NSString *entryPath = [homePath stringByAppendingPathComponent:entry];
        NSError *removeError = nil;
        if(![fm removeItemAtPath:entryPath error:&removeError] && removeError) {
            NSLog(@"[LC][StrictMode] Failed to remove %@ during auto-wipe: %@", entry, removeError.localizedDescription);
        }
    }

    LCStrictEnsureContainerDirectories(homePath);
}

static void LCStrictRecoverStaleSessionIfNeeded(void) {
    if(!strictAutoWipeOnExitEnabled || strictContainerHomePath.length == 0) {
        return;
    }
    if(LCStrictSessionMarkerExists(strictContainerHomePath)) {
        NSLog(@"[LC][StrictMode] Detected stale strict session marker. Applying deferred auto-wipe.");
        LCStrictWipeContainerContentsIfNeeded();
        LCStrictRemoveSessionMarker(strictContainerHomePath);
    }
}

static void LCStrictRegisterLifecycleObservers(void) {
    if(!strictAutoWipeOnExitEnabled || strictWillTerminateObserver != nil) {
        return;
    }
    strictWillTerminateObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        LCStrictAutoWipeOnExit();
    }];
}

static void LCStrictAutoWipeOnExit(void) {
    @autoreleasepool {
        if(strictAutoWipePerformed) {
            return;
        }
        strictAutoWipePerformed = YES;
        LCStrictWipeContainerContentsIfNeeded();
        LCStrictRemoveSessionMarker(strictContainerHomePath);
    }
}

static NSSet<NSString *> *disabledItemsForFolder(NSURL *folderURL) {
    if (!folderURL || !folderURL.isFileURL) {
        return [NSSet set];
    }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[folderURL URLByAppendingPathComponent:@"TweakInfo.plist"]];
    NSArray<NSString *> *disabled = info[kDisabledTweaksKey];
    if (![disabled isKindOfClass:NSArray.class]) {
        return [NSSet set];
    }
    return [NSSet setWithArray:disabled];
}

static BOOL isTweakURLDisabled(NSURL *url, NSURL *rootFolderURL) {
    if (!url || !rootFolderURL) {
        return NO;
    }
    NSURL *cursor = url;
    NSString *rootPath = [rootFolderURL.path stringByStandardizingPath];
    while (cursor && [[cursor.path stringByStandardizingPath] hasPrefix:rootPath]) {
        NSURL *parent = cursor.URLByDeletingLastPathComponent;
        NSSet<NSString *> *disabled = disabledItemsForFolder(parent);
        if ([disabled containsObject:cursor.lastPathComponent]) {
            return YES;
        }
        if ([[cursor.path stringByStandardizingPath] isEqualToString:rootPath]) {
            break;
        }
        cursor = parent;
    }
    return NO;
}

static NSString * const kLCPackageMetadataFileName = @".lc-package.json";

static NSString *gContainerTweakPath = nil;
static NSString *gGlobalTweakPath = nil;
static NSString *gTweakFolderName = nil;

// Thread-local storage for per-tweak resource path
// NOTE: __thread storage cannot hold an ARC-strong object (Clang cannot emit a
// static initializer for a thread-local with non-trivial ownership), so this is
// declared __unsafe_unretained. This is safe because every assignment site keeps
// a strong reference to the same string alive on the stack (tweakResourceBasePath /
// previousTweakResourcePath in loadTweakAtURL) for the entire duration during which
// this thread-local is read, so it never dangles.
static __thread NSString *__unsafe_unretained gCurrentTweakResourcePath = nil;

static BOOL stringMatchesPattern(NSString *value, NSString *pattern) {
    if (![pattern isKindOfClass:NSString.class] || pattern.length == 0) {
        return NO;
    }
    if ([pattern isEqualToString:@"*"]) {
        return YES;
    }
    if ([pattern hasSuffix:@"*"]) {
        NSString *prefix = [pattern substringToIndex:pattern.length - 1];
        return [value hasPrefix:prefix];
    }
    return [value isEqualToString:pattern];
}

static BOOL isSafeArtifactRelativePath(NSString *relativePath) {
    if (![relativePath isKindOfClass:NSString.class] || relativePath.length == 0) {
        return NO;
    }
    if ([relativePath hasPrefix:@"/"]) {
        return NO;
    }
    for (NSString *component in [relativePath pathComponents]) {
        if ([component isEqualToString:@".."]) {
            return NO;
        }
    }
    return YES;
}

static BOOL processMatchesSubstrateFilter(NSURL *dylibURL) {
    NSString *baseName = [dylibURL.lastPathComponent stringByDeletingPathExtension];
    NSURL *filterPlistURL = [[dylibURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:[baseName stringByAppendingPathExtension:@"plist"]];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfURL:filterPlistURL];
    if (![dict isKindOfClass:NSDictionary.class]) {
        return YES;
    }
    NSDictionary *filter = dict[@"Filter"];
    if (![filter isKindOfClass:NSDictionary.class]) {
        return YES;
    }

    BOOL hasAnyRule = NO;
    BOOL matched = NO;
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *executableName = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";

    NSArray *bundleRules = filter[@"Bundles"];
    if ([bundleRules isKindOfClass:NSArray.class]) {
        hasAnyRule = YES;
        for (id rule in bundleRules) {
            if (stringMatchesPattern(bundleIdentifier, rule)) {
                matched = YES;
                break;
            }
        }
    }
    NSArray *executableRules = filter[@"Executables"];
    if ([executableRules isKindOfClass:NSArray.class]) {
        hasAnyRule = YES;
        for (id rule in executableRules) {
            if (stringMatchesPattern(executableName, rule)) {
                matched = YES;
                break;
            }
        }
    }
    NSArray *classRules = filter[@"Classes"];
    if ([classRules isKindOfClass:NSArray.class]) {
        hasAnyRule = YES;
        for (id rule in classRules) {
            if (![rule isKindOfClass:NSString.class]) {
                continue;
            }
            if (NSClassFromString(rule) != Nil) {
                matched = YES;
                break;
            }
        }
    }
    return !hasAnyRule || matched;
}

static NSString *loadTweakAtURL(NSURL *url, NSString *sourceContext) {
    NSString *tweakPath = url.path;
    NSString *tweak = tweakPath.lastPathComponent;
    if (![tweakPath hasSuffix:@".dylib"] && ![tweakPath hasSuffix:@".framework"]) {
        return nil;
    }
    if ([tweakPath hasSuffix:@".dylib"] && !processMatchesSubstrateFilter(url)) {
        NSLog(@"Skipping tweak %@ because filter does not match this process", tweak);
        return nil;
    }
    
    // Determine the tweak's resource base path
    // The tweak is at something like .../Tweaks/<folder>/<tweak.dylib> or .../Tweaks/<folder>/<tweak.framework>
    // The resource base should be .../Tweaks/<folder>/
    NSString *tweakResourceBasePath = nil;
    NSURL *tweakFolderURL = [url URLByDeletingLastPathComponent];
    // If it's a .framework, go up one more level
    if ([tweakPath hasSuffix:@".framework"]) {
        tweakFolderURL = [tweakFolderURL URLByDeletingLastPathComponent];
    }
    tweakResourceBasePath = tweakFolderURL.path;
    
    // Set per-tweak resource path
    NSString *previousTweakResourcePath = gCurrentTweakResourcePath;
    gCurrentTweakResourcePath = tweakResourceBasePath;
    
    if ([tweakPath hasSuffix:@".framework"]) {
        NSURL* infoPlistURL = [url URLByAppendingPathComponent:@"Info.plist"];
        NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
        NSString* binary = infoDict[@"CFBundleExecutable"];
        if(!binary || ![binary isKindOfClass:NSString.class]) {
            gCurrentTweakResourcePath = previousTweakResourcePath;
            return [NSString stringWithFormat:@"Unable to load %@: Unable to read Info.Plist", tweak];
        }
        tweakPath = [[url URLByAppendingPathComponent:binary] path];
    }
    
    void *handle = dlopen(tweakPath.UTF8String, RTLD_LAZY | RTLD_GLOBAL);
    const char *error = dlerror();
    
    // Restore previous tweak resource path
    gCurrentTweakResourcePath = previousTweakResourcePath;
    
    if (handle) {
        NSLog(@"Loaded tweak %@", tweak);
        return nil;
    } else if (error) {
        NSLog(@"Error: %s", error);
        if (sourceContext.length > 0) {
            return [NSString stringWithFormat:@"[%@] %s", sourceContext, error];
        }
        return @(error);
    } else {
        NSLog(@"Error: dlopen(%@): Unknown error because dlerror() returns NULL", tweak);
        NSString *baseError = [NSString stringWithFormat:@"dlopen(%@): unknown error, handle is NULL", tweakPath];
        if (sourceContext.length > 0) {
            return [NSString stringWithFormat:@"[%@] %@", sourceContext, baseError];
        }
        return baseError;
    }
}

static BOOL loadTweaksUsingPackageMetadata(NSURL *folderURL, NSMutableArray *errors) {
    NSURL *metadataURL = [folderURL URLByAppendingPathComponent:kLCPackageMetadataFileName];
    NSData *metadataData = [NSData dataWithContentsOfURL:metadataURL];
    if (!metadataData) {
        return NO;
    }
    NSError *error = nil;
    NSDictionary *metadata = [NSJSONSerialization JSONObjectWithData:metadataData options:0 error:&error];
    if (error || ![metadata isKindOfClass:NSDictionary.class]) {
        [errors addObject:[NSString stringWithFormat:@"[%@] Invalid package metadata", folderURL.lastPathComponent]];
        return YES;
    }
    NSArray *artifacts = metadata[@"loadableArtifacts"];
    if (![artifacts isKindOfClass:NSArray.class]) {
        [errors addObject:[NSString stringWithFormat:@"[%@] Missing loadableArtifacts in package metadata", folderURL.lastPathComponent]];
        return YES;
    }
    for (id relativePath in artifacts) {
        if (![relativePath isKindOfClass:NSString.class]) {
            continue;
        }
        if (!isSafeArtifactRelativePath(relativePath)) {
            [errors addObject:[NSString stringWithFormat:@"[%@] Unsafe artifact path %@", folderURL.lastPathComponent, relativePath]];
            continue;
        }
        NSURL *artifactURL = [folderURL URLByAppendingPathComponent:relativePath];
        if (![NSFileManager.defaultManager fileExistsAtPath:artifactURL.path]) {
            [errors addObject:[NSString stringWithFormat:@"[%@] Missing artifact %@", folderURL.lastPathComponent, relativePath]];
            continue;
        }
        NSString *loadError = loadTweakAtURL(artifactURL, folderURL.lastPathComponent);
        if (loadError) {
            [errors addObject:loadError];
        }
    }
    return YES;
}

static void loadTweaksRecursively(NSURL *folderURL, NSURL *rootFolderURL, NSMutableArray *errors) {
    if (loadTweaksUsingPackageMetadata(folderURL, errors)) {
        return;
    }
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folderURL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 error:nil];
    for (NSURL *fileURL in items) {
        NSString *name = fileURL.lastPathComponent;
        if ([name hasSuffix:@".disabled"]) {
            NSLog(@"Skipping disabled tweak %@", name);
            continue;
        }
        if (isTweakURLDisabled(fileURL, rootFolderURL)) {
            NSLog(@"Skipped disabled tweak %@", name);
            continue;
        }
        NSNumber *isDirectory = nil;
        [fileURL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
        // a .framework is a directory but loads as a single tweak
        if (isDirectory.boolValue && ![name hasSuffix:@".framework"]) {
            loadTweaksRecursively(fileURL, rootFolderURL, errors);
        } else {
            NSString *error = loadTweakAtURL(fileURL, folderURL.lastPathComponent);
            if (error) {
                [errors addObject:error];
            }
        }
    }
}

static void showDlerrAlert(NSString *error) {
    UIWindow *window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Failed to load tweaks" message:error preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        window.windowScene = nil;
    }];
    [alert addAction:okAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleCancel handler:^(UIAlertAction * action) {
        UIPasteboard.generalPasteboard.string = error;
        window.windowScene = nil;
    }];
    [alert addAction:cancelAction];
    window.rootViewController = [UIViewController new];
    window.windowLevel = 1000;
    window.windowScene = (id)UIApplication.sharedApplication.connectedScenes.anyObject;
    [window makeKeyAndVisible];
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
    objc_setAssociatedObject(alert, @"window", window, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Path redirection helpers
static inline BOOL pathStartsWithSystemLibraryPath(NSString *path) {
    if (!path || path.length == 0) return NO;
    
    // Check for common system library paths that tweaks might look for resources in
    if ([path hasPrefix:@"/Library/Application Support/"]) return YES;
    if ([path hasPrefix:@"/Library/PreferenceBundles/"]) return YES;
    if ([path hasPrefix:@"/Library/MobileSubstrate/DynamicLibraries/"]) return YES;
    if ([path hasPrefix:@"/Library/Switches/"]) return YES;
    if ([path hasPrefix:@"/Library/LaunchDaemons/"]) return YES;
    if ([path hasPrefix:@"/Library/LaunchAgents/"]) return YES;
    if ([path hasPrefix:@"/Library/PreferenceLoader/Preferences/"]) return YES;
    if ([path hasPrefix:@"/Library/Widgets/"]) return YES;
    if ([path hasPrefix:@"/Library/Application Support/"]) return YES;
    if ([path hasPrefix:@"/Library/Themes/"]) return YES;
    if ([path hasPrefix:@"/Library/ControlCenter/"]) return YES;
    if ([path hasPrefix:@"/Library/BulletinBoard/"]) return YES;
    if ([path hasPrefix:@"/Library/IntroScreen/"]) return YES;
    if ([path hasPrefix:@"/Library/Keyboard/"]) return YES;
    if ([path hasPrefix:@"/Library/QuickLook/"]) return YES;
    if ([path hasPrefix:@"/Library/ScreenSavers/"]) return YES;
    if ([path hasPrefix:@"/Library/Spotlight/"]) return YES;
    if ([path hasPrefix:@"/Library/Widgets/"]) return YES;
    if ([path hasPrefix:@"/Library/Frameworks/"]) return YES;
    return NO;
}

static NSString* redirectTweakResourcePath(NSString *originalPath) {
    if (!pathStartsWithSystemLibraryPath(originalPath)) {
        return originalPath;
    }
    
    // Try current tweak resource path first (per-tweak)
    if (gCurrentTweakResourcePath) {
        NSString *tweakPath = [gCurrentTweakResourcePath stringByAppendingPathComponent:originalPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:tweakPath]) {
            return tweakPath;
        }
    }
    
    // Try container tweak path
    if (gContainerTweakPath) {
        NSString *containerPath = [gContainerTweakPath stringByAppendingPathComponent:originalPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:containerPath]) {
            return containerPath;
        }
    }
    
    // Try global tweak path
    if (gGlobalTweakPath) {
        NSString *globalPath = [gGlobalTweakPath stringByAppendingPathComponent:originalPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:globalPath]) {
            return globalPath;
        }
    }
    
    // Fall back to original path
    return originalPath;
}

// NSBundle hooks for path redirection
@implementation NSBundle (TweakPathRedirection)

- (NSString*)hook_pathForResource:(NSString*)name ofType:(NSString*)ext {
    NSString *path = [self hook_pathForResource:name ofType:ext];
    if (path) {
        return redirectTweakResourcePath(path);
    }
    return path;
}

- (NSString*)hook_pathForResource:(NSString*)name ofType:(NSString*)ext inDirectory:(NSString*)subpath {
    NSString *path = [self hook_pathForResource:name ofType:ext inDirectory:subpath];
    if (path) {
        return redirectTweakResourcePath(path);
    }
    return path;
}

- (NSString*)hook_bundlePath {
    NSString *path = [self hook_bundlePath];
    if (path) {
        return redirectTweakResourcePath(path);
    }
    return path;
}

- (NSString*)hook_resourcePath {
    NSString *path = [self hook_resourcePath];
    if (path) {
        return redirectTweakResourcePath(path);
    }
    return path;
}

- (NSURL*)hook_bundleURL {
    NSURL *url = [self hook_bundleURL];
    if (url) {
        NSString *path = [url path];
        NSString *redirected = redirectTweakResourcePath(path);
        if (![redirected isEqualToString:path]) {
            return [NSURL fileURLWithPath:redirected];
        }
    }
    return url;
}

- (NSURL*)hook_resourceURL {
    NSURL *url = [self hook_resourceURL];
    if (url) {
        NSString *path = [url path];
        NSString *redirected = redirectTweakResourcePath(path);
        if (![redirected isEqualToString:path]) {
            return [NSURL fileURLWithPath:redirected];
        }
    }
    return url;
}

- (NSArray<NSString*>*)hook_pathsForResourcesOfType:(NSString*)ext inDirectory:(NSString*)subpath {
    NSArray *paths = [self hook_pathsForResourcesOfType:ext inDirectory:subpath];
    if (paths) {
        NSMutableArray *redirected = [NSMutableArray arrayWithCapacity:paths.count];
        for (NSString *path in paths) {
            [redirected addObject:redirectTweakResourcePath(path)];
        }
        return redirected;
    }
    return paths;
}

@end

// NSFileManager hooks for path redirection
@implementation NSFileManager (TweakPathRedirection)

- (BOOL)hook_fileExistsAtPath:(NSString*)path {
    NSString *redirected = redirectTweakResourcePath(path);
    return [self hook_fileExistsAtPath:redirected];
}

- (BOOL)hook_fileExistsAtPath:(NSString*)path isDirectory:(BOOL*)isDirectory {
    NSString *redirected = redirectTweakResourcePath(path);
    return [self hook_fileExistsAtPath:redirected isDirectory:isDirectory];
}

- (NSDictionary<NSString*,id>*)hook_attributesOfItemAtPath:(NSString*)path error:(NSError**)error {
    NSString *redirected = redirectTweakResourcePath(path);
    return [self hook_attributesOfItemAtPath:redirected error:error];
}

- (NSArray<NSString*>*)hook_contentsOfDirectoryAtPath:(NSString*)path error:(NSError**)error {
    NSString *redirected = redirectTweakResourcePath(path);
    return [self hook_contentsOfDirectoryAtPath:redirected error:error];
}

- (NSDirectoryEnumerator<NSURL*>*)hook_enumeratorAtPath:(NSString*)path {
    NSString *redirected = redirectTweakResourcePath(path);
    return [self hook_enumeratorAtPath:redirected];
}

- (BOOL)hook_removeItemAtPath:(NSString*)path error:(NSError**)error {
    NSString *redirected = redirectTweakResourcePath(path);
    // Try redirected path first, then original
    if (![redirected isEqualToString:path] && [NSFileManager.defaultManager fileExistsAtPath:redirected]) {
        return [self hook_removeItemAtPath:redirected error:error];
    }
    return [self hook_removeItemAtPath:path error:error];
}

@end

static void installPathRedirectionHooks(void) {
    // Hook NSBundle methods
    swizzle(NSBundle.class, @selector(pathForResource:ofType:), @selector(hook_pathForResource:ofType:));
    swizzle(NSBundle.class, @selector(pathForResource:ofType:inDirectory:), @selector(hook_pathForResource:ofType:inDirectory:));
    swizzle(NSBundle.class, @selector(bundlePath), @selector(hook_bundlePath));
    swizzle(NSBundle.class, @selector(resourcePath), @selector(hook_resourcePath));
    swizzle(NSBundle.class, @selector(bundleURL), @selector(hook_bundleURL));
    swizzle(NSBundle.class, @selector(resourceURL), @selector(hook_resourceURL));
    swizzle(NSBundle.class, @selector(pathsForResourcesOfType:inDirectory:), @selector(hook_pathsForResourcesOfType:inDirectory:));
    
    // Hook NSFileManager methods
    swizzle(NSFileManager.class, @selector(fileExistsAtPath:), @selector(hook_fileExistsAtPath:));
    swizzle(NSFileManager.class, @selector(fileExistsAtPath:isDirectory:), @selector(hook_fileExistsAtPath:isDirectory:));
    swizzle(NSFileManager.class, @selector(attributesOfItemAtPath:error:), @selector(hook_attributesOfItemAtPath:error:));
    swizzle(NSFileManager.class, @selector(contentsOfDirectoryAtPath:error:), @selector(hook_contentsOfDirectoryAtPath:error:));
    swizzle(NSFileManager.class, @selector(enumeratorAtPath:), @selector(hook_enumeratorAtPath:));
    // NOTE: createDirectoryAtPath:withIntermediateDirectories:attributes:error: is intentionally NOT
    // swizzled here. NSFileManager+GuestHooks.m (NSFMGuestHooksInit, called from LCBootstrap during
    // guest process bootstrap) already swizzles this exact selector for the WebKit cookies-folder
    // workaround. Swizzling it a second time here double-exchanges the same pair of IMPs, which
    // un-does the first swap and leaves `hook_createDirectoryAtPath:...` pointing at itself. The
    // old passthrough version of this hook (which did nothing but call itself, since it never even
    // called redirectTweakResourcePath) then recursed into itself forever the first time anything
    // (e.g. CFNetwork's HTTP alt-services SQLite store) called -createDirectoryAtPath:..., overflowing
    // the stack and crashing with SIGBUS "Could not determine thread index for stack guard region".
    // This hook never redirected anything anyway, so it's removed rather than renamed.
    swizzle(NSFileManager.class, @selector(removeItemAtPath:error:), @selector(hook_removeItemAtPath:error:));
    
    NSLog(@"[TweakLoader] Path redirection hooks installed");
}

// C-level file access hooks
static int (*orig_open)(const char *path, int oflag, ...);
static int (*orig_openat)(int fd, const char *path, int oflag, ...);
static int (*orig_stat)(const char *path, struct stat *buf);
static int (*orig_lstat)(const char *path, struct stat *buf);
static int (*orig_fstat)(int fd, struct stat *buf);
static int (*orig_access)(const char *path, int amode);
static FILE* (*orig_fopen)(const char *path, const char *mode);
static char* (*orig_realpath)(const char *path, char *resolved_path);

static inline const char* redirectCPath(const char *path) {
    if (!path) return path;
    
    NSString *nsPath = @(path);
    if (!pathStartsWithSystemLibraryPath(nsPath)) {
        return path;
    }
    
    // Try current tweak resource path first (per-tweak)
    if (gCurrentTweakResourcePath) {
        NSString *tweakPath = [gCurrentTweakResourcePath stringByAppendingPathComponent:nsPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:tweakPath]) {
            return tweakPath.UTF8String;
        }
    }
    
    // Try container tweak path first
    if (gContainerTweakPath) {
        NSString *containerPath = [gContainerTweakPath stringByAppendingPathComponent:nsPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:containerPath]) {
            return containerPath.UTF8String;
        }
    }
    
    // Try global tweak path
    if (gGlobalTweakPath) {
        NSString *globalPath = [gGlobalTweakPath stringByAppendingPathComponent:nsPath];
        if ([NSFileManager.defaultManager fileExistsAtPath:globalPath]) {
            return globalPath.UTF8String;
        }
    }
    
    return path;
}

static int hook_open(const char *path, int oflag, ...) {
    const char *redirected = redirectCPath(path);
    va_list ap;
    va_start(ap, oflag);
    int result = orig_open(redirected, oflag, va_arg(ap, mode_t));
    va_end(ap);
    return result;
}

static int hook_openat(int fd, const char *path, int oflag, ...) {
    const char *redirected = redirectCPath(path);
    va_list ap;
    va_start(ap, oflag);
    int result = orig_openat(fd, redirected, oflag, va_arg(ap, mode_t));
    va_end(ap);
    return result;
}

static int hook_stat(const char *path, struct stat *buf) {
    const char *redirected = redirectCPath(path);
    return orig_stat(redirected, buf);
}

static int hook_lstat(const char *path, struct stat *buf) {
    const char *redirected = redirectCPath(path);
    return orig_lstat(redirected, buf);
}

static int hook_fstat(int fd, struct stat *buf) {
    // fstat uses file descriptor, no path to redirect
    return orig_fstat(fd, buf);
}

static int hook_access(const char *path, int amode) {
    const char *redirected = redirectCPath(path);
    return orig_access(redirected, amode);
}

static FILE* hook_fopen(const char *path, const char *mode) {
    const char *redirected = redirectCPath(path);
    return orig_fopen(redirected, mode);
}

static char* hook_realpath(const char *path, char *resolved_path) {
    const char *redirected = redirectCPath(path);
    return orig_realpath(redirected, resolved_path);
}

static void installCFileHooks(void) {
    // Hook C file functions using litehook. litehook_rebind_symbol's 4th
    // parameter is an exceptionFilter callback (bool(*)(const mach_header_u*)),
    // not an out-parameter for the original implementation — grab the real
    // implementation via dlsym before installing each global rebind.
    orig_open = dlsym(RTLD_DEFAULT, "open");
    orig_openat = dlsym(RTLD_DEFAULT, "openat");
    orig_stat = dlsym(RTLD_DEFAULT, "stat");
    orig_lstat = dlsym(RTLD_DEFAULT, "lstat");
    orig_fstat = dlsym(RTLD_DEFAULT, "fstat");
    orig_access = dlsym(RTLD_DEFAULT, "access");
    orig_fopen = dlsym(RTLD_DEFAULT, "fopen");
    orig_realpath = dlsym(RTLD_DEFAULT, "realpath");

    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, open, hook_open, NULL);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, openat, hook_openat, NULL);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, stat, hook_stat, NULL);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, lstat, hook_lstat, NULL);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, fstat, hook_fstat, NULL);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, access, hook_access, NULL);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, fopen, hook_fopen, NULL);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, realpath, hook_realpath, NULL);
    
    NSLog(@"[TweakLoader] C file access hooks installed");
}

 __attribute__((constructor))
static void TweakLoaderConstructor() {
    // As early as possible -- before AppNest's own hooks and before any
    // third-party tweak (e.g. a game's own cheat/mod dylib) gets a chance to
    // install anything -- see LCDebugLog.h.
    LCDebugLogInstall(@"guest");
    NSDictionary *guestContainerInfo = [NSUserDefaults guestContainerInfo];
    strictTestModeEnabled = [guestContainerInfo[@"strictTestMode"] boolValue];
    strictAutoWipeOnExitEnabled = strictTestModeEnabled && [guestContainerInfo[@"strictAutoWipeOnExit"] boolValue];
    if(strictAutoWipeOnExitEnabled) {
        const char *homeEnv = getenv("HOME");
        if(homeEnv) {
            strictContainerHomePath = [NSString stringWithUTF8String:homeEnv];
            LCStrictRecoverStaleSessionIfNeeded();
            LCStrictWriteSessionMarker(strictContainerHomePath);
            LCStrictRegisterLifecycleObservers();
            atexit(LCStrictAutoWipeOnExit);
        }
    }

    const char *tweakFolderC = getenv("LC_GLOBAL_TWEAKS_FOLDER");
    const char *globalTweakPathC = getenv("LC_GLOBAL_TWEAKS_PATH");
    const char *containerTweakPathC = getenv("LC_CONTAINER_TWEAK_PATH");
    const char *tweakFolderNameC = getenv("LC_TWEAK_FOLDER_NAME");
    
    NSString *globalTweakFolder = @(tweakFolderC);
    if (globalTweakPathC) {
        gGlobalTweakPath = @(globalTweakPathC);
    } else {
        gGlobalTweakPath = globalTweakFolder;
    }
    if (containerTweakPathC) {
        gContainerTweakPath = @(containerTweakPathC);
    }
    if (tweakFolderNameC) {
        gTweakFolderName = @(tweakFolderNameC);
    }
    
    unsetenv("LC_GLOBAL_TWEAKS_FOLDER");
    unsetenv("LC_GLOBAL_TWEAKS_PATH");
    unsetenv("LC_CONTAINER_TWEAK_PATH");
    unsetenv("LC_TWEAK_FOLDER_NAME");
    
    // Install path redirection hooks early
    installPathRedirectionHooks();
    installCFileHooks();
    
    if([NSUserDefaults.guestAppInfo[@"dontInjectTweakLoader"] boolValue]) {
        // don't load any tweak since tweakloader is loaded after all initializers
        NSLog(@"Skip loading tweaks");
        return;
    }
    
    NSMutableArray *errors = [NSMutableArray new];
    
    NSArray<NSURL *> *globalTweaks = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:globalTweakFolder]
    includingPropertiesForKeys:@[] options:0 error:nil];
    NSString *tweakFolderName = gTweakFolderName ?: NSUserDefaults.guestAppInfo[@"LCTweakFolder"];
    
    if([globalTweaks count] <= 1 && tweakFolderName.length == 0) {
        // nothing to load
        return;
    }

    // Load CydiaSubstrate
    const char *lcMainBundlePath;
    if(NSUserDefaults.isLiveProcess) {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.fileSystemRepresentation;
    } else {
        lcMainBundlePath = NSUserDefaults.lcMainBundle.bundlePath.fileSystemRepresentation;
    }
    char substratePath[PATH_MAX];
    snprintf(substratePath, sizeof(substratePath), "%s/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", lcMainBundlePath);
    dlopen(substratePath, RTLD_LAZY | RTLD_GLOBAL);
    const char *substrateError = dlerror();
    if (substrateError) {
        [errors addObject:@(substrateError)];
    }

    // Load global tweaks
    NSLog(@"Loading tweaks from the global folder");

    for (NSURL *fileURL in globalTweaks) {
        NSString *name = fileURL.lastPathComponent;
        if ([name isEqualToString:@"TweakLoader.dylib"]) {
            // skip loading myself
            continue;
        }
        if (isTweakURLDisabled(fileURL, [NSURL fileURLWithPath:globalTweakFolder])) {
            NSLog(@"Skipped disabled tweak %@", fileURL.lastPathComponent);
            continue;
        }
        NSString *error = loadTweakAtURL(fileURL, @"global");
        if (error) {
            [errors addObject:error];
        }
    }

    // Load selected tweak folder, recursively
    if (tweakFolderName.length > 0) {
        NSLog(@"Loading tweaks from the selected folder");
        NSString *tweakFolder = gContainerTweakPath ?: [globalTweakFolder stringByAppendingPathComponent:tweakFolderName];
        loadTweaksRecursively([NSURL fileURLWithPath:tweakFolder], [NSURL fileURLWithPath:tweakFolder], errors);
    }

    if (errors.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *error = [errors componentsJoinedByString:@"\n"];
            showDlerrAlert(error);
        });
    }
}
