//
//  WebSocketManager.h
//  SimpleChatClientTwo
//
//  Created by Antonio Carella on 8/18/15.
//  Copyright (c) 2015 SuperflousJazzHands. All rights reserved.
//

#import "WebSocket.h"

@interface WebSocketManager : WebSocket <WebSocketDelegate>

+ (id)sharedManager;

@end
