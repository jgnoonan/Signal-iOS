//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "TSIncomingMessage.h"
#import "OWSDisappearingMessagesConfiguration.h"
#import "TSContactThread.h"
#import "TSGroupThread.h"
#import <SignalServiceKit/NSDate+OWS.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

@interface TSIncomingMessage ()

@property (nonatomic, getter=wasRead) BOOL read;
@property (nonatomic, getter=wasViewed) BOOL viewed;

@property (nonatomic, nullable) NSNumber *serverTimestamp;
@property (nonatomic, readonly) NSUInteger incomingMessageSchemaVersion;

@end

#pragma mark -

const NSUInteger TSIncomingMessageSchemaVersion = 1;

@implementation TSIncomingMessage

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }

    if (_incomingMessageSchemaVersion < 1) {
        _authorPhoneNumber = [coder decodeObjectForKey:@"authorId"];
        if (_authorPhoneNumber == nil) {
            _authorPhoneNumber = [TSContactThread legacyContactPhoneNumberFromThreadId:self.uniqueThreadId];
        }
    }

    if (_authorUUID != nil) {
        _authorPhoneNumber = nil;
    }

    _incomingMessageSchemaVersion = TSIncomingMessageSchemaVersion;

    return self;
}

- (instancetype)initIncomingMessageWithBuilder:(TSIncomingMessageBuilder *)incomingMessageBuilder
{
    self = [super initMessageWithBuilder:incomingMessageBuilder];

    if (!self) {
        return self;
    }

    _authorUUID = incomingMessageBuilder.authorAciObjC.serviceIdUppercaseString;
    _authorPhoneNumber = incomingMessageBuilder.authorE164ObjC.stringValue;
    _deprecated_sourceDeviceId = nil;
    _read = incomingMessageBuilder.read;
    if (incomingMessageBuilder.serverTimestamp > 0) {
        _serverTimestamp = [NSNumber numberWithUnsignedLongLong:incomingMessageBuilder.serverTimestamp];
    } else {
        _serverTimestamp = nil;
    }
    _serverDeliveryTimestamp = incomingMessageBuilder.serverDeliveryTimestamp;
    _serverGuid = incomingMessageBuilder.serverGuid;
    _wasReceivedByUD = incomingMessageBuilder.wasReceivedByUD;

    _incomingMessageSchemaVersion = TSIncomingMessageSchemaVersion;

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
                            body:(nullable NSString *)body
                      bodyRanges:(nullable MessageBodyRanges *)bodyRanges
                    contactShare:(nullable OWSContact *)contactShare
        deprecated_attachmentIds:(nullable NSArray<NSString *> *)deprecated_attachmentIds
                       editState:(TSEditState)editState
                 expireStartedAt:(uint64_t)expireStartedAt
              expireTimerVersion:(nullable NSNumber *)expireTimerVersion
                       expiresAt:(uint64_t)expiresAt
                expiresInSeconds:(unsigned int)expiresInSeconds
                       giftBadge:(nullable OWSGiftBadge *)giftBadge
               isGroupStoryReply:(BOOL)isGroupStoryReply
  isSmsMessageRestoredFromBackup:(BOOL)isSmsMessageRestoredFromBackup
              isViewOnceComplete:(BOOL)isViewOnceComplete
               isViewOnceMessage:(BOOL)isViewOnceMessage
                     linkPreview:(nullable OWSLinkPreview *)linkPreview
                  messageSticker:(nullable MessageSticker *)messageSticker
                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
    storedShouldStartExpireTimer:(BOOL)storedShouldStartExpireTimer
           storyAuthorUuidString:(nullable NSString *)storyAuthorUuidString
              storyReactionEmoji:(nullable NSString *)storyReactionEmoji
                  storyTimestamp:(nullable NSNumber *)storyTimestamp
              wasRemotelyDeleted:(BOOL)wasRemotelyDeleted
               authorPhoneNumber:(nullable NSString *)authorPhoneNumber
                      authorUUID:(nullable NSString *)authorUUID
       deprecated_sourceDeviceId:(nullable NSNumber *)deprecated_sourceDeviceId
                            read:(BOOL)read
         serverDeliveryTimestamp:(uint64_t)serverDeliveryTimestamp
                      serverGuid:(nullable NSString *)serverGuid
                 serverTimestamp:(nullable NSNumber *)serverTimestamp
                          viewed:(BOOL)viewed
                 wasReceivedByUD:(BOOL)wasReceivedByUD
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId
               receivedAtTimestamp:receivedAtTimestamp
                            sortId:sortId
                         timestamp:timestamp
                    uniqueThreadId:uniqueThreadId
                              body:body
                        bodyRanges:bodyRanges
                      contactShare:contactShare
          deprecated_attachmentIds:deprecated_attachmentIds
                         editState:editState
                   expireStartedAt:expireStartedAt
                expireTimerVersion:expireTimerVersion
                         expiresAt:expiresAt
                  expiresInSeconds:expiresInSeconds
                         giftBadge:giftBadge
                 isGroupStoryReply:isGroupStoryReply
    isSmsMessageRestoredFromBackup:isSmsMessageRestoredFromBackup
                isViewOnceComplete:isViewOnceComplete
                 isViewOnceMessage:isViewOnceMessage
                       linkPreview:linkPreview
                    messageSticker:messageSticker
                     quotedMessage:quotedMessage
      storedShouldStartExpireTimer:storedShouldStartExpireTimer
             storyAuthorUuidString:storyAuthorUuidString
                storyReactionEmoji:storyReactionEmoji
                    storyTimestamp:storyTimestamp
                wasRemotelyDeleted:wasRemotelyDeleted];

    if (!self) {
        return self;
    }

    if (authorUUID != nil) {
        _authorUUID = authorUUID;
    } else if (authorPhoneNumber != nil) {
        _authorPhoneNumber = authorPhoneNumber;
    }
    _deprecated_sourceDeviceId = deprecated_sourceDeviceId;
    _read = read;
    _serverDeliveryTimestamp = serverDeliveryTimestamp;
    _serverGuid = serverGuid;
    _serverTimestamp = serverTimestamp;
    _viewed = viewed;
    _wasReceivedByUD = wasReceivedByUD;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

- (OWSInteractionType)interactionType
{
    return OWSInteractionType_IncomingMessage;
}

#pragma mark - OWSReadTracking

// This method will be called after every insert and update, so it needs
// to be cheap.
- (BOOL)shouldStartExpireTimer
{
    if (self.hasPerConversationExpirationStarted) {
        // Expiration already started.
        return YES;
    } else if (!self.hasPerConversationExpiration) {
        return NO;
    } else {
        return self.wasRead && [super shouldStartExpireTimer];
    }
}

- (void)debugonly_markAsReadNowWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    // In various tests and debug UI we often want to make messages as already read.
    // We want to do this without triggering sending read receipts, so we pretend it was
    // read on a linked device.
    [self markAsReadAtTimestamp:[NSDate ows_millisecondTimeStamp]
                          thread:[self threadWithTx:transaction]
                    circumstance:OWSReceiptCircumstanceOnLinkedDevice
        shouldClearNotifications:YES
                     transaction:transaction];
}

- (void)markAsReadAtTimestamp:(uint64_t)readTimestamp
                       thread:(TSThread *)thread
                 circumstance:(OWSReceiptCircumstance)circumstance
     shouldClearNotifications:(BOOL)shouldClearNotifications
                  transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    if (self.read && readTimestamp >= self.expireStartedAt) {
        return;
    }

    [self anyUpdateIncomingMessageWithTransaction:transaction
                                            block:^(TSIncomingMessage *message) {
                                                message.read = YES;
                                                // No need to update MessageAttachmentReferences table;
                                                // this doesn's change isPastRevision state.
                                                if (self.editState == TSEditState_LatestRevisionUnread) {
                                                    message.editState = TSEditState_LatestRevisionRead;
                                                }
                                            }];

    // readTimestamp may be earlier than now, so backdate the expiration if necessary.
    [SSKEnvironment.shared.disappearingMessagesJobRef startAnyExpirationForMessage:self
                                                               expirationStartedAt:readTimestamp
                                                                       transaction:transaction];

    [SSKEnvironment.shared.receiptManagerRef messageWasRead:self
                                                     thread:thread
                                               circumstance:circumstance
                                                transaction:transaction];

    if (shouldClearNotifications) {
        [NotificationPresenterObjC cancelNotificationsForMessageId:self.uniqueId];
    }
}

- (void)markAsViewedAtTimestamp:(uint64_t)viewedTimestamp
                         thread:(TSThread *)thread
                   circumstance:(OWSReceiptCircumstance)circumstance
                    transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);

    if (self.viewed) {
        return;
    }

    [self anyUpdateIncomingMessageWithTransaction:transaction
                                            block:^(TSIncomingMessage *message) { message.viewed = YES; }];

    [SSKEnvironment.shared.receiptManagerRef messageWasViewed:self
                                                       thread:thread
                                                 circumstance:circumstance
                                                  transaction:transaction];
}

- (SignalServiceAddress *)authorAddress
{
    return [SignalServiceAddress legacyAddressWithServiceIdString:self.authorUUID phoneNumber:self.authorPhoneNumber];
}

@end

NS_ASSUME_NONNULL_END