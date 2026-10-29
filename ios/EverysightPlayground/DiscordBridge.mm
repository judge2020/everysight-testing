#import "DiscordBridge.h"
#import <Security/Security.h>
#define DISCORDPP_IMPLEMENTATION
#include <discord_partner_sdk/discordpp.h>
#include <charconv>

static uint64_t ApplicationID() {
    id raw = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DiscordApplicationID"];
    if (![raw isKindOfClass:NSString.class]) return 0;
    std::string value([(NSString *)raw UTF8String]);
    uint64_t applicationID = 0;
    auto result = std::from_chars(value.data(), value.data() + value.size(), applicationID);
    return result.ec == std::errc() && result.ptr == value.data() + value.size() ? applicationID : 0;
}
static NSString *String(std::string const &s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
static NSString *ID(uint64_t value) { return [NSString stringWithFormat:@"%llu", (unsigned long long)value]; }
static NSDictionary *KeyQuery() {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".discord"],
             (__bridge id)kSecAttrAccount: @"refresh-token"};
}
static NSString *ReadRefreshToken() {
    NSMutableDictionary *q = [KeyQuery() mutableCopy];
    q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &data) != errSecSuccess) return nil;
    return [[NSString alloc] initWithData:CFBridgingRelease(data) encoding:NSUTF8StringEncoding];
}
static BOOL SaveRefreshToken(NSString *token) {
    NSDictionary *values = @{(__bridge id)kSecValueData: [token dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)KeyQuery(), (__bridge CFDictionaryRef)values);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *q = [KeyQuery() mutableCopy]; [q addEntriesFromDictionary:values];
        status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    }
    return status == errSecSuccess;
}

@implementation DiscordBridge {
    std::unique_ptr<discordpp::Client> _client;
    BOOL _ready;
    BOOL _authenticating;
    BOOL _wanted;
    BOOL _hasSession;
    NSUInteger _generation;
    NSDate *_refreshAt;
    NSDate *_retryAt;
    NSTimeInterval _retryDelay;
    NSString *_refreshToken;
}
- (instancetype)init {
    if ((self = [super init])) {
        _client = std::make_unique<discordpp::Client>();
        if (self.configured) _client->SetApplicationId(ApplicationID());
        _retryDelay = 2;
        __weak DiscordBridge *weakSelf = self;
        _client->SetStatusChangedCallback([weakSelf](auto status, auto error, int32_t detail) {
            DiscordBridge *owner = weakSelf; if (!owner) return;
            owner->_ready = owner->_wanted && owner->_hasSession && status == discordpp::Client::Status::Ready;
            if (owner->_ready) { owner->_retryDelay = 2; owner->_retryAt = nil; }
            if (status == discordpp::Client::Status::Disconnected && owner->_wanted && owner->_hasSession) {
                owner->_retryAt = [NSDate dateWithTimeIntervalSinceNow:owner->_retryDelay];
                owner->_retryDelay = MIN(owner->_retryDelay * 2, 60);
            }
            NSString *text = String(discordpp::Client::StatusToString(status));
            if (error != discordpp::Client::Error::None)
                text = [text stringByAppendingFormat:@" · %@ (%d)", String(discordpp::Client::ErrorToString(error)), detail];
            [owner status:text];
        });
        _client->SetMessageCreatedCallback([weakSelf](uint64_t messageID) { [weakSelf receive:messageID created:YES]; });
        _client->SetMessageUpdatedCallback([weakSelf](uint64_t messageID) { [weakSelf receive:messageID created:NO]; });
        _client->SetMessageDeletedCallback([weakSelf](uint64_t messageID, uint64_t channelID) {
            DiscordBridge *owner = weakSelf;
            if (owner.ready && owner.messageDeleted) owner.messageDeleted(ID(messageID));
        });
        // No file logging, voice, microphone, presence publication, or send-message calls.
    }
    return self;
}
- (BOOL)ready { return _ready; }
- (BOOL)configured { return ApplicationID() != 0; }
- (void)status:(NSString *)text { if (self.statusChanged) self.statusChanged(text, _ready); }
- (void)pump {
    discordpp::RunCallbacks();
    if (!_wanted || _authenticating) return;
    if (_refreshToken.length && _refreshAt && [_refreshAt timeIntervalSinceNow] <= 0) [self refresh];
    else if (_hasSession && _retryAt && [_retryAt timeIntervalSinceNow] <= 0) { _retryAt = nil; _client->Connect(); }
}
- (NSDictionary *)dictionary:(discordpp::MessageHandle const &)message {
    if (message.Lobby() || !message.RecipientId()) return nil;
    auto author = message.Author();
    auto recipient = message.Recipient();
    NSString *content = String(message.Content());
    NSMutableDictionary *additionalDetails = [NSMutableDictionary dictionary];
    if (auto additional = message.AdditionalContent()) {
        NSString *type = String(discordpp::AdditionalContent::TypeToString(additional->Type()));
        if (additional->Type() == discordpp::AdditionalContentType::VoiceMessage) type = @"Voice message";
        if (additional->Type() == discordpp::AdditionalContentType::Other) type = @"Additional content";
        additionalDetails[@"type"] = type;
        additionalDetails[@"count"] = @(additional->Count());
        NSString *detail = additional->Count() ? [NSString stringWithFormat:@"%@ ×%u", type, (unsigned)additional->Count()] : type;
        if (auto title = additional->Title(); title && !title->empty()) {
            additionalDetails[@"title"] = String(*title);
            detail = [detail stringByAppendingFormat:@": %@", String(*title)];
        }
        content = [content stringByAppendingFormat:@"%@[%@ · open in Discord]", content.length ? @"\n" : @"", detail];
    }
    return @{@"id": ID(message.Id()), @"userID": ID(message.RecipientId()),
        @"author": author ? String(author->DisplayName()) : ID(message.AuthorId()),
        @"conversation": recipient ? String(recipient->DisplayName()) : ID(message.RecipientId()),
        @"content": content.length ? content : @"[Empty message]",
        @"timestamp": @(message.SentTimestamp()), @"edited": @(message.EditedTimestamp() != 0),
        @"disclosure": @(message.DisclosureType().has_value()),
        @"channelID": ID(message.ChannelId()), @"additionalContent": additionalDetails};
}
- (void)receive:(uint64_t)messageID created:(BOOL)created {
    if (!_ready) return;
    auto message = _client->GetMessageHandle(messageID);
    if (!message) return;
    NSDictionary *value = [self dictionary:*message];
    auto me = _client->GetCurrentUserV2();
    BOOL incoming = created && me && message->AuthorId() != me->Id() && !message->DisclosureType();
    if (value && self.messageChanged) self.messageChanged(value, incoming);
}
- (void)acceptResult:(discordpp::ClientResult)result access:(std::string const &)access refresh:(std::string const &)refresh expires:(int32_t)expires generation:(NSUInteger)generation {
    if (generation != _generation) return;
    _authenticating = NO;
    if (!result.Successful()) {
        // A revoked/expired refresh token requires a new authorization; transient errors retry.
        int status = static_cast<int>(result.Status());
        if (status == 400 || status == 401 || status == 403) {
            _wanted = NO; _hasSession = NO; _ready = NO; _refreshToken = nil; _refreshAt = nil;
            _client->Disconnect();
            if (self.sessionCleared) self.sessionCleared();
            SecItemDelete((__bridge CFDictionaryRef)KeyQuery());
        } else _refreshAt = [NSDate dateWithTimeIntervalSinceNow:60];
        [self status:[@"Authentication failed: " stringByAppendingString:String(result.Error())]];
        return;
    }
    _refreshToken = String(refresh);
    BOOL saved = SaveRefreshToken(_refreshToken);
    _refreshAt = [NSDate dateWithTimeIntervalSinceNow:MAX(1, expires - 60)];
    __weak DiscordBridge *weakSelf = self;
    _client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, access, [weakSelf, generation, saved](auto update) {
        DiscordBridge *owner = weakSelf; if (!owner || owner->_generation != generation) return;
        if (update.Successful()) {
            owner->_hasSession = YES;
            [owner status:saved ? @"Connecting to Discord…" : @"Connecting · Keychain unavailable, sign-in won't persist"];
            owner->_client->Connect();
        } else [owner status:@"Could not apply Discord access token. Sign in again."];
    });
}
- (void)signIn {
    if (!self.configured) { [self status:@"Discord application ID is not configured. See the setup instructions."]; return; }
    if (_authenticating) { _client->AbortAuthorize(); _authenticating = NO; }
    _generation++; _wanted = YES; _authenticating = YES; _ready = NO; _hasSession = NO; _retryAt = nil;
    _refreshAt = nil; _refreshToken = nil;
    _client->SetShowingChat(false); _client->Disconnect();
    if (self.sessionCleared) self.sessionCleared();
    NSUInteger generation = _generation;
    [self status:@"Waiting for Discord authorization…"];
    auto verifier = _client->CreateAuthorizationCodeVerifier();
    discordpp::AuthorizationArgs args;
    args.SetClientId(ApplicationID());
    args.SetScopes(discordpp::Client::GetDefaultCommunicationScopes());
    args.SetCodeChallenge(verifier.Challenge());
    __weak DiscordBridge *weakSelf = self;
    _client->Authorize(args, [weakSelf, verifier, generation](auto result, auto code, auto redirect) {
        DiscordBridge *owner = weakSelf; if (!owner || owner->_generation != generation) return;
        if (!result.Successful()) {
            owner->_authenticating = NO; owner->_wanted = NO; owner->_retryAt = nil;
            [owner status:[@"Sign-in cancelled or failed: " stringByAppendingString:String(result.Error())]];
            return;
        }
        owner->_client->GetToken(ApplicationID(), code, verifier.Verifier(), redirect,
            [weakSelf, generation](auto result, auto access, auto refresh, auto type, int32_t expires, auto scopes) {
                [weakSelf acceptResult:result access:access refresh:refresh expires:expires generation:generation];
            });
    });
}
- (void)refresh {
    if (_authenticating || !_refreshToken.length) return;
    _authenticating = YES;
    NSUInteger generation = _generation;
    __weak DiscordBridge *weakSelf = self;
    _client->RefreshToken(ApplicationID(), _refreshToken.UTF8String,
        [weakSelf, generation](auto result, auto access, auto refresh, auto type, int32_t expires, auto scopes) {
            [weakSelf acceptResult:result access:access refresh:refresh expires:expires generation:generation];
        });
}
- (void)restoreSession {
    if (!self.configured) { [self status:@"Discord application ID is not configured. See the setup instructions."]; return; }
    if (_wanted) return;
    _refreshToken = ReadRefreshToken();
    if (!_refreshToken.length) { [self status:@"Sign in to read Discord messages"]; return; }
    _wanted = YES;
    [self status:@"Restoring Discord session…"];
    [self refresh];
}
- (void)signOut {
    _generation++; _wanted = NO; _hasSession = NO; _authenticating = NO; _ready = NO; _retryAt = nil; _refreshAt = nil;
    _client->AbortAuthorize(); _client->SetShowingChat(false); _client->Disconnect();
    // Remove this device's session. Account-wide revocation is available in Discord settings.
    _refreshToken = nil;
    SecItemDelete((__bridge CFDictionaryRef)KeyQuery());
    if (self.sessionCleared) self.sessionCleared();
    [self status:@"Signed out on this device"];
}
- (void)setShowingChat:(BOOL)showing { _client->SetShowingChat(showing && _ready); }
- (void)loadConversations:(void (^)(NSArray<NSDictionary *> *, NSString *))completion {
    if (!_ready) { completion(@[], @"Discord is not ready"); return; }
    NSUInteger generation = _generation;
    __weak DiscordBridge *weakSelf = self;
    _client->GetUserMessageSummaries([weakSelf, generation, completion](auto result, auto summaries) {
        DiscordBridge *owner = weakSelf; if (!owner || owner->_generation != generation) return;
        if (!result.Successful()) { completion(@[], String(result.Error())); return; }
        NSMutableArray *rows = [NSMutableArray array];
        for (auto const &summary : summaries) {
            auto user = owner->_client->GetUser(summary.UserId());
            [rows addObject:@{@"userID": ID(summary.UserId()), @"name": user ? String(user->DisplayName()) : ID(summary.UserId()), @"lastMessageID": ID(summary.LastMessageId())}];
        }
        completion(rows, nil);
    });
}
- (void)loadMessagesForUser:(NSString *)userID completion:(void (^)(NSArray<NSDictionary *> *, NSString *))completion {
    if (!_ready) { completion(@[], @"Discord is not ready"); return; }
    NSUInteger generation = _generation;
    __weak DiscordBridge *weakSelf = self;
    _client->GetUserMessagesWithLimit(userID.longLongValue, 200, [weakSelf, generation, completion](auto result, auto messages) {
        DiscordBridge *owner = weakSelf; if (!owner || owner->_generation != generation) return;
        if (!result.Successful()) { completion(@[], [@"History unavailable: " stringByAppendingString:String(result.Error())]); return; }
        NSMutableArray *rows = [NSMutableArray array];
        for (auto const &message : messages) { NSDictionary *row = [owner dictionary:message]; if (row) [rows addObject:row]; }
        completion(rows, nil);
    });
}
- (void)openMessage:(NSString *)messageID {
    if (!_ready || !_client->CanOpenMessageInDiscord(messageID.longLongValue)) { [self status:@"This message cannot be opened in Discord"]; return; }
    __weak DiscordBridge *weakSelf = self;
    _client->OpenMessageInDiscord(messageID.longLongValue, [] {}, [weakSelf](auto result) {
        if (!result.Successful()) [weakSelf status:@"Could not open message in Discord"];
    });
}
@end
