//
//  WebSocketManager.m
//  SimpleChatClientTwo
//
//  Created by Antonio Carella on 8/18/15.
//  Copyright (c) 2015 SuperflousJazzHands. All rights reserved.
//

#import "WebSocketManager.h"
#import "WebSocketConnectConfig.h"
@interface WebSocketManager()

@property (strong, nonatomic) WebSocket *socket;

@end

@implementation WebSocketManager

+ (id)sharedManager {

    static WebSocketManager *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] init];
    });
    return sharedMyManager;
}

- (instancetype)init
{
    
    self = [super init];
    if (self) {
        WebSocketConnectConfig *config = [[WebSocketConnectConfig alloc]initWithURLString:@"localhost" origin:nil protocols:@[@"ws", @"wss"] tlsSettings:nil headers:nil verifySecurityKey:nil extensions:nil];
        self.socket = [[WebSocket alloc]initWithConfig:config delegate:self];
        [self.socket open];
    }
    return self;
}

/**
 * Called when the web socket connects and is ready for reading and writing.
 **/
- (void) webSocketDidOpen:(WebSocket *)socket{
    NSLog(@"Web Socket Open.");
    
}

/**
 * Called when the web socket closes. aError will be nil if it closes cleanly.
 **/
- (void) webSocket:(WebSocket *)socket didClose:(NSUInteger) aStatusCode message:(NSString*) aMessage error:(NSError*) aError{
    NSLog(@"Web Socket did close.");
    
}

/**
 * Called when the web socket receives an error. Such an error can result in the
 socket being closed.
 **/
- (void) webSocket:(WebSocket *)socket didReceiveError:(NSError*) aError{
    NSLog(@"Web Socket received error: %@", aError);
    
}

/**
 * Called when the web socket receives a message.
 **/
- (void) webSocket:(WebSocket *)socket didReceiveTextMessage:(NSString*) aMessage{
    NSLog(@"Web Socket received a text message.");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.superflousjazzhands.AutoComplete.newMessage" object:aMessage];
}

/**
 * Called when the web socket receives a message.
 **/
- (void) webSocket:(WebSocket *)socket didReceiveBinaryMessage:(NSData*) aMessage{
    NSLog(@"Web Socket received a binary message.");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"com.superflousjazzhands.AutoComplete.newData" object:aMessage];
}

/**
 * Called when pong is sent... For keep-alive optimization.
 **/
- (void) didSendPong:(NSData*) aMessage{
    NSLog(@"Web Socket did send pong.");
    
}


@end
