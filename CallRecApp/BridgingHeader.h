// CallRec-Bridging-Header.h
// Exposes C helper functions to Swift.
//
// Note: We do NOT import SharedProtocol.h or RingBuffer.h directly because
// they use _Alignas and volatile which don't import cleanly into Swift.
// Instead, SharedMemoryHelpers provides an opaque C API that Swift can call.

#import "../Common/AudioConstants.h"
#import "../Common/SharedMemoryHelpers.h"
