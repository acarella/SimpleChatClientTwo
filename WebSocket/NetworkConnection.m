//
//  NetworkConnection.m
//
//  Copyright (C) 2013 IRCCloud, Ltd.
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.


#import "NetworkConnection.h"
#import "HandshakeHeader.h"
#import "IRCCloudJSONObject.h"

NSString *_userAgent = nil;
NSString *kIRCCloudConnectivityNotification = @"com.irccloud.notification.connectivity";
NSString *kIRCCloudEventNotification = @"com.irccloud.notification.event";
NSString *kIRCCloudBacklogStartedNotification = @"com.irccloud.notification.backlog.start";
NSString *kIRCCloudBacklogFailedNotification = @"com.irccloud.notification.backlog.failed";
NSString *kIRCCloudBacklogCompletedNotification = @"com.irccloud.notification.backlog.completed";
NSString *kIRCCloudBacklogProgressNotification = @"com.irccloud.notification.backlog.progress";
NSString *kIRCCloudEventKey = @"com.irccloud.event";

NSString *HOST_ADDRESS = @"localhost";
NSString *IRCCLOUD_PATH = @"/";

#define TYPE_UNKNOWN 0
#define TYPE_WIFI 1
#define TYPE_WWAN 2

NSLock *__parserLock = nil;

@interface OOBFetcher : NSObject<NSURLConnectionDelegate> {
    SBJsonStreamParser *_parser;
    SBJsonStreamParserAdapter *_adapter;
    NSString *_url;
    BOOL _cancelled;
    BOOL _running;
    NSURLConnection *_connection;
    int _bid;
}
@property (readonly) NSString *url;
@property int bid;
-(id)initWithURL:(NSString *)URL;
-(void)cancel;
-(void)start;
@end

@implementation OOBFetcher

-(id)initWithURL:(NSString *)URL {
    self = [super init];
    if(self) {
        _url = URL;
        _bid = -1;
        _adapter = [[SBJsonStreamParserAdapter alloc] init];
        _adapter.delegate = [NetworkConnection sharedInstance];
        _parser = [[SBJsonStreamParser alloc] init];
        _parser.delegate = _adapter;
        _cancelled = NO;
        _running = NO;
    }
    return self;
}
-(void)cancel {
    _cancelled = YES;
    [_connection cancel];
}
-(void)start {
    if(_cancelled || _running)
        return;
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:_url] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:[NSString stringWithFormat:@"session=%@",[NetworkConnection sharedInstance].session] forHTTPHeaderField:@"Cookie"];
    
    _connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    if(_connection) {
        if(_bid == -1)
            [__parserLock lock];
        _running = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogStartedNotification object:self];
        NSRunLoop *loop = [NSRunLoop currentRunLoop];
        while(!_cancelled && _running && [loop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]);
        if(_bid == -1)
            [__parserLock unlock];
    } else {
        NSLog(@"Failed to create NSURLConnection");
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogFailedNotification object:self];
    }
}
- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse {
    return nil;
}
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    if(_cancelled)
        return;
	NSLog(@"Request failed: %@", error);
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogFailedNotification object:self];
    }];
    _running = NO;
    _cancelled = YES;
}
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if(_cancelled)
        return;
	NSLog(@"Backlog download completed");
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogCompletedNotification object:self];
    }];
    _running = NO;
}
- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse {
    if(_cancelled)
        return nil;
	NSLog(@"Fetching: %@", [request URL]);
	return request;
}
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSHTTPURLResponse *)response {
	if([response statusCode] != 200) {
        NSLog(@"HTTP status code: %li", (long)[response statusCode]);
		NSLog(@"HTTP headers: %@", [response allHeaderFields]);
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogFailedNotification object:self];
        }];
        _cancelled = YES;
	}
}
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    //NSLog(@"%@", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
    if(!_cancelled) {
        [_parser parse:data];
    }
}

@end

@implementation NetworkConnection

+(NetworkConnection *)sharedInstance {
    static NetworkConnection *sharedInstance;
	
    @synchronized(self) {
        if(!sharedInstance)
            sharedInstance = [[NetworkConnection alloc] init];
		
        return sharedInstance;
    }
	return nil;
}

+(void)sync:(NSURL *)file1 with:(NSURL *)file2 {
    NSDictionary *a1 = [[NSFileManager defaultManager] attributesOfItemAtPath:file1.path error:nil];
    NSDictionary *a2 = [[NSFileManager defaultManager] attributesOfItemAtPath:file2.path error:nil];

    if(a1) {
        if(a2 == nil || [[a2 fileModificationDate] compare:[a1 fileModificationDate]] == NSOrderedAscending) {
            [[NSFileManager defaultManager] copyItemAtURL:file1 toURL:file2 error:NULL];
        }
    }
    
    if(a2) {
        if(a1 == nil || [[a1 fileModificationDate] compare:[a2 fileModificationDate]] == NSOrderedAscending) {
            [[NSFileManager defaultManager] copyItemAtURL:file2 toURL:file1 error:NULL];
        }
    }

    [file1 setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:NULL];
    [file2 setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:NULL];
}

+(void)sync {
    if([[[[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."] objectAtIndex:0] intValue] >= 8) {
#ifdef ENTERPRISE
        NSURL *sharedcontainer = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.irccloud.enterprise.share"];
#else
        NSURL *sharedcontainer = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.irccloud.share"];
#endif
        if(sharedcontainer) {
            NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] objectAtIndex:0];
            
            [NetworkConnection sync:[caches URLByAppendingPathComponent:@"servers"] with:[sharedcontainer URLByAppendingPathComponent:@"servers"]];
            [NetworkConnection sync:[caches URLByAppendingPathComponent:@"buffers"] with:[sharedcontainer URLByAppendingPathComponent:@"buffers"]];
            [NetworkConnection sync:[caches URLByAppendingPathComponent:@"channels"] with:[sharedcontainer URLByAppendingPathComponent:@"channels"]];
        }
    }
}

-(id)init {
    self = [super init];
#ifdef ENTERPRISE
    IRCCLOUD_HOST = [[NSUserDefaults standardUserDefaults] objectForKey:@"host"];
#endif
    if(self) {
    __parserLock = [[NSLock alloc] init];
    _queue = [[NSOperationQueue alloc] init];
//    _servers = [ServersDataSource sharedInstance];
//    _buffers = [BuffersDataSource sharedInstance];
//    _channels = [ChannelsDataSource sharedInstance];
//    _users = [UsersDataSource sharedInstance];
//    _events = [EventsDataSource sharedInstance];
//    _notifications = [NotificationsDataSource sharedInstance];
    _state = kIRCCloudStateDisconnected;
    _oobQueue = [[NSMutableArray alloc] init];
    _awayOverride = nil;
    _adapter = [[SBJsonStreamParserAdapter alloc] init];
    _adapter.delegate = self;
    _parser = [[SBJsonStreamParser alloc] init];
    _parser.supportMultipleDocuments = YES;
    _parser.delegate = _adapter;
    _lastReqId = 1;
    _idleInterval = 20;
    _reconnectTimestamp = -1;
    _failCount = 0;
    _notifier = NO;
    _writer = [[SBJsonWriter alloc] init];
    _reachabilityValid = NO;
    _reachability = nil;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backlogStarted:) name:kIRCCloudBacklogStartedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backlogCompleted:) name:kIRCCloudBacklogCompletedNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_backlogFailed:) name:kIRCCloudBacklogFailedNotification object:nil];
#ifdef APPSTORE
    NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
#else
    NSString *version = [NSString stringWithFormat:@"%@-%@",[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"], [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"]];
#endif
#ifdef EXTENSION
    NSString *app = @"ShareExtension";
#else
    NSString *app = @"IRCCloud";
#endif
    _userAgent = [NSString stringWithFormat:@"%@/%@ (%@; %@; %@ %@)", app, version, [UIDevice currentDevice].model, [[[NSUserDefaults standardUserDefaults] objectForKey: @"AppleLanguages"] objectAtIndex:0], [UIDevice currentDevice].systemName, [UIDevice currentDevice].systemVersion];
    
    if([[[NSUserDefaults standardUserDefaults] objectForKey:@"cacheVersion"] isEqualToString:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"]]) {
        NSString *cacheFile = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"stream"];
        _userInfo = [NSKeyedUnarchiver unarchiveObjectWithFile:cacheFile];
    } else {
        NSLog(@"Version changed, not loading caches");
    }
#ifndef EXTENSION
    if(_userInfo) {
        _streamId = [_userInfo objectForKey:@"streamId"];
        _config = [_userInfo objectForKey:@"config"];
        _highestEID = [[_userInfo objectForKey:@"highestEID"] doubleValue];
    }
#endif
    
    NSLog(@"%@", _userAgent);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cacheVersion"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
        _parserMap = @{};
    }
    return self;
}

//Adapted from http://stackoverflow.com/a/17057553/1406639
-(kIRCCloudReachability)reachable {
    SCNetworkReachabilityFlags flags;
    if(_reachabilityValid && SCNetworkReachabilityGetFlags(_reachability, &flags)) {
        if((flags & kSCNetworkReachabilityFlagsReachable) == 0) {
            // if target host is not reachable
            return kIRCCloudUnreachable;
        }
        
        if((flags & kSCNetworkReachabilityFlagsConnectionRequired) == 0) {
            // if target host is reachable and no connection is required
            return kIRCCloudReachable;
        }
        
        
        if ((((flags & kSCNetworkReachabilityFlagsConnectionOnDemand ) != 0) || (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic) != 0)) {
            // ... and the connection is on-demand (or on-traffic) if the
            //     calling application is using the CFSocketStream or higher APIs
            
            if ((flags & kSCNetworkReachabilityFlagsInterventionRequired) == 0) {
                // ... and no [user] intervention is needed
                return kIRCCloudReachable;
            }
        }
        
        if ((flags & kSCNetworkReachabilityFlagsIsWWAN) == kSCNetworkReachabilityFlagsIsWWAN) {
            // ... but WWAN connections are OK if the calling application
            //     is using the CFNetwork (CFSocketStream?) APIs.
            return kIRCCloudReachable;
        }
        return kIRCCloudUnreachable;
    }
    return kIRCCloudUnknown;
}

static void ReachabilityCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void* info) {
    static BOOL firstTime = YES;
    static int lastType = TYPE_UNKNOWN;
    int type = TYPE_UNKNOWN;
    [NetworkConnection sharedInstance].reachabilityValid = YES;
    kIRCCloudReachability reachable = [[NetworkConnection sharedInstance] reachable];
    kIRCCloudState state = [NetworkConnection sharedInstance].state;
    NSLog(@"IRCCloud state: %i Reconnect timestamp: %f Reachable: %i lastType: %i", state, [NetworkConnection sharedInstance].reconnectTimestamp, reachable, lastType);
    
    if(flags & kSCNetworkReachabilityFlagsIsWWAN)
        type = TYPE_WWAN;
    else if (flags & kSCNetworkReachabilityFlagsReachable)
        type = TYPE_WIFI;
    else
        type = TYPE_UNKNOWN;

    if(!firstTime && type != lastType && state != kIRCCloudStateDisconnected) {
        NSLog(@"IRCCloud became unreachable, disconnecting websocket");
        [[NetworkConnection sharedInstance] performSelectorOnMainThread:@selector(disconnect) withObject:nil waitUntilDone:YES];
        [NetworkConnection sharedInstance].reconnectTimestamp = -1;
        state = kIRCCloudStateDisconnected;
        [[NetworkConnection sharedInstance] performSelectorInBackground:@selector(serialize) withObject:nil];
    }
    
    lastType = type;
    firstTime = NO;
    
    if(reachable == kIRCCloudReachable && state == kIRCCloudStateDisconnected && [NetworkConnection sharedInstance].reconnectTimestamp != 0 && [[NetworkConnection sharedInstance].session length]) {
        NSLog(@"IRCCloud server became reachable, connecting");
        [[NetworkConnection sharedInstance] performSelectorOnMainThread:@selector(_connect) withObject:nil waitUntilDone:YES];
    } else if(reachable == kIRCCloudUnreachable && state == kIRCCloudStateConnected) {
        NSLog(@"IRCCloud server became unreachable, disconnecting");
        [[NetworkConnection sharedInstance] performSelectorOnMainThread:@selector(disconnect) withObject:nil waitUntilDone:YES];
        [NetworkConnection sharedInstance].reconnectTimestamp = -1;
        [[NetworkConnection sharedInstance] performSelectorInBackground:@selector(serialize) withObject:nil];
    }
    [[NetworkConnection sharedInstance] performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
}

-(void)_connect {
    [self connect:_notifier];
}

-(NSDictionary *)login:(NSString *)email password:(NSString *)password token:(NSString *)token {
	NSData *data;
	NSURLResponse *response = nil;
	NSError *error = nil;
    
    CFStringRef email_escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)email, NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
    CFStringRef password_escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)password, NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/login", HOST_ADDRESS]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:token forHTTPHeaderField:@"x-auth-formtoken"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[[NSString stringWithFormat:@"email=%@&password=%@&token=%@", email_escaped, password_escaped, token] dataUsingEncoding:NSUTF8StringEncoding]];
    
    CFRelease(email_escaped);
    CFRelease(password_escaped);
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
    return [[[SBJsonParser alloc] init] objectWithData:data];
}

-(NSDictionary *)login:(NSURL *)accessLink {
	NSData *data;
	NSURLResponse *response = nil;
	NSError *error = nil;
    
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:accessLink cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
    return [[[SBJsonParser alloc] init] objectWithData:data];
}

-(NSDictionary *)signup:(NSString *)email password:(NSString *)password realname:(NSString *)realname token:(NSString *)token impression:(NSString *)impression {
	NSData *data;
	NSURLResponse *response = nil;
	NSError *error = nil;
    
    CFStringRef realname_escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)realname, NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
    CFStringRef email_escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)email, NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
    CFStringRef password_escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)password, NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/signup", HOST_ADDRESS]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:token forHTTPHeaderField:@"x-auth-formtoken"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[[NSString stringWithFormat:@"realname=%@&email=%@&password=%@&token=%@&ios_impression=%@", realname_escaped, email_escaped, password_escaped, token,(impression!=nil)?impression:@""] dataUsingEncoding:NSUTF8StringEncoding]];
    
    if(realname_escaped != NULL)
        CFRelease(realname_escaped);
    
    if(email_escaped != NULL)
        CFRelease(email_escaped);
    
    if(password_escaped != NULL)
        CFRelease(password_escaped);
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
    return [[[SBJsonParser alloc] init] objectWithData:data];
}

-(NSDictionary *)requestPassword:(NSString *)email token:(NSString *)token {
	NSData *data;
	NSURLResponse *response = nil;
	NSError *error = nil;
    
    CFStringRef email_escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)email, NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/request-access-link", HOST_ADDRESS]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:token forHTTPHeaderField:@"x-auth-formtoken"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[[NSString stringWithFormat:@"email=%@&token=%@&mobile=1", email_escaped, token] dataUsingEncoding:NSUTF8StringEncoding]];
    
    CFRelease(email_escaped);
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
    return [[[SBJsonParser alloc] init] objectWithData:data];
}

//From: http://stackoverflow.com/questions/1305225/best-way-to-serialize-a-nsdata-into-an-hexadeximal-string
-(NSString *)dataToHex:(NSData *)data {
    /* Returns hexadecimal string of NSData. Empty string if data is empty.   */
    
    const unsigned char *dataBuffer = (const unsigned char *)[data bytes];
    
    if (!dataBuffer)
        return [NSString string];
    
    NSUInteger          dataLength  = [data length];
    NSMutableString     *hexString  = [NSMutableString stringWithCapacity:(dataLength * 2)];
    
    for (int i = 0; i < dataLength; ++i)
        [hexString appendString:[NSString stringWithFormat:@"%02x", (unsigned int)dataBuffer[i]]];
    
    return [NSString stringWithString:hexString];
}

-(NSDictionary *)registerAPNs:(NSData *)token {
#if defined(DEBUG) || defined(EXTENSION)
    return nil;
#else
	NSData *data;
	NSURLResponse *response = nil;
	NSError *error = nil;
    NSString *body = [NSString stringWithFormat:@"device_id=%@&session=%@", [self dataToHex:token], self.session];
    
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/apn-register", IRCCLOUD_HOST]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:[NSString stringWithFormat:@"session=%@",self.session] forHTTPHeaderField:@"Cookie"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    
    return [[[SBJsonParser alloc] init] objectWithData:data];
#endif
}

-(NSDictionary *)unregisterAPNs:(NSData *)token session:(NSString *)session {
#ifdef EXTENSION
    return nil;
#else
	NSData *data;
	NSURLResponse *response = nil;
	NSError *error = nil;
    NSString *body = [NSString stringWithFormat:@"device_id=%@&session=%@", [self dataToHex:token], session];
    
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/apn-unregister", HOST_ADDRESS]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:[NSString stringWithFormat:@"session=%@",self.session] forHTTPHeaderField:@"Cookie"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    
    return [[[SBJsonParser alloc] init] objectWithData:data];
#endif
}

-(NSDictionary *)impression:(NSString *)idfa referrer:(NSString *)referrer {
#ifdef EXTENSION
    return nil;
#else
    CFStringRef idfa_escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)idfa, NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
    CFStringRef referrer_escaped = CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)referrer, NULL, (CFStringRef)@"&+/?=[]();:^", kCFStringEncodingUTF8);
    
    NSData *data;
    NSURLResponse *response = nil;
    NSError *error = nil;
    NSString *body = [NSString stringWithFormat:@"idfa=%@&referrer=%@", idfa_escaped, referrer_escaped];
    if(self.session.length)
        body = [body stringByAppendingFormat:@"&session=%@", self.session];

    CFRelease(idfa_escaped);
    CFRelease(referrer_escaped);
    
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/ios-impressions", HOST_ADDRESS]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    if(self.session.length)
        [request setValue:[NSString stringWithFormat:@"session=%@",self.session] forHTTPHeaderField:@"Cookie"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
    
    return [[[SBJsonParser alloc] init] objectWithData:data];
#endif
}

-(NSDictionary *)requestAuthToken {
	NSData *data;
	NSURLResponse *response = nil;
	NSError *error = nil;
    
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/auth-formtoken", HOST_ADDRESS]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setHTTPMethod:@"POST"];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
    return [[[SBJsonParser alloc] init] objectWithData:data];
}

-(NSDictionary *)requestConfiguration {
    NSData *data;
    NSURLResponse *response = nil;
    NSError *error = nil;
    
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/config", HOST_ADDRESS]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
    return [[[SBJsonParser alloc] init] objectWithData:data];
}

-(NSDictionary *)getFiles:(int)page {
    NSData *data;
    NSURLResponse *response = nil;
    NSError *error = nil;
    
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/files?page=%i", HOST_ADDRESS, page]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    if(self.session.length)
        [request setValue:[NSString stringWithFormat:@"session=%@",self.session] forHTTPHeaderField:@"Cookie"];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
    return [[[SBJsonParser alloc] init] objectWithData:data];
}

-(NSDictionary *)getPastebins:(int)page {
    NSData *data;
    NSURLResponse *response = nil;
    NSError *error = nil;
    
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/pastebins?page=%i", HOST_ADDRESS, page]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:30];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    if(self.session.length)
        [request setValue:[NSString stringWithFormat:@"session=%@",self.session] forHTTPHeaderField:@"Cookie"];
    
    data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
    return [[[SBJsonParser alloc] init] objectWithData:data];
}

-(int)_sendRequest:(NSString *)method args:(NSDictionary *)args {
    @synchronized(_writer) {
        if(_state == kIRCCloudStateConnected) {
            NSMutableDictionary *dict = [[NSMutableDictionary alloc] initWithDictionary:args];
            [dict setObject:method forKey:@"_method"];
            [dict setObject:@(++_lastReqId) forKey:@"_reqid"];
            [_socket sendText:[_writer stringWithObject:dict]];
            return _lastReqId;
        } else {
            NSLog(@"Discarding request '%@' on disconnected socket", method);
            return -1;
        }
    }
}

-(int)say:(NSString *)message to:(NSString *)to cid:(int)cid {
    if(to)
        return [self _sendRequest:@"say" args:@{@"cid":@(cid), @"msg":message, @"to":to}];
    else
        return [self _sendRequest:@"say" args:@{@"cid":@(cid), @"msg":message}];
}

-(int)heartbeat:(int)selectedBuffer cids:(NSArray *)cids bids:(NSArray *)bids lastSeenEids:(NSArray *)lastSeenEids {
    @synchronized(_writer) {
        NSMutableDictionary *heartbeat = [[NSMutableDictionary alloc] init];
        for(int i = 0; i < cids.count; i++) {
            NSMutableDictionary *d = [heartbeat objectForKey:[NSString stringWithFormat:@"%@",[cids objectAtIndex:i]]];
            if(!d) {
                d = [[NSMutableDictionary alloc] init];
                [heartbeat setObject:d forKey:[NSString stringWithFormat:@"%@",[cids objectAtIndex:i]]];
            }
            [d setObject:[lastSeenEids objectAtIndex:i] forKey:[NSString stringWithFormat:@"%@",[bids objectAtIndex:i]]];
        }
        NSString *seenEids = [_writer stringWithObject:heartbeat];
        NSMutableDictionary *d = _userInfo.mutableCopy;
        [d setObject:@(selectedBuffer) forKey:@"last_selected_bid"];
        _userInfo = d;
        return [self _sendRequest:@"heartbeat" args:@{@"selectedBuffer":@(selectedBuffer), @"seenEids":seenEids}];
    }
}
-(int)heartbeat:(int)selectedBuffer cid:(int)cid bid:(int)bid lastSeenEid:(NSTimeInterval)lastSeenEid {
    return [self heartbeat:selectedBuffer cids:@[@(cid)] bids:@[@(bid)] lastSeenEids:@[@(lastSeenEid)]];
}

-(int)join:(NSString *)channel key:(NSString *)key cid:(int)cid {
    if(key.length) {
        return [self _sendRequest:@"join" args:@{@"cid":@(cid), @"channel":channel, @"key":key}];
    } else {
        return [self _sendRequest:@"join" args:@{@"cid":@(cid), @"channel":channel}];
    }
}
-(int)part:(NSString *)channel msg:(NSString *)msg cid:(int)cid {
    if(msg.length) {
        return [self _sendRequest:@"part" args:@{@"cid":@(cid), @"channel":channel, @"msg":msg}];
    } else {
        return [self _sendRequest:@"part" args:@{@"cid":@(cid), @"channel":channel}];
    }
}

-(int)kick:(NSString *)nick chan:(NSString *)chan msg:(NSString *)msg cid:(int)cid {
    return [self say:[NSString stringWithFormat:@"/kick %@ %@",nick,(msg.length)?msg:@""] to:chan cid:cid];
}

-(int)mode:(NSString *)mode chan:(NSString *)chan cid:(int)cid {
    return [self say:[NSString stringWithFormat:@"/mode %@ %@",chan,mode] to:chan cid:cid];
}

-(int)invite:(NSString *)nick chan:(NSString *)chan cid:(int)cid {
    return [self say:[NSString stringWithFormat:@"/invite %@ %@",nick,chan] to:chan cid:cid];
}

-(int)archiveBuffer:(int)bid cid:(int)cid {
    return [self _sendRequest:@"archive-buffer" args:@{@"cid":@(cid),@"id":@(bid)}];
}

-(int)unarchiveBuffer:(int)bid cid:(int)cid {
    return [self _sendRequest:@"unarchive-buffer" args:@{@"cid":@(cid),@"id":@(bid)}];
}

-(int)deleteBuffer:(int)bid cid:(int)cid {
    return [self _sendRequest:@"delete-buffer" args:@{@"cid":@(cid),@"id":@(bid)}];
}

-(int)deleteServer:(int)cid {
    return [self _sendRequest:@"delete-connection" args:@{@"cid":@(cid)}];
}

-(int)addServer:(NSString *)hostname port:(int)port ssl:(int)ssl netname:(NSString *)netname nick:(NSString *)nick realname:(NSString *)realname serverPass:(NSString *)serverPass nickservPass:(NSString *)nickservPass joinCommands:(NSString *)joinCommands channels:(NSString *)channels {
    return [self _sendRequest:@"add-server" args:@{
                                                   @"hostname":hostname?hostname:@"",
                                                   @"port":@(port),
                                                   @"ssl":[NSString stringWithFormat:@"%i",ssl],
                                                   @"netname":netname?netname:@"",
                                                   @"nickname":nick?nick:@"",
                                                   @"realname":realname?realname:@"",
                                                   @"server_pass":serverPass?serverPass:@"",
                                                   @"nspass":nickservPass?nickservPass:@"",
                                                   @"joincommands":joinCommands?joinCommands:@"",
                                                   @"channels":channels?channels:@""}];
}

-(int)editServer:(int)cid hostname:(NSString *)hostname port:(int)port ssl:(int)ssl netname:(NSString *)netname nick:(NSString *)nick realname:(NSString *)realname serverPass:(NSString *)serverPass nickservPass:(NSString *)nickservPass joinCommands:(NSString *)joinCommands {
    return [self _sendRequest:@"edit-server" args:@{
                                                    @"hostname":hostname?hostname:@"",
                                                    @"port":@(port),
                                                    @"ssl":[NSString stringWithFormat:@"%i",ssl],
                                                    @"netname":netname?netname:@"",
                                                    @"nickname":nick?nick:@"",
                                                    @"realname":realname?realname:@"",
                                                    @"server_pass":serverPass?serverPass:@"",
                                                    @"nspass":nickservPass?nickservPass:@"",
                                                    @"joincommands":joinCommands?joinCommands:@"",
                                                    @"cid":@(cid)}];
}

-(int)ignore:(NSString *)mask cid:(int)cid {
    return [self _sendRequest:@"ignore" args:@{@"cid":@(cid),@"mask":mask}];
}

-(int)unignore:(NSString *)mask cid:(int)cid {
    return [self _sendRequest:@"unignore" args:@{@"cid":@(cid),@"mask":mask}];
}

-(int)setPrefs:(NSString *)prefs {
    _prefs = nil;
    return [self _sendRequest:@"set-prefs" args:@{@"prefs":prefs}];
}

-(int)setRealname:(NSString *)realname highlights:(NSString *)highlights autoaway:(BOOL)autoaway {
    return [self _sendRequest:@"user-settings" args:@{
                                                      @"realname":realname,
                                                      @"hwords":highlights,
                                                      @"autoaway":autoaway?@"1":@"0"}];
}

-(int)changeEmail:(NSString *)email password:(NSString *)password {
    return [self _sendRequest:@"change-password" args:@{
                                                      @"email":email,
                                                      @"password":password}];
}

-(int)ns_help_register:(int)cid {
    return [self _sendRequest:@"ns-help-register" args:@{@"cid":@(cid)}];
}

-(int)setNickservPass:(NSString *)nspass cid:(int)cid {
    return [self _sendRequest:@"set-nspass" args:@{@"cid":@(cid),@"nspass":nspass}];
}

-(int)whois:(NSString *)nick server:(NSString *)server cid:(int)cid {
    if(server.length) {
        return [self _sendRequest:@"whois" args:@{@"cid":@(cid), @"nick":nick, @"server":server}];
    } else {
        return [self _sendRequest:@"whois" args:@{@"cid":@(cid), @"nick":nick}];
    }
}

-(int)topic:(NSString *)topic chan:(NSString *)chan cid:(int)cid {
    return [self _sendRequest:@"topic" args:@{@"cid":@(cid),@"channel":chan,@"topic":topic}];
}

-(int)back:(int)cid {
    return [self _sendRequest:@"back" args:@{@"cid":@(cid)}];
}

-(int)resendVerifyEmail {
    return [self _sendRequest:@"resend-verify-email" args:nil];
}

-(int)disconnect:(int)cid msg:(NSString *)msg {
    if(msg.length)
        return [self _sendRequest:@"disconnect" args:@{@"cid":@(cid), @"msg":msg}];
    else
        return [self _sendRequest:@"disconnect" args:@{@"cid":@(cid)}];
}

-(int)reconnect:(int)cid {
    return [self _sendRequest:@"reconnect" args:@{@"cid":@(cid)}];
}

-(int)reorderConnections:(NSString *)cids {
    return [self _sendRequest:@"reorder-connections" args:@{@"cids":cids}];
}

-(int)finalizeUpload:(NSString *)uploadID filename:(NSString *)filename originalFilename:(NSString *)originalFilename {
    return [self _sendRequest:@"upload-finalise" args:@{@"id":uploadID, @"filename":filename, @"original_filename":originalFilename}];
}

-(int)deleteFile:(NSString *)fileID {
    return [self _sendRequest:@"delete-file" args:@{@"file":fileID}];
}

-(int)paste:(NSString *)name contents:(NSString *)contents extension:(NSString *)extension {
    if(name.length) {
        return [self _sendRequest:@"paste" args:@{@"name":name, @"contents":contents, @"extension":extension}];
    } else {
        return [self _sendRequest:@"paste" args:@{@"contents":contents, @"extension":extension}];
    }
}

-(int)deletePaste:(NSString *)pasteID {
    return [self _sendRequest:@"delete-pastebin" args:@{@"id":pasteID}];
}

-(int)editPaste:(NSString *)pasteID name:(NSString *)name contents:(NSString *)contents extension:(NSString *)extension {
    if(name.length) {
        return [self _sendRequest:@"edit-pastebin" args:@{@"id":pasteID, @"name":name, @"body":contents, @"extension":extension}];
    } else {
        return [self _sendRequest:@"edit-pastebin" args:@{@"id":pasteID, @"body":contents, @"extension":extension}];
    }
}

-(void)connect:(BOOL)notifier {
    @synchronized(self) {
        if(HOST_ADDRESS.length < 1) {
            NSLog(@"Not connecting, no host");
            return;
        }
        
        if(self.session.length < 1) {
            NSLog(@"Not connecting, no session");
            return;
        }
        
        if(_socket) {
            NSLog(@"Discarding previous socket");
            WebSocket *s = _socket;
            _socket = nil;
            s.delegate = nil;
            [s close];
        }
        
        if(!_reachability) {
            _reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, [HOST_ADDRESS cStringUsingEncoding:NSUTF8StringEncoding]);
            SCNetworkReachabilityScheduleWithRunLoop(_reachability, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            SCNetworkReachabilitySetCallback(_reachability, ReachabilityCallback, NULL);
        } else {
            kIRCCloudReachability reachability = [self reachable];
            if(reachability != kIRCCloudReachable) {
                NSLog(@"IRCCloud is unreachable");
                _reconnectTimestamp = -1;
                _state = kIRCCloudStateDisconnected;
                if(reachability == kIRCCloudUnreachable)
                    [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
                return;
            }
        }
        
        if(_oobQueue.count) {
            NSLog(@"Cancelling pending OOB requests");
            for(OOBFetcher *fetcher in _oobQueue) {
                [fetcher cancel];
            }
            [_oobQueue removeAllObjects];
        }
        __parserLock = [[NSLock alloc] init];
        
        NSString *url = [NSString stringWithFormat:@"wss://%@%@",HOST_ADDRESS,IRCCLOUD_PATH];
        if(_highestEID > 0 && _streamId.length) {
            url = [url stringByAppendingFormat:@"?since_id=%.0lf&stream_id=%@", _highestEID, _streamId];
        }
        if(notifier) {
            if([url rangeOfString:@"?"].location == NSNotFound)
                url = [url stringByAppendingFormat:@"?notifier=1"];
            else
                url = [url stringByAppendingFormat:@"&notifier=1"];
        }
        NSLog(@"Connecting: %@", url);
        _notifier = notifier;
        _state = kIRCCloudStateConnecting;
        _idleInterval = 20;
        _accrued = 0;
        _currentCount = 0;
        _totalCount = 0;
        _reconnectTimestamp = -1;
        _resuming = NO;
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
        WebSocketConnectConfig* config = [WebSocketConnectConfig configWithURLString:url origin:[NSString stringWithFormat:@"https://%@", HOST_ADDRESS] protocols:nil
                                                                         tlsSettings:[@{(NSString *)kCFStreamSSLPeerName: HOST_ADDRESS,
                                                                                        (NSString *)GCDAsyncSocketSSLProtocolVersionMin:@(kTLSProtocol1),
#ifndef ENTERPRISE
                                                                                        @"fingerprints":@[@"E6B8B984CA03D68389A227021B11C496770DE26A", @"8D3BE1983F75F4A4546F42F5EC189BC65A9D3A42"]
#endif
                                                                                        } mutableCopy]
                                                                             headers:[@[[HandshakeHeader headerWithValue:_userAgent forKey:@"User-Agent"],
                                                                                        [HandshakeHeader headerWithValue:[NSString stringWithFormat:@"session=%@",self.session] forKey:@"Cookie"]] mutableCopy]
                                                                   verifySecurityKey:YES extensions:@[@"x-webkit-deflate-frame"]];
        _socket = [WebSocket webSocketWithConfig:config delegate:self];
        
        [_socket open];
    }
}

-(void)cancelPendingBacklogRequests {
    for(OOBFetcher *fetcher in _oobQueue.copy) {
        if(fetcher.bid > 0) {
            [fetcher cancel];
            [_oobQueue removeObject:fetcher];
        }
    }
}

-(void)disconnect {
    NSLog(@"Closing websocket");
    if(_reachability)
        CFRelease(_reachability);
    _reachability = nil;
    _reachabilityValid = NO;
    for(OOBFetcher *fetcher in _oobQueue) {
        [fetcher cancel];
    }
    [_oobQueue removeAllObjects];
    _reconnectTimestamp = 0;
    [self cancelIdleTimer];
    _state = kIRCCloudStateDisconnected;
    [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
    [_socket close];
    _socket = nil;
}

-(void)clearPrefs {
    _prefs = nil;
    _userInfo = nil;
}

-(void)parser:(SBJsonStreamParser *)parser foundArray:(NSArray *)array {
    //This is wasteful, we don't use it
}

-(void)webSocketDidOpen:(WebSocket *)socket {
    if(socket == _socket) {
        NSLog(@"Socket connected");
        _idleInterval = 20;
        _reconnectTimestamp = -1;
        _state = kIRCCloudStateConnected;
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
        _config = [self requestConfiguration];
    } else {
        NSLog(@"Socket connected, but it wasn't the active socket");
    }
}

-(void)fail {
    _failCount++;
    if(_failCount < 4)
        _idleInterval = _failCount;
    else if(_failCount < 10)
        _idleInterval = 10;
    else
        _idleInterval = 30;
    _reconnectTimestamp = -1;
    NSLog(@"Fail count: %i will reconnect in %f seconds", _failCount, _idleInterval);
    [self performSelectorOnMainThread:@selector(scheduleIdleTimer) withObject:nil waitUntilDone:YES];
}

-(void)webSocket:(WebSocket *)socket didClose:(NSUInteger) aStatusCode message:(NSString*) aMessage error:(NSError*) aError {
    if(socket == _socket) {
        NSLog(@"Status Code: %lu", (unsigned long)aStatusCode);
        NSLog(@"Close Message: %@", aMessage);
        NSLog(@"Error: errorDesc=%@, failureReason=%@", [aError localizedDescription], [aError localizedFailureReason]);
        _state = kIRCCloudStateDisconnected;
        if([self reachable] == kIRCCloudReachable && _reconnectTimestamp != 0) {
            [self fail];
        } else {
            NSLog(@"IRCCloud is unreacahable or reconnecting is disabled");
            [self performSelectorOnMainThread:@selector(cancelIdleTimer) withObject:nil waitUntilDone:YES];
            [self serialize];
        }
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
    } else {
        NSLog(@"Socket closed, but it wasn't the active socket");
    }
}

-(void)webSocket:(WebSocket *)socket didReceiveError: (NSError*) aError {
    if(socket == _socket) {
        NSLog(@"Error: errorDesc=%@, failureReason=%@", [aError localizedDescription], [aError localizedFailureReason]);
        _state = kIRCCloudStateDisconnected;
        if([self reachable] && _reconnectTimestamp != 0) {
            [self fail];
        }
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
    } else {
        NSLog(@"Socket received error, but it wasn't the active socket");
    }
}

-(void)webSocket:(WebSocket *)socket didReceiveTextMessage:(NSString*)aMessage {
    if(socket == _socket) {
        if(aMessage) {
            [__parserLock lock];
            [_parser parse:[aMessage dataUsingEncoding:NSUTF8StringEncoding]];
            [__parserLock unlock];
        }
    } else {
        NSLog(@"Got event for inactive socket");
    }
}

- (void)webSocket:(WebSocket *)socket didReceiveBinaryMessage: (NSData*) aMessage {
    if(socket == _socket) {
        if(aMessage) {
            [__parserLock lock];
            [_parser parse:aMessage];
            [__parserLock unlock];
        }
    } else {
        NSLog(@"Got event for inactive socket");
    }
}

-(void)postObject:(id)object forEvent:(kIRCEvent)event {
    if(_accrued == 0) {
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudEventNotification object:object userInfo:@{kIRCCloudEventKey:[NSNumber numberWithInt:event]}];
        }];
    }
}

-(void)_postLoadingProgress:(NSNumber *)progress {
    static NSNumber *lastProgress = nil;
    if(!lastProgress || (int)(lastProgress.floatValue * 100) != (int)(progress.floatValue * 100))
        [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudBacklogProgressNotification object:progress];
    lastProgress = progress;
}

-(void)_postConnectivityChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:kIRCCloudConnectivityNotification object:nil userInfo:nil];
}

-(NSDictionary *)prefs {
    if(!_prefs && _userInfo && [[_userInfo objectForKey:@"prefs"] isKindOfClass:[NSString class]] && [[_userInfo objectForKey:@"prefs"] length]) {
        SBJsonParser *parser = [[SBJsonParser alloc] init];
        _prefs = [parser objectWithString:[_userInfo objectForKey:@"prefs"]];
    }
    return _prefs;
}

-(void)cancelIdleTimer {
    if(![NSThread currentThread].isMainThread)
        NSLog(@"WARNING: cancel idle timer called outside of main thread");
    
    [_idleTimer invalidate];
    _idleTimer = nil;
}

-(void)scheduleIdleTimer {
    if(![NSThread currentThread].isMainThread)
        NSLog(@"WARNING: schedule idle timer called outside of main thread");
    [_idleTimer invalidate];
    _idleTimer = nil;
    if(_reconnectTimestamp == 0)
        return;
    
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:_idleInterval target:self selector:@selector(_idle) userInfo:nil repeats:NO];
    _reconnectTimestamp = [[NSDate date] timeIntervalSince1970] + _idleInterval;
}

-(void)_idle {
    _reconnectTimestamp = 0;
    _idleTimer = nil;
    [_socket close];
    _state = kIRCCloudStateDisconnected;
    NSLog(@"Websocket idle time exceeded, reconnecting...");
    [self connect:_notifier];
}

-(void)requestBacklogForBuffer:(int)bid server:(int)cid {
    [self requestBacklogForBuffer:bid server:cid beforeId:-1];
}

-(void)requestBacklogForBuffer:(int)bid server:(int)cid beforeId:(NSTimeInterval)eid {
    NSString *URL = nil;
    if(eid > 0)
        URL = [NSString stringWithFormat:@"https://%@/chat/backlog?cid=%i&bid=%i&beforeid=%.0lf", HOST_ADDRESS, cid, bid, eid];
    else
        URL = [NSString stringWithFormat:@"https://%@/chat/backlog?cid=%i&bid=%i", HOST_ADDRESS, cid, bid];
    OOBFetcher *fetcher = [self fetchOOB:URL];
    fetcher.bid = bid;
}


-(OOBFetcher *)fetchOOB:(NSString *)url {
    @synchronized(_oobQueue) {
        NSArray *fetchers = _oobQueue.copy;
        for(OOBFetcher *fetcher in fetchers) {
            if([fetcher.url isEqualToString:url]) {
                NSLog(@"Cancelling previous OOB request");
                [fetcher cancel];
                [_oobQueue removeObject:fetcher];
            }
        }
        OOBFetcher *fetcher = [[OOBFetcher alloc] initWithURL:url];
        [_oobQueue addObject:fetcher];
        if(_oobQueue.count == 1) {
            [_queue addOperationWithBlock:^{
                [fetcher start];
            }];
        } else {
            NSLog(@"OOB Request has been queued");
        }
        return fetcher;
    }
}

-(void)clearOOB {
    @synchronized(_oobQueue) {
        NSMutableArray *oldQueue = _oobQueue;
        _oobQueue = [[NSMutableArray alloc] init];
        for(OOBFetcher *fetcher in oldQueue) {
            [fetcher cancel];
        }
    }
}

-(void)_backlogStarted:(NSNotification *)notification {
    _OOBStartTime = [NSDate timeIntervalSinceReferenceDate];
    _longestEventTime = 0;
    _longestEventType = nil;
    if(_awayOverride.count)
        NSLog(@"Caught %lu self_back events", (unsigned long)_awayOverride.count);
    _currentBid = -1;
    _currentCount = 0;
    _firstEID = 0;
    _totalCount = 0;
    backlog = YES;
}

-(void)_backlogCompleted:(NSNotification *)notification {
    if(_OOBStartTime) {
        NSTimeInterval total = [NSDate timeIntervalSinceReferenceDate] - _OOBStartTime;
        NSLog(@"OOB processed %i events in %f seconds (%f seconds / event)", _totalCount, total, total / (double)_totalCount);
        NSLog(@"Longest event: %@ (%f seconds)", _longestEventType, _longestEventTime);
        _OOBStartTime = 0;
        _longestEventTime = 0;
        _longestEventType = nil;
    }
    _failCount = 0;
    _accrued = 0;
    backlog = NO;
    _resuming = NO;
    _awayOverride = nil;
    _reconnectTimestamp = [[NSDate date] timeIntervalSince1970] + _idleInterval;
    [self performSelectorOnMainThread:@selector(scheduleIdleTimer) withObject:nil waitUntilDone:NO];
    OOBFetcher *fetcher = notification.object;
    NSLog(@"Backlog finished for bid: %i", fetcher.bid);
    if(fetcher.bid > 0) {
        //[_buffers updateTimeout:0 buffer:fetcher.bid];
    } else {
        
        if(fetcher.bid == -1) {
            
        }
        
        _numBuffers = 0;
        
    }
    NSLog(@"I downloaded %i events", _totalCount);
    [_oobQueue removeObject:fetcher];
    
    [self performSelectorInBackground:@selector(serialize) withObject:nil];
}

-(void)serialize {
    @synchronized(self) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"cacheVersion"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    
#ifndef EXTENSION
        NSString *cacheFile = [[NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingPathComponent:@"stream"];
        NSMutableDictionary *stream = [_userInfo mutableCopy];
        if(_streamId)
            [stream setObject:_streamId forKey:@"streamId"];
        else
            [stream removeObjectForKey:@"streamId"];
        if(_config)
            [stream setObject:_config forKey:@"config"];
        else
            [stream removeObjectForKey:@"config"];
        [stream setObject:@(_highestEID) forKey:@"highestEID"];
        [NSKeyedArchiver archiveRootObject:stream toFile:cacheFile];
        [[NSURL fileURLWithPath:cacheFile] setResourceValue:[NSNumber numberWithBool:YES] forKey:NSURLIsExcludedFromBackupKey error:NULL];
#endif
        [[NSUserDefaults standardUserDefaults] setObject:[[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"] forKey:@"cacheVersion"];
        if([[[[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."] objectAtIndex:0] intValue] >= 8) {
#ifdef ENTERPRISE
            NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.irccloud.enterprise.share"];
#else
            NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.irccloud.share"];
#endif
            [d setObject:[[NSUserDefaults standardUserDefaults] objectForKey:@"cacheVersion"] forKey:@"cacheVersion"];
            [d setObject:[[NSUserDefaults standardUserDefaults] objectForKey:@"fontSize"] forKey:@"fontSize"];
            [d synchronize];
        }
        [NetworkConnection sync];
    }
}

-(void)_backlogFailed:(NSNotification *)notification {
    _accrued = 0;
    backlog = NO;
    _awayOverride = nil;
    _reconnectTimestamp = [[NSDate date] timeIntervalSince1970] + _idleInterval;
    [self performSelectorOnMainThread:@selector(scheduleIdleTimer) withObject:nil waitUntilDone:NO];
    [_oobQueue removeObject:notification.object];
    if([(OOBFetcher *)notification.object bid] > 0) {
        NSLog(@"Backlog download failed, rescheduling timed out buffers");
        
    } else {
        NSLog(@"Initial backlog download failed");
        [self disconnect];
        _state = kIRCCloudStateDisconnected;
        _streamId = nil;
        [self fail];
        [self performSelectorOnMainThread:@selector(_postConnectivityChange) withObject:nil waitUntilDone:YES];
    }
}

-(void)_logout:(NSString *)session {
    NSLog(@"Unregister result: %@", [self unregisterAPNs:[[NSUserDefaults standardUserDefaults] objectForKey:@"APNs"] session:session]);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"APNs"];
    //TODO: check the above result, and retry if it fails
	NSURLResponse *response = nil;
	NSError *error = nil;
    NSString *body = [NSString stringWithFormat:@"session=%@", self.session];
    
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
    if([[[[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."] objectAtIndex:0] intValue] >= 7)
        [[UIApplication sharedApplication] setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalNever];
#endif
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"https://%@/chat/logout", HOST_ADDRESS]] cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:5];
    [request setHTTPShouldHandleCookies:NO];
    [request setValue:_userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:[NSString stringWithFormat:@"session=%@", session] forHTTPHeaderField:@"Cookie"];
    [request setHTTPMethod:@"POST"];
    [request setHTTPBody:[body dataUsingEncoding:NSUTF8StringEncoding]];
    
    [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
#ifndef EXTENSION
    [UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
#endif
}

-(void)logout {
    NSLog(@"Logging out");
    _reconnectTimestamp = 0;
    _streamId = nil;
    _userInfo = @{};
    _highestEID = 0;
    NSString *s = self.session;
    SecItemDelete((__bridge CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:(__bridge id)(kSecClassGenericPassword),  kSecClass, [NSBundle mainBundle].bundleIdentifier, kSecAttrService, nil]);
    _session = nil;
    [self disconnect];
    [self performSelectorInBackground:@selector(_logout:) withObject:s];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"host"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"path"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"imgur_access_token"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"imgur_refresh_token"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"imgur_account_username"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"imgur_token_type"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"imgur_expires_in"];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"uploadsAvailable"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self clearPrefs];
    [self serialize];
    [NetworkConnection sync];
#ifndef EXTENSION
    [[UIApplication sharedApplication] unregisterForRemoteNotifications];
    NSURL *caches = [[[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] objectAtIndex:0];
    for(NSURL *file in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:caches includingPropertiesForKeys:nil options:0 error:nil]) {
        [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
    }
    if([[[[UIDevice currentDevice].systemVersion componentsSeparatedByString:@"."] objectAtIndex:0] intValue] >= 8) {
#ifdef ENTERPRISE
        NSURL *sharedcontainer = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.irccloud.enterprise.share"];
#else
        NSURL *sharedcontainer = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.irccloud.share"];
#endif
        for(NSURL *file in [[NSFileManager defaultManager] contentsOfDirectoryAtURL:sharedcontainer includingPropertiesForKeys:nil options:0 error:nil]) {
            [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
        }
    }
#endif
    [self cancelIdleTimer];
}

-(NSString *)session {
    if(_session) {
        _keychainFailCount = 0;
        return _session;
    }
    
    if([[NSUserDefaults standardUserDefaults] objectForKey:@"session"]) {
        self.session = [[NSUserDefaults standardUserDefaults] stringForKey:@"session"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"session"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    
    CFDataRef data = nil;
#ifdef ENTERPRISE
    OSStatus err = SecItemCopyMatching((__bridge CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:(__bridge id)(kSecClassGenericPassword),  kSecClass, @"com.irccloud.enterprise", kSecAttrService, kCFBooleanTrue, kSecReturnData, nil], (CFTypeRef*)&data);
#else
    OSStatus err = SecItemCopyMatching((__bridge CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:(__bridge id)(kSecClassGenericPassword),  kSecClass, @"com.irccloud.IRCCloud", kSecAttrService, kCFBooleanTrue, kSecReturnData, nil], (CFTypeRef*)&data);
#endif
    if(!err) {
        _keychainFailCount = 0;
        _session = [[NSString alloc] initWithData:CFBridgingRelease(data) encoding:NSUTF8StringEncoding];
        return _session;
    } else {
        _keychainFailCount++;
        if(_keychainFailCount < 10 && err != errSecItemNotFound) {
            NSLog(@"Error fetching session: %i, trying again", (int)err);
            return self.session;
        } else {
            if(err == errSecItemNotFound)
                NSLog(@"Session key not found");
            else
                NSLog(@"Error fetching session: %i", (int)err);
            _keychainFailCount = 0;
            return nil;
        }
    }
}

-(void)setSession:(NSString *)session {
#ifdef ENTERPRISE
    SecItemDelete((__bridge CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:(__bridge id)(kSecClassGenericPassword),  kSecClass, @"com.irccloud.enterprise", kSecAttrService, nil]);
    if(session)
        SecItemAdd((__bridge CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:(__bridge id)(kSecClassGenericPassword),  kSecClass, @"com.irccloud.enterprise", kSecAttrService, [session dataUsingEncoding:NSUTF8StringEncoding], kSecValueData, (__bridge id)(kSecAttrAccessibleAlways), kSecAttrAccessible, nil], NULL);
#else
    SecItemDelete((__bridge CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:(__bridge id)(kSecClassGenericPassword),  kSecClass, @"com.irccloud.IRCCloud", kSecAttrService, nil]);
    if(session)
        SecItemAdd((__bridge CFDictionaryRef)[NSDictionary dictionaryWithObjectsAndKeys:(__bridge id)(kSecClassGenericPassword),  kSecClass, @"com.irccloud.IRCCloud", kSecAttrService, [session dataUsingEncoding:NSUTF8StringEncoding], kSecValueData, (__bridge id)(kSecAttrAccessibleAlways), kSecAttrAccessible, nil], NULL);
#endif
    _session = session;
}

-(BOOL)notifier {
    return _notifier;
}

-(void)setNotifier:(BOOL)notifier {
    _notifier = notifier;
    if(_state == kIRCCloudStateConnected && !notifier) {
        NSLog(@"Upgrading websocket");
        [self _sendRequest:@"upgrade_notifier" args:nil];
    }
}
@end
