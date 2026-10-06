#pragma once
#import <Foundation/Foundation.h>

// Cross-layer diagnostic state for the shared audio pipeline.
// Shared/Audio publishes its state here; Diagnostics can read it through Core without importing Shared.
void SGAudioStatusSet(BOOL available, NSString *reason);
BOOL SGAudioStatusAvailable(void);
NSString *SGAudioStatusReason(void);
