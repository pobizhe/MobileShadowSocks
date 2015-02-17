/*
 *    Shadowsocks per-app plugin
 *    Copyright (c) 2014 Linus Yang
 *
 *    This program is free software: you can redistribute it and/or modify
 *    it under the terms of the GNU General Public License as published by
 *    the Free Software Foundation, either version 3 of the License, or
 *    (at your option) any later version.
 *
 *    This program is distributed in the hope that it will be useful,
 *    but WITHOUT ANY WARRANTY; without even the implied warranty of
 *    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *    GNU General Public License for more details.
 *
 *    You should have received a copy of the GNU General Public License
 *    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 */

#include <UIKit/UIKit.h>
#include "libfinder/LFFinderController.h"
#define ROCKETBOOTSTRAP_LOAD_DYNAMIC
#import "rocket/rocketbootstrap.h"
#import <AppSupport/CPDistributedMessagingCenter.h>
#import <mach-o/dyld.h>

#ifndef kCFCoreFoundationVersionNumber_iOS_8_0
#define kCFCoreFoundationVersionNumber_iOS_8_0 1140.10
#endif

#define SYSTEM_GE_IOS_8() (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_8_0)

#define DECL_FUNC(name, ret, ...) \
    static ret (*original_ ## name)(__VA_ARGS__); \
    ret custom_ ## name(__VA_ARGS__)
#define HOOK_FUNC(name, image) do { \
    void *_ ## name = MSFindSymbol(image, "_" #name); \
    if (_ ## name == NULL) { \
        LOG(@"Failed to load symbol: " #name "."); \
        return; \
    } \
    MSHookFunction(_ ## name, (void *) custom_ ## name, (void **) &original_ ## name); \
    LOG("interposed " #name); \
} while(0)
#define HOOK_SIMPLE(name) do { \
    MSHookFunction(name, (void *) custom_ ## name, (void **) &original_ ## name); \
    LOG("interposed " #name); \
} while(0)
#define LOAD_IMAGE(image, path) do { \
    image = MSGetImageByName(path); \
    if (image == NULL) { \
        LOG(@"Failed to load " #image "."); \
        return; \
    } \
} while (0)

typedef const struct __SCDynamicStore *SCDynamicStoreRef;
typedef const void *MSImageRef;
MSImageRef MSGetImageByName(const char *file);
void *MSFindSymbol(MSImageRef image, const char *name);
void MSHookFunction(void *symbol, void *replace, void **result);

#define PC_PATH_DEFAULT "/Applications/MobileShadowSocks.app/proxychains.conf"
#include "proxychains/common.h"

typedef union {
    unsigned char octet[4];
    uint32_t as_int;
} ip_type;

typedef enum {
    HTTP_TYPE,
    SOCKS4_TYPE,
    SOCKS5_TYPE
} proxy_type;

typedef enum {
    PLAY_STATE,
    DOWN_STATE,
    BLOCKED_STATE,
    BUSY_STATE
} proxy_state;

typedef struct {
    ip_type ip;
    unsigned short port;
    proxy_type pt;
    proxy_state ps;
    char user[256];
    char pass[256];
} proxy_data;

char proxychains_conf_path[PROXYCHAINS_MAX_PATH];
void activateProxyChains(void);
extern int proxychains_resolver;
extern int proxychains_default_port;
extern proxy_data proxychains_pd[MAX_CHAIN];

#ifdef DEBUG
#define LOG(...) NSLog(@"SSPerApp: " __VA_ARGS__)
#else
#define LOG(...)
#endif

static BOOL pluginEnabled = NO;
static BOOL proxyEnabled = NO;
static BOOL spdyDisabled = YES;
static BOOL finderEnabled = YES;
static BOOL removeBadge = NO;
static BOOL useProxyChains = NO;
static BOOL isMediaServer = NO;

#define DEFAULT_PORT 1983
static int proxyPort = DEFAULT_PORT;

static BOOL getValue(NSDictionary *dict, NSString *key, BOOL defaultVal)
{
    if (dict == nil || key == nil) {
        return defaultVal;
    }
    NSNumber *valObj = [dict objectForKey:key];
    if (valObj == nil) {
        return defaultVal;
    }
    return [valObj boolValue];
}

static int getIntValue(NSDictionary *dict, NSString *key, int defaultVal)
{
    if (dict == nil || key == nil) {
        return defaultVal;
    }
    NSString *valObj = [dict objectForKey:key];
    if (valObj == nil) {
        return defaultVal;
    }
    return [valObj intValue];
}

static void addPrefSetting(NSMutableDictionary *response, CFStringRef prefIdentifier)
{
    CFArrayRef keyList = CFPreferencesCopyKeyList(prefIdentifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keyList == NULL) {
        return;
    }
    NSDictionary *preferences = (NSDictionary *) CFPreferencesCopyMultiple(keyList, prefIdentifier, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(keyList);
    if (preferences) {
        [response addEntriesFromDictionary:preferences];
        [preferences release];
    }
}

static NSDictionary *prefDictionary(void)
{
    if (SYSTEM_GE_IOS_8()) {
        CPDistributedMessagingCenter *center = [CPDistributedMessagingCenter centerNamed:@"com.linusyang.sspref"];
        rocketbootstrap_distributedmessagingcenter_apply(center);
        return [center sendMessageAndReceiveReplyName:@"com.linusyang.sspref.fetch" userInfo:nil];
    } else {
        return [[[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.linusyang.ssperapp.plist"] autorelease];
    }
}

static void checkAndDisableGlobalProxy(void)
{
    CFDictionaryRef proxyDict = CFNetworkCopySystemProxySettings();
    BOOL pacEnabled = [[(NSDictionary *) proxyDict objectForKey:@"ProxyAutoConfigEnable"] boolValue];
    BOOL socksEnabled = [[(NSDictionary *) proxyDict objectForKey:@"SOCKSEnable"] boolValue];
    CFRelease(proxyDict);

    // Exit if already disabled
    if (!(pacEnabled || socksEnabled)) {
        return;
    }

    // Disable global proxy
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:1993/proxy.pac"]];
    [request setValue:@"True" forHTTPHeaderField:@"SetProxy-None"];
    [request setTimeoutInterval:3.0];
    for (int i = 0; i < 5; i++) {
        NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:nil error:nil];
        if (data == nil) {
            continue;
        }
        NSString *str = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if ([str hasPrefix:@"Updated."]) {
            LOG("Global proxy disabled");
            break;
        } else if ([str hasPrefix:@"Failed."]) {
            LOG("Failed to disable global proxy");
            break;
        }
    }
}

static void updateSettings(void)
{
    @autoreleasepool {
        pluginEnabled = NO;
        spdyDisabled = YES;
        finderEnabled = YES;
        removeBadge = NO;
        proxyEnabled = !SYSTEM_GE_IOS_8();

        NSDictionary *dict = nil;
        if (SYSTEM_GE_IOS_8()) {
            const char *path = _dyld_get_image_name(0);
            NSString *imagePath = path ? [NSString stringWithUTF8String:path] : @"unknown";
            BOOL isApp = [imagePath hasPrefix:@"/private/var/db/stash"] || [imagePath hasPrefix:@"/private/var/mobile"];
            if (isApp) {
                dict = prefDictionary();
            } else {
                dict = [NSMutableDictionary dictionary];
                addPrefSetting((NSMutableDictionary *) dict, CFSTR("com.linusyang.ssperapp"));
            }
        } else {
            dict = prefDictionary();
        }

        LOG(@"%@ update settings: %@", imagePath, dict);
        if (dict != nil) {
            pluginEnabled = getValue(dict, @"SSPerAppEnabled", NO);
            spdyDisabled = getValue(dict, @"SSPerAppDisableSPDY", YES);
            finderEnabled = getValue(dict, @"SSPerAppFinder", YES);
            removeBadge = getValue(dict, @"SSPerAppNoBadge", NO);
            if (pluginEnabled) {
                proxyPort = getIntValue(dict, @"SSPerAppSocksPort", DEFAULT_PORT);
                if (proxyPort <= 0 || proxyPort > 65535) {
                    proxyPort = DEFAULT_PORT;
                }
                LOG("Using proxy port: %d", proxyPort);
                if (isMediaServer) {
                    proxyEnabled = getValue(dict, @"SSPerAppVideo", NO);
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        checkAndDisableGlobalProxy();
                    });
                    return;
                }
                NSString *bundleName = [[NSBundle mainBundle] bundleIdentifier];              
                if (bundleName != nil) {
                    NSString *entry = [[NSString alloc] initWithFormat:@"Enabled-%@", bundleName];
                    if ([bundleName hasPrefix:@"com.apple.WebKit"]) {
                        proxyEnabled = getValue(dict, @"Enabled-com.apple.mobilesafari", NO);
                    } else {
                        proxyEnabled = getValue(dict, entry, NO);
                    }
                    if (getValue(dict, @"SSPerAppReversed", NO)) {
                        proxyEnabled = !proxyEnabled;
                    }
                    [entry release];
                }
                if (useProxyChains) {
                    proxychains_resolver = proxyEnabled ? 1 : 0;
                    proxychains_default_port = proxyPort;
                    proxychains_pd[0].port = htons((unsigned short) proxyPort);
                }
            }
        }
    }
}

static void listenSettingChanges(void)
{
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback) updateSettings, CFSTR("com.linusyang.ssperapp.settingschanged"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}

static CFDictionaryRef copyEmptyProxyDict(void)
{
    CFMutableDictionaryRef proxyDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int zero = 0;
    CFNumberRef zeroNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &zero);
    CFDictionarySetValue(proxyDict, CFSTR("HTTPEnable"), zeroNumber);
    CFDictionarySetValue(proxyDict, CFSTR("HTTPProxyType"), zeroNumber);
    CFDictionarySetValue(proxyDict, CFSTR("HTTPSEnable"), zeroNumber);
    CFDictionarySetValue(proxyDict, CFSTR("ProxyAutoConfigEnable"), zeroNumber);
    CFRelease(zeroNumber);
    return proxyDict;
}

static CFDictionaryRef copySocksProxyDict(void)
{
    CFMutableDictionaryRef proxyDict = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int port = proxyPort;
    CFNumberRef portNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &port);
    CFDictionarySetValue(proxyDict, kCFStreamPropertySOCKSProxyHost, CFSTR("127.0.0.1"));
    CFDictionarySetValue(proxyDict, kCFStreamPropertySOCKSProxyPort, portNumber);
    CFDictionarySetValue(proxyDict, kCFStreamPropertySOCKSVersion, kCFStreamSocketSOCKSVersion5);
    CFRelease(portNumber);
    return proxyDict;
}

DECL_FUNC(SCDynamicStoreCopyProxies, CFDictionaryRef, SCDynamicStoreRef store)
{
    CFDictionaryRef result;
    if (proxyEnabled) {
        result = original_SCDynamicStoreCopyProxies(store);
    } else {
        result = copyEmptyProxyDict();
    }
    return result;
}

DECL_FUNC(CFReadStreamOpen, Boolean, CFReadStreamRef stream)
{
    if (proxyEnabled && stream != NULL) {
        CFDictionaryRef socksConfig = copySocksProxyDict();
        CFReadStreamSetProperty(stream, kCFStreamPropertySOCKSProxy, socksConfig);
        CFRelease(socksConfig);
    }
    return original_CFReadStreamOpen(stream);
}

DECL_FUNC(CFWriteStreamOpen, Boolean, CFWriteStreamRef stream)
{
    if (proxyEnabled && stream != NULL) {
        CFDictionaryRef socksConfig = copySocksProxyDict();
        CFWriteStreamSetProperty(stream, kCFStreamPropertySOCKSProxy, socksConfig);
        CFRelease(socksConfig);
    }
    return original_CFWriteStreamOpen(stream);
}

@interface SettingTableViewController <LFFinderActionDelegate>

- (BOOL)useLibFinder;
- (UIViewController *)allocFinderController;
- (void)finderSelectedFilePath:(NSString *)path checkSanity:(BOOL)check;

@end

typedef enum {
    kProxyOperationDisableProxy = 0,
    kProxyOperationEnableSocks,
    kProxyOperationEnablePac,
    kProxyOperationUpdateConf,
    kProxyOperationForceStop,
    
    kProxyOperationCount
} ProxyOperation;

typedef enum {
    kProxyOperationSuccess = 0,
    kProxyOperationError
} ProxyOperationStatus;

@interface ProxyManager : NSObject
- (ProxyOperation)_currentProxyOperation;
@end

%group ShadowHook

%hook SettingTableViewController
- (BOOL)useLibFinder
{
    return finderEnabled;
}

- (UIViewController *)allocFinderController
{
    LFFinderController* finder = [[LFFinderController alloc] initWithMode:LFFinderModeDefault];
    finder.actionDelegate = self;
    return finder;
}

- (void)setBadge:(BOOL)enabled
{
    if (removeBadge) {
        enabled = NO;
    }
    %orig;
}

%new
-(void)finder:(LFFinderController*)finder didSelectItemAtPath:(NSString*)path
{
    [self finderSelectedFilePath:path checkSanity:NO];
}
%end

%hook ProxyManager
- (ProxyOperationStatus)_sendProxyOperation:(ProxyOperation)op updateOnlyChanged:(BOOL)updateOnlyChanged
{
    if (SYSTEM_GE_IOS_8() && pluginEnabled && op <= kProxyOperationEnablePac) {
        if ([self _currentProxyOperation] == kProxyOperationDisableProxy) {
            return kProxyOperationSuccess;
        }
        op = kProxyOperationDisableProxy;
    }
    return %orig;
}
%end

%end

%group TwitterHook

%hook T1SPDYConfigurationChangeListener 
- (BOOL)_shouldEnableSPDY
{
    if (spdyDisabled) {
        return NO;
    } else {
        return %orig;
    }
}
%end

%end

%group FacebookHook

%hook FBRequester
- (BOOL)allowSPDY
{
    if (spdyDisabled) {
        return NO;
    } else {
        return %orig;
    }
}

- (BOOL)spdyEnabled
{
    if (spdyDisabled) {
        return NO;
    } else {
        return %orig;
    }
}

- (BOOL)useDNSCache
{
    if (spdyDisabled) {
        return NO;
    } else {
        return %orig;
    }
}
%end

%hook FBNetworkerRequest
- (BOOL)disableSPDY
{
    if (spdyDisabled) {
        return YES;
    } else {
        return %orig;
    }
}
%end

%hook FBRequesterState
- (BOOL)didUseSPDY
{
    if (spdyDisabled) {
        return NO;
    } else {
        return %orig;
    }
}
%end

%hook FBAppConfigService
- (BOOL)disableDNSCache
{
    if (spdyDisabled) {
        return YES;
    } else {
        return %orig;
    }
}
%end

%hook FBNetworker
- (BOOL)_shouldAllowUseOfDNSCache:(id)arg
{
    if (spdyDisabled) {
        return NO;
    } else {
        return %orig;
    }
}
%end

%hook FBAppSessionController
- (BOOL)networkerShouldAllowUseOfDNSCache:(id)arg
{
    if (spdyDisabled) {
        return NO;
    } else {
        return %orig;
    }
}
%end

%end

%group SBService

%hook SpringBoard

- (id)init
{
    self = %orig;
    CPDistributedMessagingCenter *center = [CPDistributedMessagingCenter centerNamed:@"com.linusyang.sspref"];
    rocketbootstrap_distributedmessagingcenter_apply(center);
    [center registerForMessageName:@"com.linusyang.sspref.fetch" target:self selector:@selector(handleSSPerAppMessage:userInfo:)];
    [center runServerOnCurrentThread];
    return self;
}

%new
- (NSDictionary *)handleSSPerAppMessage:(NSString *)name userInfo:(NSDictionary *)userInfo
{
    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    addPrefSetting(response, CFSTR("com.linusyang.ssperapp"));
    return response;
}

%end

%end

%ctor
{
    @autoreleasepool {
        // Check bundle name
        NSString *bundleName = [[NSBundle mainBundle] bundleIdentifier];
        if (bundleName == nil) {
            LOG("not a bundled app, exit");
            return;
        }
        isMediaServer = [bundleName isEqualToString:@"com.apple.mediaserverd"];
        if (isMediaServer && !SYSTEM_GE_IOS_8()) {
            return;
        }
        LOG(@"hooking %@", bundleName);

        // iOS 8 settings
        if (SYSTEM_GE_IOS_8()) {
            // Springboard service init
            if ([bundleName isEqualToString:@"com.apple.springboard"]) {
                %init(SBService);
                return;
            }

            // Proxychains init
            proxychains_resolver = 0;
            strncpy(proxychains_conf_path, PC_PATH_DEFAULT, PROXYCHAINS_MAX_PATH - 1);
            proxychains_conf_path[PROXYCHAINS_MAX_PATH - 1] = '\0';
            if ([bundleName isEqualToString:@"com.google.chrome.ios"]) {
                useProxyChains = YES;
            }
        }

        // Update settings
        updateSettings();
        listenSettingChanges();

        // Hook special apps
        if ([bundleName isEqualToString:@"com.linusyang.MobileShadowSocks"]) {
            LOG("hook shadow app");
            %init(ShadowHook);
            return;
        }
        if ([bundleName isEqualToString:@"shadowsocks"]) {
            // Do nothing for App Store version shadowsocks
            return;
        }

        // Disable SPDY protocol
        if ([bundleName isEqualToString:@"com.atebits.Tweetie2"]) {
            LOG("hook twitter");
            %init(TwitterHook);
        } else if ([bundleName isEqualToString:@"com.facebook.Facebook"] ||
                   [bundleName isEqualToString:@"com.facebook.Messenger"]) {
            LOG("hook facebook");
            %init(FacebookHook);
        }

        // Deploy proxy hooks
        LOG("deploy proxy hooks");
        if (SYSTEM_GE_IOS_8()) {
            if (useProxyChains) {
                activateProxyChains();
            }
            HOOK_SIMPLE(CFReadStreamOpen);
            HOOK_SIMPLE(CFWriteStreamOpen);
        } else {
            MSImageRef image;
            LOAD_IMAGE(image, "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration");
            HOOK_FUNC(SCDynamicStoreCopyProxies, image);
        }
    }
}
