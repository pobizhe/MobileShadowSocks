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
void activateProxyChains(void);

#define PC_PATH_DEFAULT "/Applications/MobileShadowSocks.app/proxychains.conf"
#define PC_PATH_CHNROUTE "/Applications/MobileShadowSocks.app/proxychains_chnroute.conf"
#include "proxychains/common.h"
char proxychains_conf_path[PROXYCHAINS_MAX_PATH];

#ifdef DEBUG
#define LOG(...) NSLog(@"SSPerApp: " __VA_ARGS__)
#else
#define LOG(...)
#endif

static BOOL pluginEnabled = NO;
static BOOL proxyEnabled = YES;
static BOOL spdyDisabled = YES;
static BOOL finderEnabled = YES;
static BOOL useProxyChains = NO;
static BOOL bypassChina = NO;

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

static void updateSettings(void)
{
    @autoreleasepool {
        pluginEnabled = NO;
        proxyEnabled = YES;
        spdyDisabled = YES;
        finderEnabled = YES;
        useProxyChains = NO;
        bypassChina = NO;
        NSDictionary *dict = prefDictionary();
        if (dict != nil) {
            LOG(@"updating settings: %@", dict);
            pluginEnabled = getValue(dict, @"SSPerAppEnabled", NO);
            if (pluginEnabled) {
                useProxyChains = getValue(dict, @"SSPerAppUseProxyChains", NO);
                if (useProxyChains) {
                    proxyEnabled = NO;
                    bypassChina = getValue(dict, @"SSPerAppBypassChina", NO);
                    strncpy(proxychains_conf_path, bypassChina ? PC_PATH_CHNROUTE : PC_PATH_DEFAULT, PROXYCHAINS_MAX_PATH - 1);
                    proxychains_conf_path[PROXYCHAINS_MAX_PATH - 1] = '\0';
                }
                NSString *bundleName = [[NSBundle mainBundle] bundleIdentifier];
                if (bundleName != nil) {
                    LOG(@"my name is: %@", bundleName);
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
                spdyDisabled = getValue(dict, @"SSPerAppDisableSPDY", YES);
                finderEnabled = getValue(dict, @"SSPerAppFinder", YES);
            }
        } else {
            LOG("failed to update settings");
        }
    }
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
    int port = 1983;
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
    LOG(@"override SCDynamicStoreCopyProxies: %@", result);
    return result;
}

DECL_FUNC(CFReadStreamOpen, Boolean, CFReadStreamRef stream)
{
    if (proxyEnabled && stream != NULL) {
        CFDictionaryRef socksConfig = copySocksProxyDict();
        CFReadStreamSetProperty(stream, kCFStreamPropertySOCKSProxy, socksConfig);
        CFRelease(socksConfig);
    }
    LOG(@"override CFReadStreamOpen, proxyEnabled: %d", proxyEnabled);
    return original_CFReadStreamOpen(stream);
}

DECL_FUNC(CFWriteStreamOpen, Boolean, CFWriteStreamRef stream)
{
    if (proxyEnabled && stream != NULL) {
        CFDictionaryRef socksConfig = copySocksProxyDict();
        CFWriteStreamSetProperty(stream, kCFStreamPropertySOCKSProxy, socksConfig);
        CFRelease(socksConfig);
    }
    LOG(@"override CFWriteStreamOpen, proxyEnabled: %d", proxyEnabled);
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

%group FinderHook

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

%new
-(void)finder:(LFFinderController*)finder didSelectItemAtPath:(NSString*)path
{
    [self finderSelectedFilePath:path checkSanity:NO];
}
%end

%hook ProxyManager
- (ProxyOperationStatus)_sendProxyOperation:(ProxyOperation)op updateOnlyChanged:(BOOL)updateOnlyChanged
{
    if (useProxyChains && op <= kProxyOperationEnablePac) {
        if ([self _currentProxyOperation] == kProxyOperationDisableProxy) {
            return kProxyOperationSuccess;
        }
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
    LOG("registered: SSPerApp setting service");
    return self;
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

%new
- (NSDictionary *)handleSSPerAppMessage:(NSString *)name userInfo:(NSDictionary *)userInfo
{
    LOG("received: fetch SSPerApp settings message");
    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    addPrefSetting(response, CFSTR("com.linusyang.ssperapp"));
    return response;
}

%end

%end

%ctor
{
    @autoreleasepool {
        NSString *bundleName = [[NSBundle mainBundle] bundleIdentifier];
        if (bundleName == nil) {
            LOG("not a normal app, exit");
            return;
        }
        if (SYSTEM_GE_IOS_8() && [bundleName isEqualToString:@"com.apple.springboard"]) {
            %init(SBService);
        } else {
            updateSettings();
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback) updateSettings, CFSTR("com.linusyang.ssperapp.settingschanged"), NULL, CFNotificationSuspensionBehaviorCoalesce);
            if ([bundleName isEqualToString:@"com.linusyang.MobileShadowSocks"]) {
                LOG("hook shadow app");
                %init(FinderHook);
            } else if (![bundleName isEqualToString:@"shadowsocks"]) {
                if (pluginEnabled) {
                    if (useProxyChains) {
                        if (proxyEnabled) {
                            LOG("proxychains mode");
                            activateProxyChains();
                            HOOK_SIMPLE(CFReadStreamOpen);
                            HOOK_SIMPLE(CFWriteStreamOpen);
                        }
                    } else {
                        LOG("hook SCDynamicStoreCopyProxies");
                        MSImageRef image;
                        LOAD_IMAGE(image, "/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration");
                        HOOK_FUNC(SCDynamicStoreCopyProxies, image);
                    }
                }
                if ([bundleName isEqualToString:@"com.atebits.Tweetie2"]) {
                    LOG("hook twitter");
                    %init(TwitterHook);
                } else if ([bundleName isEqualToString:@"com.facebook.Facebook"] ||
                           [bundleName isEqualToString:@"com.facebook.Messenger"]) {
                    LOG("hook facebook");
                    %init(FacebookHook);
                }
            }
        }
    }
}
