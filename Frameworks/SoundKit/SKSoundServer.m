/*
  Project: SoundKit framework.

  Copyright (C) 2019 Sergii Stoian

  This application is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public
  License as published by the Free Software Foundation; either
  version 2 of the License, or (at your option) any later version.

  This application is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  Library General Public License for more details.

  You should have received a copy of the GNU General Public
  License along with this library; if not, write to the Free
  Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.
*/
                                      
#import <dispatch/dispatch.h>

#import "PACard.h"
#import "PASink.h"
#import "PASource.h"
#import "PASinkInput.h"
#import "PAClient.h"
#import "PAStream.h"

#import "SKSoundDevice.h"
#import "SKSoundOut.h"
#import "SKSoundIn.h"
#import "SKSoundStream.h"
#import "SKSoundServer.h"
#import "SKSoundServerCallbacks.h"

static dispatch_queue_t _pa_q;
static SKSoundServer    *_server;

NSString *SKDeviceDidAddNotification = @"SKDeviceDidAdd";
NSString *SKDeviceDidChangeNotification = @"SKDeviceDidChange";
NSString *SKDeviceDidRemoveNotification = @"SKDeviceDidRemove";

@implementation SKSoundServer

+ (void)initialize
{
  if ([SKSoundServer class] == self) {
    _server = [SKSoundServer new];
  }
}
+ (id)sharedServer
{
  return _server;
}

- (void)dealloc
{
  fprintf(stderr, "[SoundKit] SoundServer -dealloc\n");
  
  [cardList release];
  [sinkList release];
  [sourceList release];
  [clientList release];
  [sinkInputList release];
  [sourceOutputList release];
  [savedStreamList release];
  
  [_userName release];
  [_hostName release];
  [_name release];
  [_version release];
  [_defaultSinkName release];
  [_defaultSourceName release];
  
  [super dealloc];
}
- (id)init
{
  return [self initOnHost:nil];
}
- (id)initOnHost:(NSString *)hostName
{
  pa_proplist *proplist;
  const char  *host = NULL;
  const char  *app_name = NULL;

  [super init];

  if (hostName != nil) {
    host = [hostName cString];
  }

  app_name = [[[NSProcessInfo processInfo] processName] cString];

  cardList = [NSMutableArray new];
  sinkList = [NSMutableArray new];
  sourceList = [NSMutableArray new];
  clientList = [NSMutableArray new];
  sinkInputList = [NSMutableArray new];
  sourceOutputList = [NSMutableArray new];
  savedStreamList = [NSMutableArray new];
  
  _pa_loop = pa_mainloop_new();
  _pa_api = pa_mainloop_get_api(_pa_loop);

  proplist = pa_proplist_new();
  pa_proplist_sets(proplist, PA_PROP_APPLICATION_NAME, app_name);
  pa_proplist_sets(proplist, PA_PROP_APPLICATION_ID, "org.nextspace.soundkit");
  pa_proplist_sets(proplist, PA_PROP_APPLICATION_ICON_NAME, "audio-card");
  pa_proplist_sets(proplist, PA_PROP_APPLICATION_VERSION, "0.1");

  _pa_ctx = pa_context_new_with_proplist(_pa_api, app_name, proplist);
  
  pa_proplist_free(proplist);
  
  pa_context_set_state_callback(_pa_ctx, context_state_cb, self);
  pa_context_connect(_pa_ctx, host, 0, NULL);

  _pa_q = dispatch_queue_create("org.nextspace.soundkit", NULL);
  dispatch_async(_pa_q, ^{
      while (pa_mainloop_iterate(_pa_loop, 1, NULL) >= 0) { ; }
      fprintf(stderr, "[SoundKit] mainloop exited!\n");
    });
  
  return self;
}
- (void)disconnect
{
  int retval = 0;
  
  fprintf(stderr, "[SoundKit] closing connection to server...\n");
  pa_mainloop_quit(_pa_loop, retval);
  pa_context_disconnect(_pa_ctx);
  pa_context_unref(_pa_ctx);
  pa_mainloop_free(_pa_loop);
  fprintf(stderr, "[SoundKit] connection to server closed.\n");
}

- (SKSoundDevice *)defaultCard
{
  return nil;
}
- (NSArray *)cardList
{
  NSMutableArray *list = [NSMutableArray new];
  SKSoundDevice  *device;

  for (PACard *card in cardList) {
    device = [[SKSoundDevice alloc] initWithServer:self];
    device.card = card;
    [list addObject:device];
    [device release];
  }
  return [list autorelease];
}

- (SKSoundOut *)outputWithSink:(PASink *)sink
{
  SKSoundOut *output;

  output = [[SKSoundOut alloc] init];
  output.card = [self cardWithIndex:sink.cardIndex];
  output.sink = sink;

  return [output autorelease];
}
- (SKSoundOut *)defaultOutput
{
  return [self outputWithSink:[self sinkWithName:_defaultSinkName]];
}
- (NSArray *)outputList
{
  NSMutableArray *list = [NSMutableArray new];

  for (PASink *sink in sinkList) {
    [list addObject:[self outputWithSink:sink]];
  }
  return [list autorelease];
}

- (SKSoundIn *)inputWithSource:(PASource *)source
{
  SKSoundIn *input;

  input = [[SKSoundIn alloc] init];
  input.card = [self cardWithIndex:source.cardIndex];
  input.source = source;

  return [input autorelease];
}
- (SKSoundIn *)defaultInput
{
  return [self inputWithSource:[self sourceWithName:_defaultSourceName]];
}
- (NSArray *)inputList
{
  NSMutableArray *list = [NSMutableArray new];

  for (PASource *source in sourceList) {
    [list addObject:[self inputWithSource:source]];
  }
  return [list autorelease];
}

- (SKSoundStream *)defaultPlayStream
{
  for (SKSoundStream *st in [self streamList]) {
    if (st.isPlayStream && st.isVirtual) {
      return st;
    }
  }
  return nil;
}
- (NSArray *)streamList
{
  NSMutableArray *list = [NSMutableArray new];
  SKSoundStream  *soundStream;

  for (PAStream *stream in savedStreamList) {
    soundStream = [[SKSoundStream alloc] initWithRestoredStream:stream
                                                         server:self];
    [list addObject:soundStream];
    [soundStream release];
  }
  return [list autorelease];
}

@end

// --- These methods are called by PA callbacks in the ---
// --- GCD thread with label "org.nextspace.soundkit"  ---

@implementation SKSoundServer (PulseAudio)

// Server
- (void)updateConnectionState:(NSNumber *)state
{
  // fprintf(stderr, "[SoundKit] connection state was updated.\n");
  _status = [state intValue];
  [[NSNotificationCenter defaultCenter]
      postNotificationName:SKServerStateDidChangeNotification
                    object:self];
}
- (void)updateServer:(NSValue *)value // server_info_cb(...)
{
  const pa_server_info *info;

  info = malloc(sizeof(const pa_server_info));
  [value getValue:(void *)info];

  _userName = [[NSString alloc] initWithCString:info->user_name];
  _hostName = [[NSString alloc] initWithCString:info->host_name];
  _name = [[NSString alloc] initWithCString:info->server_name];
  _version = [[NSString alloc] initWithCString:info->server_version];
  _defaultSinkName = [[NSString alloc] initWithCString:info->default_sink_name];
  _defaultSourceName = [[NSString alloc] initWithCString:info->default_source_name];
  
  free((void *)info);
}

// Card
- (void)updateCard:(NSValue *)value // card_sb(...)
{
  const pa_card_info *info;
  BOOL               isUpdated = NO;
  PACard             *card;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_card_info));
  [value getValue:(void *)info];

  for (card in cardList) {
    if (card.index == info->index) {
      fprintf(stderr, "[SoundKit] Card Update: %s.\n", info->name);
      [card updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    SKSoundDevice *soundDevice;
    card = [[PACard alloc] init];
    fprintf(stderr, "[SoundKit] Card Add: %s.\n", info->name);
    card.context = _pa_ctx;
    [card updateWithValue:value];
    [cardList addObject:card];
    [card release];
  }
  
  free((void *)info);
}
- (PACard *)cardWithIndex:(NSUInteger)index
{
  for (PACard *card in cardList) {
    if (card.index == index) {
      return card;
    }
  }
  return nil;
}
- (void)removeCardWithIndex:(NSNumber *)index // context_subscribe_cb(...)
{
  PACard *card = [self cardWithIndex:[index unsignedIntegerValue]];

  if (card != nil) {
    [cardList removeObject:card];
  }
}

// Sink
- (void)updateSink:(NSValue *)value // sink_cb(...)
{
  const pa_sink_info *info;
  PASink             *sink;
  BOOL               isUpdated = NO;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_sink_info));
  [value getValue:(void *)info];

  for (sink in sinkList) {
    if (sink.index == info->index) {
      fprintf(stderr, "[SoundKit] Sink Update: %s.\n", info->name);
      [sink updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    // Create Sink
    sink = [[PASink alloc] init];
    fprintf(stderr, "[SoundKit] Sink Add: %s.\n", info->name);
    [sink updateWithValue:value];
    sink.context = _pa_ctx;
    [sinkList addObject:sink];
    [sink release];
  }
  
  free((void *)info);  
}
- (PASink *)sinkWithIndex:(NSUInteger)index
{
  for (PASink *sink in sinkList) {
    if (sink.index == index) {
      return sink;
    }
  }
  return nil;
}
- (PASink *)sinkWithName:(NSString *)name
{
  for (PASink *sink in sinkList) {
    if ([name isEqualToString:sink.name]) {
      return sink;
    }
  }
  return nil;
}
- (void)removeSinkWithIndex:(NSNumber *)index // context_subscribe_cb(...)
{
  PASink *sink = [self sinkWithIndex:[index unsignedIntegerValue]];

  if (sink != nil) {
    [sinkList removeObject:sink];
  }  
}

// Source
- (void)updateSource:(NSValue *)value // source_cb(...)
{
  const pa_source_info *info;
  PASource             *source;
  BOOL                 isUpdated = NO;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_source_info));
  [value getValue:(void *)info];

  for (source in sourceList) {
    if (source.index == info->index) {
      fprintf(stderr, "[SoundKit] Source Update: %s.\n", info->name);
      [source updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    source = [[PASource alloc] init];
    fprintf(stderr, "[SoundKit] Source Add: %s.\n", info->name);
    [source updateWithValue:value];
    source.context = _pa_ctx;
    [sourceList addObject:source];
    [source release];
  }
  
  free((void *)info);  
}
- (PASource *)sourceWithIndex:(NSUInteger)index
{
  for (PASource *source in sourceList) {
    if (source.index == index) {
      return source;
    }
  }
  return nil;
}
- (PASource *)sourceWithName:(NSString *)name
{
  for (PASource *source in sourceList) {
    if ([name isEqualToString:source.name]) {
      return source;
    }
  }
  return nil;
}
- (void)removeSourceWithIndex:(NSNumber *)index // context_subscribe_cb(...)
{
  PASource *source = [self sourceWithIndex:[index unsignedIntegerValue]];

  if (source != nil) {
    [sourceList removeObject:source];
  }  
}

// Sink Input
- (void)updateSinkInput:(NSValue *)value // sink_input_cb(...)
{
  const pa_sink_input_info *info;
  BOOL  isUpdated = NO;
  PASinkInput *sinkInput;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_sink_input_info));
  [value getValue:(void *)info];

  for (sinkInput in sinkInputList) {
    if (sinkInput.index == info->index) {
      fprintf(stderr, "[SoundKit] Sink Input Update: %s.\n", info->name);
      [sinkInput updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    sinkInput = [[PASinkInput alloc] init];
    fprintf(stderr, "[SoundKit] Sink Input Add: %s.\n", info->name);
    [sinkInput updateWithValue:value];
    sinkInput.context = _pa_ctx;
    [sinkInputList addObject:sinkInput];
    [sinkInput release];
  }
  
  free((void *)info);
}
- (PASinkInput *)sinkInputWithClientIndex:(NSUInteger)index
{
  for (PASinkInput *sinkInput in sinkInputList) {
    if (sinkInput.clientIndex == index) {
      return sinkInput;
    }
  }
  return nil;
}
- (PASinkInput *)sinkInputWithIndex:(NSUInteger)index
{
  for (PASinkInput *sinkInput in sinkInputList) {
    if (sinkInput.index == index) {
      return sinkInput;
    }
  }
  return nil;
}
- (void)removeSinkInputWithIndex:(NSNumber *)index // context_subscribe_cb(...)
{
  PASinkInput *sinkInput = [self sinkInputWithIndex:[index unsignedIntegerValue]];
  if (sinkInput != nil) {
    [sinkInputList removeObject:sinkInput];
  }
}

// TODO: Source Output
- (void)updateSourceOutput:(NSValue *)value // source_outout_cb(...)
{
}
- (void)removeSourceOutputWithIndex:(NSNumber *)index // context_subscribe_cb(...)
{
}

// Client
- (void)updateClient:(NSValue *)value // client_sb(...)
{
  const pa_client_info *info;
  BOOL                 isUpdated = NO;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_client_info));
  [value getValue:(void *)info];

  for (PAClient *c in clientList) {
    if ([c index] == info->index) {
      fprintf(stderr, "[SoundKit] Client Update: %s.\n", info->name);
      [c updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    PAClient *client = [[PAClient alloc] init];
    fprintf(stderr, "[SoundKit] Add: %s.\n", info->name);
    [client updateWithValue:value];
    [clientList addObject:client];
    [client release];
  }
  
  free((void *)info);
}
- (PAClient *)clientWithIndex:(NSNumber *)index
{
  for (PAClient *client in clientList) {
    if ([client index] == [index unsignedIntegerValue]) {
      return client;
    }
  }
  return nil;
}
- (PAClient *)clientWithName:(NSString *)name
{
  for (PAClient *client in clientList) {
    if ([name isEqualToString:client.name]) {
      return client;
    }
  }
  return nil;
}
- (void)removeClientWithIndex:(NSNumber *)index // context_subscribe_cb(...)
{
  PAClient *client = [self clientWithIndex:index];

  if (client != nil) {
    [clientList removeObject:client];
  }
}

// Restored Stream
- (void)updateStream:(NSValue *)value // ext_stream_restore_read_cb(...)
{
  const pa_ext_stream_restore_info *info;
  BOOL                             isUpdated = NO;
  NSString                         *streamName;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_ext_stream_restore_info));
  [value getValue:(void *)info];
  
  streamName = [NSString stringWithCString:info->name];
  for (PAStream *s in savedStreamList) {
    if ([[s name] isEqualToString:streamName]) {
      fprintf(stderr, "[SoundKit] Stream Update: %s.\n", info->name);
      [s updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    PAStream *s = [[PAStream alloc] init];
    fprintf(stderr, "[SoundKit] Stream Add: %s.\n", info->name);
    [s updateWithValue:value];
    [savedStreamList addObject:s];
    [s release];
  }
  
  free((void *)info);
}

@end
