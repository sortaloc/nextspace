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
#import "PASinkInput.h"
#import "PAClient.h"
#import "PAStream.h"

#import "NXSoundOut.h"
#import "NXSoundServer.h"
#import "NXSoundServerCallbacks.h"

static dispatch_queue_t _pa_q;
static NXSoundServer    *_server;

NSString *SKDeviceDidAddNotification = @"SKDeviceDidAdd";
NSString *SKDeviceDidChangeNotification = @"SKDeviceDidChange";
NSString *SKDeviceDidRemoveNotification = @"SKDeviceDidRemove";

@implementation NXSoundServer

+ (id)defaultServer
{
  if (_server == nil) {
    _server = [[NXSoundServer alloc] init];
  }

  return [_server autorelease];
}

- (void)dealloc
{
  int retval = 0;

  fprintf(stderr, "[SoundKit] closing connection to server...\n");
  pa_mainloop_quit(_pa_loop, retval);
  pa_context_disconnect(_pa_ctx);
  pa_context_unref(_pa_ctx);
  pa_mainloop_free(_pa_loop);
  fprintf(stderr, "[SoundKit] connection to server closed.\n");
  
  if (_host) {
    [_host release];
  }
  [super dealloc];
}

- (id)init
{
  return [self initOnHost:nil withName:@"SoundKit"];
}

- (id)initOnHost:(NSString *)hostName
        withName:(NSString *)appName
{
  pa_proplist *proplist;
  const char  *host = NULL;

  [super init];

  if (hostName != nil) {
    _host = [[NSString alloc] initWithString:hostName];
    host = [hostName cString];
  }
  
  _pa_loop = pa_mainloop_new();
  _pa_api = pa_mainloop_get_api(_pa_loop);

  proplist = pa_proplist_new();
  pa_proplist_sets(proplist, PA_PROP_APPLICATION_NAME, [appName cString]);
  pa_proplist_sets(proplist, PA_PROP_APPLICATION_ID, "org.nextspace.soundkit");
  pa_proplist_sets(proplist, PA_PROP_APPLICATION_ICON_NAME, "audio-card");
  // pa_proplist_sets(proplist, PA_PROP_APPLICATION_VERSION, "0.1");

  _pa_ctx = pa_context_new_with_proplist(_pa_api, [appName cString], proplist);
  
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

- (NSString *)host
{
  return _host;
}

- (SKConnectionState)state
{
  return connectionState;
}

- (NXSoundOut *)defaultOutput
{
  return nil;
}

@end

// --- These methods are called by PA callbacks ---

@implementation NXSoundServer (PulseAudioEvents)

- (void)updateConnectionState:(NSNumber *)state
{
  fprintf(stderr, "[SoundKit] connection state was updated.\n");
  connectionState = [state intValue];
  [[NSNotificationCenter defaultCenter]
      postNotificationName:SKServerStateDidChangeNotification
                    object:self];
}

// client_sb(...)
- (void)updateClient:(NSValue *)value
{
  const pa_client_info *info;
  BOOL                 isUpdated = NO;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_client_info));
  [value getValue:(void *)info];

  for (PAClient *c in clientList) {
    if ([c index] == info->index) {
      [c updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    PAClient *client = [[PAClient alloc] init];
    NSLog(@"Add Client: %s", info->name);
    [client updateWithValue:value];
    [clientList addObject:client];
    [client release];
    // [self reloadBrowser:streamsBrowser];
  }
  
  free((void *)info);
}
// context_subscribe_cb(...)
- (void)removeClientWithIndex:(NSNumber *)index
{
  PAClient *client;

  for (PAClient *c in clientList) {
    if ([c index] == [index unsignedIntegerValue]) {
      client = c;
      break;
    }
  }

  if (client != nil) {
    [clientList removeObject:client];
    // [self reloadBrowser:streamsBrowser];
  }
}

// ext_stream_restore_read_cb(...)
- (void)updateStream:(NSValue *)value
{
  const pa_ext_stream_restore_info *info;
  BOOL                             isUpdated = NO;
  NSString                         *streamName;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_ext_stream_restore_info));
  [value getValue:(void *)info];
  
  streamName = [NSString stringWithCString:info->name];
  for (PAStream *s in streamList) {
    if ([[s name] isEqualToString:streamName]) {
      [s updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    PAStream *s = [[PAStream alloc] init];
    [s updateWithValue:value];
    [streamList addObject:s];
    [s release];
    // [self reloadBrowser:streamsBrowser];
  }
  // [self browserClick:appBrowser];
  
  free((void *)info);
}

// sink_cb(...)
- (void)updateSink:(NSValue *)value
{
  const pa_sink_info *info;
  PASink *sink;
  BOOL   isUpdated = NO;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_sink_info));
  [value getValue:(void *)info];

  for (sink in sinkList) {
    if (sink.index == info->index) {
      NSLog(@"Update Sink: %s", info->name);
      [sink updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    sink = [[PASink alloc] init];
    NSLog(@"Add Sink: %s", info->name);
    [sink updateWithValue:value];
    [sinkList addObject:sink];
    [sink release];
  }
  
  // [self updateOutputDeviceList];
  
  free((void *)info);  
}
// context_subscribe_cb(...)
- (void)removeSinkWithIndex:(NSNumber *)index
{
  PASink     *sink;
  NSUInteger idx = [index unsignedIntegerValue];

  for (PASink *s in sinkList) {
    if (s.index == idx) {
      sink = s;
      break;
    }
  }

  if (sink != nil) {
    [sinkList removeObject:sink];
    // [self updateOutputDeviceList];
  }  
}

- (void)updateSinkInput:(NSValue *)value
{
  const pa_sink_input_info *info;
  BOOL  isUpdated = NO;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_sink_input_info));
  [value getValue:(void *)info];

  for (PASinkInput *si in sinkInputList) {
    if (si.index == info->index) {
      NSLog(@"Update Sink Input: %s", info->name);
      [si updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    PASinkInput *si = [[PASinkInput alloc] init];
    NSLog(@"Add Sink Input: %s", info->name);
    [si updateWithValue:value];
    si.context = _pa_ctx;
    [sinkInputList addObject:si];
    // [self reloadBrowser:streamsBrowser];
    [si release];
  }
  
  // [self browserClick:appBrowser];
  
  free((void *)info);
}
// context_subscribe_cb(...)
- (void)removeSinkInputWithIndex:(NSNumber *)index
{
  PASinkInput *sinkInput;
  NSUInteger  idx = [index unsignedIntegerValue];

  for (PASinkInput *si in sinkInputList) {
    if (si.index == idx) {
      sinkInput = si;
      break;
    }
  }

  if (sinkInput != nil) {
    [sinkInputList removeObject:sinkInput];
    // [self reloadBrowser:streamsBrowser];
  }
}

- (void)updateSource:(NSValue *)value
{
}
// context_subscribe_cb(...)
- (void)removeSourceWithIndex:(NSNumber *)index
{
}
- (void)updateSourceOutput:(NSValue *)value
{
}
// context_subscribe_cb(...)
- (void)removeSourceOutputWithIndex:(NSNumber *)index
{
}

- (void)updateServer:(NSValue *)value
{
  const pa_server_info *info;

  info = malloc(sizeof(const pa_server_info));
  [value getValue:(void *)info];

  // TODO: get NXSoundOut for default_sink_name
  defaultSinkName = [[NSString alloc] initWithCString:info->default_sink_name];
  // TODO: get NXSoundIn for default_source_name
  defaultSourceName = [[NSString alloc] initWithCString:info->default_source_name];
  
  free((void *)info);
}
- (void)updateCard:(NSValue *)value
{
  const pa_card_info *info;
  BOOL               isUpdated = NO;

  // Convert PA structure into NSDictionary
  info = malloc(sizeof(const pa_card_info));
  [value getValue:(void *)info];

  fprintf(stderr, "Card: %s (%i ports, %i profiles)\n",
          info->name, info->n_ports, info->n_profiles);
  fprintf(stderr, "\tDriver: %s\n", info->driver);
  
  fprintf(stderr, "\tProfiles:\n");
  for (unsigned i = 0; i < info->n_profiles; i++) {
    fprintf(stderr, "\t\t[%i] %s (%s)\n",
            info->profiles2[i]->priority,
            info->profiles2[i]->name, info->profiles2[i]->description);
  }
  fprintf(stderr, "\tActive profile: [%i] %s\n",
          info->active_profile->priority, info->active_profile->name);

  fprintf(stderr, "\tPorts:\n");
  for (unsigned i = 0; i < info->n_ports; i++) {
    fprintf(stderr, "\t\t[%i] %s (%s)\n",
            info->ports[i]->priority,
            info->ports[i]->name, info->ports[i]->description);
  }

  for (PACard *card in cardList) {
    if (card.index == info->index) {
      NSLog(@"Update Card: %s", info->name);
      [card updateWithValue:value];
      isUpdated = YES;
      break;
    }
  }

  if (isUpdated == NO) {
    PACard *card = [[PACard alloc] init];
    NSLog(@"Add Card: %s", info->name);
    [card updateWithValue:value];
    [cardList addObject:card];
    [card release];
  }
  
  free((void *)info);
  
  // [self updateOutputDeviceList];
}
// context_subscribe_cb(...)
- (void)removeCardWithIndex:(NSNumber *)index
{
  for (PACard *card in cardList) {
    if (card.index == [index unsignedIntegerValue]) {
      NSLog(@"Remove Card: %@", card.name);
      [cardList removeObject:card];
      // [self updateOutputDeviceList];
      break;
    }
  }
}

@end
