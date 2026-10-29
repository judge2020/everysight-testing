#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// All methods and callbacks run on the main thread. IDs cross the bridge as strings.
@interface DiscordBridge : NSObject
@property(nonatomic, copy, nullable) void (^statusChanged)(NSString *status, BOOL ready);
@property(nonatomic, copy, nullable) void (^messageChanged)(NSDictionary *message, BOOL incoming);
@property(nonatomic, copy, nullable) void (^messageDeleted)(NSString *messageID);
@property(nonatomic, copy, nullable) void (^sessionCleared)(void);
@property(nonatomic, readonly) BOOL ready;
@property(nonatomic, readonly) BOOL configured;
- (void)pump;
- (void)signIn;
- (void)restoreSession;
- (void)signOut;
- (void)setShowingChat:(BOOL)showing;
- (void)loadConversations:(void (^)(NSArray<NSDictionary *> *conversations, NSString * _Nullable error))completion;
- (void)loadMessagesForUser:(NSString *)userID completion:(void (^)(NSArray<NSDictionary *> *messages, NSString * _Nullable error))completion;
- (void)openMessage:(NSString *)messageID;
@end
NS_ASSUME_NONNULL_END
