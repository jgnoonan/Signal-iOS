//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "OWSGroupCallMessage.h"
#import "TSGroupThread.h"
#import <SignalServiceKit/NSDate+OWS.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark -

@implementation OWSGroupCallMessage

- (instancetype)initWithJoinedMemberAcis:(NSArray<AciObjC *> *)joinedMemberAcis
                              creatorAci:(nullable AciObjC *)creatorAci
                                  thread:(TSGroupThread *)thread
                         sentAtTimestamp:(uint64_t)sentAtTimestamp
{
    self = [super initWithTimestamp:sentAtTimestamp
                receivedAtTimestamp:[NSDate ows_millisecondTimeStamp]
                             thread:thread];

    if (!self) {
        return self;
    }

    NSMutableArray<NSString *> *uuids = [[NSMutableArray alloc] initWithCapacity:joinedMemberAcis.count];
    for (AciObjC *aci in joinedMemberAcis) {
        [uuids addObject:aci.serviceIdUppercaseString];
    }
    _joinedMemberUuids = uuids;
    _hasEnded = joinedMemberAcis.count == 0;
    _creatorUuid = creatorAci.serviceIdUppercaseString;

    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
             receivedAtTimestamp:(uint64_t)receivedAtTimestamp
                          sortId:(uint64_t)sortId
                       timestamp:(uint64_t)timestamp
                  uniqueThreadId:(NSString *)uniqueThreadId
                     creatorUuid:(nullable NSString *)creatorUuid
                           eraId:(nullable NSString *)eraId
                        hasEnded:(BOOL)hasEnded
               joinedMemberUuids:(nullable NSArray<NSString *> *)joinedMemberUuids
                            read:(BOOL)read
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId
               receivedAtTimestamp:receivedAtTimestamp
                            sortId:sortId
                         timestamp:timestamp
                    uniqueThreadId:uniqueThreadId];

    if (!self) {
        return self;
    }

    _creatorUuid = creatorUuid;
    _eraId = eraId;
    _hasEnded = hasEnded;
    _joinedMemberUuids = joinedMemberUuids;
    _read = read;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    return [super initWithCoder:coder];
}

- (NSArray<AciObjC *> *)joinedMemberAcis
{
    NSArray<NSString *> *_Nullable uuids = self.joinedMemberUuids;
    NSMutableArray<AciObjC *> *result = [[NSMutableArray alloc] initWithCapacity:uuids.count];
    for (NSString *aciString in uuids) {
        [result addObject:[[AciObjC alloc] initWithAciString:aciString]];
    }
    return result;
}

- (nullable AciObjC *)creatorAci
{
    if (self.creatorUuid) {
        return [[AciObjC alloc] initWithAciString:self.creatorUuid];
    } else {
        return nil;
    }
}

- (OWSInteractionType)interactionType
{
    return OWSInteractionType_Call;
}

@end

NS_ASSUME_NONNULL_END