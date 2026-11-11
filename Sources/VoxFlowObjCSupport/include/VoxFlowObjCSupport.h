#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil.
///
/// Swift cannot catch NSException. One that unwinds through Swift frames skips
/// their cleanup; on 2026-11-06 an AVAudioEngine exception did that inside a
/// main-actor Task, AppKit swallowed it, and the next isolation check crashed
/// on a stale executor record. Calls that can raise go through this first.
NSException *_Nullable VFCatchObjCException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
