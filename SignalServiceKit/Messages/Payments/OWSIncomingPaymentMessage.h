//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import <SignalServiceKit/OWSPaymentMessage.h>
#import <SignalServiceKit/TSIncomingMessage.h>

NS_ASSUME_NONNULL_BEGIN

@class TSPaymentNotification;

@interface OWSIncomingPaymentMessage : TSIncomingMessage <OWSPaymentMessage>

@property (nonatomic, readonly, nullable) NSData *paymentRequest; // deprecated
@property (nonatomic, readonly, nullable) TSPaymentNotification *paymentNotification;
@property (nonatomic, readonly, nullable) NSData *paymentCancellation; // deprecated

- (instancetype)initIncomingMessageWithBuilder:(TSIncomingMessageBuilder *)messageBuilder
                           paymentNotification:(TSPaymentNotification *)paymentNotification NS_DESIGNATED_INITIALIZER
    NS_SWIFT_NAME(init(initIncomingMessageWithBuilder:paymentNotification:));

- (instancetype)initIncomingMessageWithBuilder:(TSIncomingMessageBuilder *)messageBuilder NS_UNAVAILABLE;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

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
         deprecated_sourceDeviceId:(unsigned int)deprecated_sourceDeviceId
                              read:(BOOL)read
           serverDeliveryTimestamp:(uint64_t)serverDeliveryTimestamp
                        serverGuid:(nullable NSString *)serverGuid
                   serverTimestamp:(nullable NSNumber *)serverTimestamp
                            viewed:(BOOL)viewed
                   wasReceivedByUD:(BOOL)wasReceivedByUD NS_UNAVAILABLE;

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
             paymentCancellation:(nullable NSData *)paymentCancellation
             paymentNotification:(nullable TSPaymentNotification *)paymentNotification
                  paymentRequest:(nullable NSData *)paymentRequest
NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(grdbId:uniqueId:receivedAtTimestamp:sortId:timestamp:uniqueThreadId:body:bodyRanges:contactShare:deprecated_attachmentIds:editState:expireStartedAt:expireTimerVersion:expiresAt:expiresInSeconds:giftBadge:isGroupStoryReply:isSmsMessageRestoredFromBackup:isViewOnceComplete:isViewOnceMessage:linkPreview:messageSticker:quotedMessage:storedShouldStartExpireTimer:storyAuthorUuidString:storyReactionEmoji:storyTimestamp:wasRemotelyDeleted:authorPhoneNumber:authorUUID:deprecated_sourceDeviceId:read:serverDeliveryTimestamp:serverGuid:serverTimestamp:viewed:wasReceivedByUD:paymentCancellation:paymentNotification:paymentRequest:));

// clang-format on

// --- CODE GENERATION MARKER

@end

NS_ASSUME_NONNULL_END