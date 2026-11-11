#import "VoxFlowObjCSupport.h"

NSException *_Nullable VFCatchObjCException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
