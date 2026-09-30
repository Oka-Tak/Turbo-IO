#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import "Core.h"
#import "NavigationUI.h"
#import "Profile.h"
#import "ProfileUI.h"
#import "RecordingExports.h"
#import "RecordingText.h"
#import "AlwaysOnAudio.h"
#import "WebSearch.h"
#import "TodoRuntime.h"
#import "TodoProtocol.h"
#import "NewsReader.h"
#if TIO_MUSIC
#import "music/MusicPlayer.h"
#endif
#import "PrivateBootstrap.h"
#import "ResearchCatalog.h"
#if TIO_LOCAL_TRANSLATION
#import "local-translation/LocalTranslationEntry.h"
#endif
#import "ResearchUI.h"
#import "VoiceTTS.h"
#if TIO_NATIVE_NAV
#import "DisplayPhoneUI.h"
#endif
#if TIO_OTA_RESEARCH_ENABLED
#import "ExperimentalOTAUI.h"
#import "ExperimentalOTAFeed.h"
#endif
#import "HomeTabBridge.h"
#import "KnowledgeUI.h"
#import "KnowledgeClient.h"

#ifndef TIO_TARGET_BUNDLE_ID
#define TIO_TARGET_BUNDLE_ID "com.rayneo.venus.pub"
#endif
static NSString *const TargetBundle=@TIO_TARGET_BUNDLE_ID;

// No Frida, inline patching, device credentials or official token access.
static NSString *const Domain=@"io.turboio.official-private-addon";
static NSUserDefaults *Prefs;
static TIOTranscriptArchive *Archive;
static dispatch_queue_t ArchiveQueue;
static NSString *Diagnostic=@"尚未收到回调";
static BOOL HooksReady=NO;
static UIButton *Entry;
static void (*OriginalAsr)(id,SEL,id,BOOL,id);
static void (*OriginalNlp)(id,SEL,id);
static void (*OriginalComplete)(id,SEL);
static void (*OriginalAlwaysOn)(id,SEL,id);
static void (*OriginalAudioStart)(id,SEL);
static BOOL VoiceExitReady=NO;
static NSUInteger CompletionEvents;
static TIOVoiceTTS *VoiceTTS;

static NSDictionary *KeyQuery(NSString *host) {return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:Domain,(__bridge id)kSecAttrAccount:host};}
static NSString *ReadKey(NSString *host) {
    NSMutableDictionary *q=[KeyQuery(host) mutableCopy];q[(__bridge id)kSecReturnData]=@YES;
    CFTypeRef out=NULL; if(SecItemCopyMatching((__bridge CFDictionaryRef)q,&out)!=errSecSuccess)return @"";
    return [[NSString alloc]initWithData:CFBridgingRelease(out) encoding:NSUTF8StringEncoding]?:@"";
}
static BOOL TTSOn(void){return [Prefs boolForKey:@"ttsEnabled"]&&([[Prefs stringForKey:@"ttsEngine"] isEqual:@"local"]||ReadKey(TIOVoiceTTSService()).length>0);}
static BOOL StoreKey(NSString *host,NSString *key) {
    NSDictionary *q=KeyQuery(host);
    if(!key.length){OSStatus s=SecItemDelete((__bridge CFDictionaryRef)q);return s==errSecSuccess||s==errSecItemNotFound;}
    NSDictionary *attrs=@{(__bridge id)kSecValueData:[key dataUsingEncoding:NSUTF8StringEncoding],(__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus result=SecItemUpdate((__bridge CFDictionaryRef)q,(__bridge CFDictionaryRef)attrs);
    if(result==errSecItemNotFound){NSMutableDictionary *all=[q mutableCopy];[all addEntriesFromDictionary:attrs];result=SecItemAdd((__bridge CFDictionaryRef)all,NULL);}
    return result==errSecSuccess;
}
static void ImportPrivateBootstrap(void){
    // Source release: configure credentials in the app's Keychain UI only.
    // Never import keys from a distributable application resource.
}
static id Get(id obj,NSString *key) {if(!obj)return nil;@try{return [obj valueForKey:key];}@catch(NSException *e){return nil;}}
static NSString *String(id obj) {return [obj isKindOfClass:NSString.class]?obj:@"";}
static UIViewController *TopController(void) {
    UIWindow *window=nil;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) if(scene.activationState==UISceneActivationStateForegroundActive && [scene isKindOfClass:UIWindowScene.class]) {
        for(UIWindow *w in ((UIWindowScene *)scene).windows) if(w.isKeyWindow){window=w;break;}
    }
    // Official Flutter 1.0.2 uses the legacy application window lifecycle.
    if(!window){for(UIWindow *w in UIApplication.sharedApplication.windows)if(w.isKeyWindow){window=w;break;}}
    UIViewController *c=window.rootViewController;while(c.presentedViewController)c=c.presentedViewController;return c;
}
static void Alert(NSString *title,NSString *message) {
    dispatch_async(dispatch_get_main_queue(),^{UIViewController *top=TopController();if(!top)return;UIAlertController *a=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];[top presentViewController:a animated:YES completion:nil];});
}

@interface TIORequest : TIOWebChatRequest
@property(nonatomic,copy) NSArray<NSDictionary *> *history;
- (void)startQuestion:(NSString *)question;
@end
@implementation TIORequest
- (void)startQuestion:(NSString *)question {
    NSString *endpoint=[Prefs stringForKey:@"endpoint"]?:@"",*model=[Prefs stringForKey:@"model"]?:@"";
    NSURL *url=TIOValidateEndpoint(endpoint); NSString *key=ReadKey(endpoint);
    NSDictionary *payload=TIOChatRequestWithHistory(model,question,_history?:@[]);
    if(!url||!payload||!key.length){if(self.update)self.update(@"",YES,@"请先配置有效的 HTTPS 接口、模型和 Key。");return;}
    // Optional provider extension, sent only when explicitly selected by user.
    NSMutableDictionary *body=[payload mutableCopy];if([Prefs boolForKey:@"deepseekDisableThinking"])body[@"thinking"]=@{@"type":@"disabled"};
    NSString *searchKey=([Prefs boolForKey:@"tinyfishEnabled"]||self.newsMode)?ReadKey(@"https://api.search.tinyfish.ai"):@"";
    TIOImportKnowledgeConnection();if(!self.newsMode&&TIOKnowledgeEnabled()){TIOKnowledgeClient *client=[TIOKnowledgeClient new];self.cancelKnowledge=^{[client cancel];};self.knowledgeQuery=^(NSDictionary *input,BOOL statusOnly,void(^done)(NSDictionary *)){void(^completion)(NSDictionary *,NSString *)=^(NSDictionary *j,NSString *e){done(j?:@{@"status":@"failed"});};if(statusOnly)[client refreshLast:completion];else [client query:input completion:completion];};}
    [self startEndpoint:url key:key payload:body searchKey:searchKey];
}
@end

@interface TIOController : NSObject
@property(nonatomic) TIORequest *request;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,weak) id listener;
@property(nonatomic) NSString *asr;
@property(nonatomic) NSString *sid;
@property(nonatomic) id responseTemplate;
@property(nonatomic) NSString *emitted;
@property(nonatomic) BOOL ownsTurn;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL responseDone;
@property(nonatomic) NSMutableSet<NSString *> *seenFinals;
@property(nonatomic) NSString *captureEpoch;
@property(nonatomic) TIOConversationHistory *history;
@property(nonatomic,copy) NSString *requestQuestion;
@property(nonatomic) BOOL voiceExited;
@property(nonatomic) TIOTodoTurnGate *taskGate;
@property(nonatomic,copy) NSString *officialTTSAnswer;
@property(nonatomic) BOOL officialTTSActive;
- (BOOL)exitVoice;
@end
static TIOController *Controller;

static id CopyResponse(id source,NSString *answer,BOOL final) {
    // Only use the observed wrapper class. Do not call guessed Swift addresses.
    Class cls=NSClassFromString(@"RayNeoNlpResultWrapper");if(!cls||![source isKindOfClass:cls])return nil;
    id copy=[cls new];
    @try {
        for(NSString *field in @[@"sub",@"dialogId",@"sessionId",@"domain",@"intent",@"round",@"query",@"spoken",@"answer",@"finished",@"offline",@"command",@"hasNextRound",@"rawData"]) {id v=[source valueForKey:field];if(v)[copy setValue:v forKey:field];}
        [copy setValue:answer forKey:@"answer"];[copy setValue:@"" forKey:@"spoken"];[copy setValue:@(final) forKey:@"finished"];
    }@catch(NSException *e){return nil;}
    return copy;
}
@implementation TIOController
- (instancetype)init {if((self=[super init])){_seenFinals=[NSMutableSet set];_captureEpoch=NSUUID.UUID.UUIDString;_history=[TIOConversationHistory new];_taskGate=[TIOTodoTurnGate new];}return self;}
- (void)cancel {++_generation;[_request cancel];_request=nil;_ownsTurn=NO;_started=NO;_responseDone=NO;_responseTemplate=nil;_emitted=@"";_officialTTSAnswer=@"";_officialTTSActive=NO;[VoiceTTS cancel];}
- (BOOL)exitVoice {
    if(!VoiceExitReady)return NO;
    Class cls=NSClassFromString(@"rayneo_venus_sdk_plugin.VoiceAssistantHelper");
    id helper=((id(*)(id,SEL))objc_msgSend)(cls,NSSelectorFromString(@"shared"));
    if(!helper)return NO;
    // Cancel our stream before asking the official workflow to stop, so a late
    // network delta cannot re-open the page. New audio start releases this gate.
    [self cancel];_voiceExited=YES;_asr=@"";_sid=@"";
    ((void(*)(id,SEL))objc_msgSend)(helper,NSSelectorFromString(@"stopWorkflow"));
    Diagnostic=@"语音退出已调用官方停止入口；等待镜片确认";
    return YES;
}
- (void)acceptAsr:(NSString *)text finished:(BOOL)final session:(NSString *)sid listener:(id)listener {
    if(![Prefs integerForKey:@"mode"]||!text.length)return;
    if(!final){if(_ownsTurn&&_started){[self cancel];}_asr=text;return;}
    NSString *identity=[NSString stringWithFormat:@"%@|%@",sid,text];if([_seenFinals containsObject:identity])return;
    if(_seenFinals.count>=256)[_seenFinals removeAllObjects];[_seenFinals addObject:identity];
    [self cancel];[_taskGate beginTurn];_listener=listener;_asr=text;_sid=sid;
    // Do not seize an unknown response shape. Wait for an eligible official template.
    Diagnostic=@"ASR final 已到达，等待官方聊天回包模板";
}
- (void)emitText:(NSString *)text done:(BOOL)done error:(NSString *)error generation:(NSUInteger)gen {
    if(gen!=_generation||!_ownsTurn||_responseDone||!_listener)return;
    if(error)text=[(_emitted?:@"") stringByAppendingFormat:@"\n[%@]",error];
    NSString *delta=TIOAppendDelta(_emitted?:@"",text);
    if(!delta){
        // Close an owned turn even if a provider rewrites a previous chunk.
        // Keep ownership until the next turn so late official chunks stay suppressed.
        [_request cancel];_request=nil;_responseDone=YES;
        id failure=CopyResponse(_responseTemplate,@"\n[回复流格式变化，本轮已停止。]",YES);
        if(failure)OriginalNlp(_listener,NSSelectorFromString(@"onNlpResult:"),failure);
        OriginalComplete(_listener,NSSelectorFromString(@"onResponseComplete"));
        Diagnostic=@"模型输出不是追加流，已提交错误收尾";return;
    }
    if(delta.length||done){id wrapper=CopyResponse(_responseTemplate,delta,done);if(!wrapper){[_request cancel];_request=nil;_responseDone=YES;OriginalComplete(_listener,NSSelectorFromString(@"onResponseComplete"));Diagnostic=@"回复模板复制失败，已提交收尾";return;}OriginalNlp(_listener,NSSelectorFromString(@"onNlpResult:"),wrapper);_emitted=[text copy];if(TTSOn()&&!error)[VoiceTTS appendFullText:text finished:done];}
    if(done){_responseDone=YES;if(!error&&_request&&text.length)[_history appendQuestion:_requestQuestion answer:text];Diagnostic=error?@"自定义回复失败，已提交错误收尾":@"自定义回复结束，已提交官方收尾回调";OriginalComplete(_listener,NSSelectorFromString(@"onResponseComplete"));}
}
- (BOOL)receiveNlp:(id)response listener:(id)listener {
    NSString *domain=String(Get(response,@"domain")),*intent=String(Get(response,@"intent")),*sub=String(Get(response,@"sub"));
    BOOL offline=[Get(response,@"offline") boolValue];
    // Metadata whitelist: no question, answer, rawData, IDs or tokens in diagnostics.
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"];
    NSString *(^safe)(NSString *)=^NSString *(NSString *s){return s.length<64&&[s rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound?s:@"(other)";};
    Diagnostic=[NSString stringWithFormat:@"NLP domain=%@ / intent=%@ / sub=%@ / offline=%d",safe(domain),safe(intent),safe(sub),offline];
    id command=Get(response,@"command");
    if([_taskGate observeDomain:domain intent:intent command:String(Get(command,@"name")) params:Get(command,@"params") session:String(Get(response,@"sessionId")) expectedSession:_sid?:@"" sameListener:listener==_listener]){
        // Invalidate in-flight private deltas before forwarding the official
        // command. Keep subsequent acknowledgement and completion official too.
        [self cancel];Diagnostic=@"官方待办接管本轮；自有回复已取消，完成回调交回官方";
    }
    if(_taskGate.official)return NO;
    BOOL eligible=TIOIsEligibleChat(domain,intent,sub,offline,Get(response,@"command")!=nil);
    if(eligible)
        [Prefs setObject:@"chat" forKey:@"verifiedChatDomain"];
    if(![Prefs integerForKey:@"mode"]||listener!=_listener||!_asr.length||offline)return NO;
    NSString *sid=String(Get(response,@"sessionId"));if(_sid.length&&sid.length&&![_sid isEqual:sid])return NO;
    // Exact chat-domain allowlist must be confirmed on the current phone. Skill commands are never replaced.
    NSString *approved=[Prefs stringForKey:@"verifiedChatDomain"];
    if(!approved.length||![domain isEqual:approved]||!eligible)return NO;
    if(_ownsTurn)return YES;
    _responseTemplate=response;_ownsTurn=YES;_started=YES;_emitted=@"";NSUInteger gen=_generation;
    if([Prefs integerForKey:@"mode"]==1){
        NSString *test=[@"私用模型测试 " stringByAppendingString:[NSUUID.UUID.UUIDString substringToIndex:6]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[self emitText:test done:YES error:nil generation:gen];});
    }else{
        _request=[TIORequest new];__weak typeof(self) weakSelf=self;
        TIOTodoSetChatContext(listener,response);
        _request.createTodo=^(NSString *title,void (^completion)(NSDictionary *result)){TIOTodoCreateFromTool(title,completion);};
        _requestQuestion=[_asr copy];_request.history=[_history snapshot];
        _request.update=^(NSString *text,BOOL done,NSString *error){[weakSelf emitText:text done:done error:error generation:gen];};
        [_request startQuestion:_asr];
    }
    return YES;
}
- (id)observeOfficialVoice:(id)response {
    if(!TTSOn()||!TIOIsEligibleChat(String(Get(response,@"domain")),String(Get(response,@"intent")),String(Get(response,@"sub")),[Get(response,@"offline") boolValue],Get(response,@"command")!=nil))return response;
    NSString *answer=String(Get(response,@"answer"));if(!answer.length)return response;
    if(!_officialTTSActive){_officialTTSActive=YES;_officialTTSAnswer=@"";[VoiceTTS beginTurn];}
    NSString *prior=_officialTTSAnswer?:@"";
    NSString *full=[answer hasPrefix:prior]?answer:([prior hasPrefix:answer]?prior:[prior stringByAppendingString:answer]);
    _officialTTSAnswer=full;
    [VoiceTTS appendFullText:full finished:[Get(response,@"finished") boolValue]];
    // Suppress duplicate spoken text only for the eligible chat response.
    return String(Get(response,@"spoken")).length?(CopyResponse(response,answer,[Get(response,@"finished") boolValue])?:response):response;
}
- (void)completeOfficialVoice {
    if(_officialTTSActive&&_officialTTSAnswer.length)[VoiceTTS appendFullText:_officialTTSAnswer finished:YES];
    _officialTTSActive=NO;_officialTTSAnswer=@"";
}
@end

static void AsrHook(id self,SEL cmd,id text,BOOL final,id sid) {
    NSString *copy=String(text),*session=String(sid);
    void (^work)(void)=^{
        if(final&&[Prefs boolForKey:@"voiceExitCommands"]&&TIOIsVoiceExitCommand(copy)&&[Controller exitVoice])return;
        if(Controller.voiceExited)return;
        // The official app may reopen its microphone after the answer. Cancel
        // playback only when new recognized user speech arrives.
        if(copy.length&&[Prefs boolForKey:@"ttsEnabled"])[VoiceTTS cancel];
        OriginalAsr(self,cmd,text,final,sid);
        [Controller acceptAsr:copy finished:final session:session listener:self];
    };
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}
static void AudioStartHook(id self,SEL cmd) {
    void (^work)(void)=^{
#if TIO_MUSIC
        TMMusicPauseForVoice();
#endif
        Controller.voiceExited=NO;[Controller.taskGate beginTurn];OriginalAudioStart(self,cmd);};
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}
static void NlpHook(id self,SEL cmd,id value) {
    // Route decisions on the main queue to serialize ASR, cancellation and stream completion.
    void (^work)(void)=^{if(Controller.voiceExited)return;if(TIOTodoIsToolDispatching()){OriginalNlp(self,cmd,value);return;}TIOTodoObserveNlp(self,value);if(![Controller receiveNlp:value listener:self])OriginalNlp(self,cmd,[Controller observeOfficialVoice:value]);};
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}
static void CompleteHook(id self,SEL cmd) {
    void (^work)(void)=^{CompletionEvents++;if(Controller.voiceExited)return;[Controller completeOfficialVoice];if(![Prefs integerForKey:@"mode"]||!(Controller.listener==self&&Controller.ownsTurn))OriginalComplete(self,cmd);};
    if(NSThread.isMainThread)work();else dispatch_async(dispatch_get_main_queue(),work);
}
static void AlwaysOnHook(id self,SEL cmd,id value) {
    OriginalAlwaysOn(self,cmd,value);
    if(![Prefs boolForKey:@"captureFinalText"]||![Get(value,@"finish") boolValue])return;
    NSString *text=String(Get(value,@"text")),*round=String(Get(value,@"roundId"));
    id r=Get(value,@"role");NSString *role=[r respondsToSelector:@selector(stringValue)]?[r stringValue]:String(r);
    NSString *identity=round.length?[NSString stringWithFormat:@"%@:%@",Controller.captureEpoch,round]:@"";
    dispatch_async(ArchiveQueue,^{NSError *error=nil;BOOL ok=[Archive recordText:text round:identity role:role at:NSDate.date error:&error];dispatch_async(dispatch_get_main_queue(),^{Diagnostic=ok?@"全天智记最终文字已保存到扩展本机归档":@"全天智记归档失败，官方数据未改";});});
}

@interface TIOPanel : UITableViewController
@property(nonatomic) TIORequest *testRequest;
@property(nonatomic,copy) NSString *page;
@property(nonatomic) NSArray<NSDictionary *> *sections;
@end
@implementation TIOPanel
- (void)viewDidLoad {[super viewDidLoad];self.page=self.page?:@"model";self.sections=TIOResearchSections(self.page);self.title=[@{@"model":@"AIと会話",@"library":@"データと書き出し",@"diagnostics":@"診断ツール"} objectForKey:self.page];TIOStyleResearchTable(self);}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self.tableView reloadData];}
- (void)viewDidAppear:(BOOL)animated{[super viewDidAppear:animated];[NSNotificationCenter.defaultCenter removeObserver:self name:@"TIOResearchClosed" object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cancelPanelTest) name:@"TIOResearchClosed" object:nil];}
- (void)cancelPanelTest{[_testRequest cancel];_testRequest=nil;}
- (void)dealloc{[NSNotificationCenter.defaultCenter removeObserver:self];[_testRequest cancel];}
- (void)close {[_testRequest cancel];[self dismissViewControllerAnimated:YES completion:nil];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return self.sections.count;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return [self.sections[section][@"rows"] count];}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return self.sections[section][@"title"];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section==0&&[self.page isEqual:@"model"])return [TIOSelectedAgent() isEqual:@"Codex"]?@"Codex が知識ベースを読み取り専用で検索します。接続状態は知識ベースで確認できます。":@"選択中のエージェントには実行機能がありません。選択してもタスクは始まりません。";
    if(section==0)return [@{@"model":@"TURBO IO · 回答方法、独自モデル、検索サービスを設定します。",@"library":@"音声と文字起こしを管理します。共有時はコピーを作り、元のファイルは残します。",@"diagnostics":@"手動テストと通信状態を確認します。"} objectForKey:self.page];
    if(section!=self.sections.count-1)return nil;
    if([self.page isEqual:@"model"])return @"公式の音声認識を使うため、音声は公式クラウドを経由する場合があります。回答の読み上げは初期状態でiOS端末内の音声を使います。会話履歴はこのアプリの実行中に成功した直近50件だけ保持します。";
    if([self.page isEqual:@"library"])return @"保存は明示的に有効にした場合だけ行います。録音や自動アップロードは始まりません。ライフログの保存対象は有効化後の内容だけです。";
    return @"テストは手動で実行します。設定済みのサービスへ接続する場合があります。APIの成功は眼鏡への表示成功を意味しません。";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r=self.sections[ip.section][@"rows"][ip.row];NSInteger section=[r[@"section"] integerValue],row=[r[@"row"] integerValue];
    UITableViewCell *c=section>=0?[self legacyCell:tableView at:[NSIndexPath indexPathForRow:row inSection:section]]:[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.text=r[@"title"];c.textLabel.numberOfLines=0;c.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];c.textLabel.adjustsFontForContentSizeCategory=YES;c.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];c.detailTextLabel.adjustsFontForContentSizeCategory=YES;c.detailTextLabel.numberOfLines=0;c.detailTextLabel.textColor=UIColor.secondaryLabelColor;c.imageView.image=[UIImage systemImageNamed:r[@"icon"]];c.imageView.tintColor=UIColor.systemIndigoColor;
    c.accessibilityIdentifier=[@"research-" stringByAppendingString:r[@"key"]];c.contentView.directionalLayoutMargins=NSDirectionalEdgeInsetsMake(15,16,15,16);
    if([r[@"key"] isEqual:@"agent"]){__weak typeof(self) weak=self;c.accessoryView=TIOAgentPicker(^{[weak.tableView reloadData];});c.detailTextLabel.text=[TIOSelectedAgent() isEqual:@"Codex"]?@"Mac・独自の知識ベース":@"実行機能は未接続";}
    if([r[@"key"] isEqual:@"knowledge"])c.detailTextLabel.text=@"アーカイブ・プロジェクト文書・学習資料";
    if([r[@"key"] isEqual:@"tts"]){c.detailTextLabel.text=@"公式/独自モデルの回答・眼鏡のBluetooth音声";
        UISwitch *s=[UISwitch new];s.on=[Prefs boolForKey:@"ttsEnabled"];[s addTarget:self action:@selector(ttsToggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;}
    if([r[@"key"] isEqual:@"ttsEngine"])c.detailTextLabel.text=[[Prefs stringForKey:@"ttsEngine"] isEqual:@"local"]?@"iOS端末内の音声・キー不要・初期設定":@"Ali qwen-audio-3.1-tts-flash・クラウド";
    if([r[@"key"] isEqual:@"ttsKey"])c.detailTextLabel.text=ReadKey(TIOVoiceTTSService()).length?@"端末のキーチェーンに保存済み":@"クラウド利用時のみ接続先とキーが必要";
    if([r[@"key"] isEqual:@"ttsTest"]){c.detailTextLabel.text=[NSString stringWithFormat:@"テスト用の短文・%@",VoiceTTS.status?:@"待機中"];
        UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:@"再生" forState:UIControlStateNormal];
        button.accessibilityIdentifier=@"research-tts-play-button";button.frame=CGRectMake(0,0,58,44);
        [button addTarget:self action:@selector(testTTS) forControlEvents:UIControlEventTouchUpInside];c.accessoryView=button;}
    if(!c.accessoryView)c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if([r[@"key"] isEqual:@"mode"]){c.detailTextLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];c.detailTextLabel.textColor=UIColor.labelColor;}
    if([r[@"key"] isEqual:@"history"])c.detailTextLabel.text=[c.detailTextLabel.text stringByAppendingString:@"・タップして消去を管理"];
    if(section==-1)c.detailTextLabel.text=@[@"端末内の音声/TXT/MarkdownをAirDropやファイルで共有",@"文字起こしを入力し、確認してから独自モデルへ送信",@"Markdownの書き出しと保存済みテキストの整理",@"保存を有効にして音声のコピーを表示・共有"][row];
    if([r[@"key"] isEqual:@"navigation"])c.detailTextLabel.text=@"Amapの検索・地点選択・徒歩シミュレーションを眼鏡へ表示。iOS用キーが必要";
    if([r[@"key"] isEqual:@"archive"])c.detailTextLabel.text=@"MarkdownとJSONを書き出します";
    if([r[@"key"] isEqual:@"capture"])c.detailTextLabel.text=@"今後のライフログのテキストのみ保存します。録音は始まりません";
    if([r[@"key"] isEqual:@"status"])c.accessoryType=UITableViewCellAccessoryNone;
    return c;
}
- (UITableViewCell *)legacyCell:(UITableView *)tableView at:(NSIndexPath *)ip {
    UITableViewCell *c=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];c.detailTextLabel.numberOfLines=0;
    if(ip.section==0){
        c.textLabel.text=@[@"回答モデルを選択",@"独自 API を設定",@"API をテスト（合成された質問）",@"DeepSeek：思考用の追加パラメータを無効化",@"会話履歴（タップして消去）",@"システムプロンプトを表示",@"音声で会話を終了",@"ウェブ検索 · TinyFish",@"TinyFish のキーを設定",@"ウェブ検索をテスト（公開情報）",@"ToDo 連携を確認",@"モデルのツール",@"AI ニュース購読"][ip.row];
        if(ip.row==12)c.detailTextLabel.text=@"標準 AI · TinyFish · 一定速度の字幕表示 · 録音は開始しません";
        if(ip.row==11)c.detailTextLabel.text=TIOKnowledgeEnabled()?@"knowledge_query · knowledge_query_status · create_todo · web_search":@"create_todo · web_search · 知識ベースは有効化が必要";
        if(ip.row==0){NSInteger m=[Prefs integerForKey:@"mode"];c.detailTextLabel.text=@[@"公式の回答",@"ランダム文字列で検証",@"独自の OpenAI 互換 API"][MAX(0,MIN(m,2))];}
        if(ip.row==1)c.detailTextLabel.text=[Prefs stringForKey:@"model"]?:@"未設定。API キーは同梱されません";
        if(ip.row==3){UISwitch *s=[UISwitch new];s.on=[Prefs boolForKey:@"deepseekDisableThinking"];[s addTarget:self action:@selector(thinking:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;}
        if(ip.row==4)c.detailTextLabel.text=[NSString stringWithFormat:@"%lu / 50 件 · 実行中のメモリのみ · 成功した問答だけ",(unsigned long)[Controller.history snapshot].count];
        if(ip.row==5)c.detailTextLabel.text=[TIOProfilePrompt(TIOProfile()) length]?@"設定済み · 次の独自モデルとの会話から適用":@"未設定 · 呼び名や背景、好みを編集";
        if(ip.row==6){c.detailTextLabel.text=VoiceExitReady?@"閉じて / 会話を終了 / もう大丈夫；短い発話の完全一致":@"このバージョンでは終了処理を検証できず、無効です";UISwitch *s=[UISwitch new];s.on=[Prefs boolForKey:@"voiceExitCommands"];s.enabled=VoiceExitReady;[s addTarget:self action:@selector(voiceExit:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;}
        if(ip.row==7){c.detailTextLabel.text=@"モデルが必要に応じて呼び出し · 公開ウェブを読み取りのみ · 最大2回";UISwitch *s=[UISwitch new];s.on=[Prefs boolForKey:@"tinyfishEnabled"];[s addTarget:self action:@selector(searchToggle:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;}
        if(ip.row==8)c.detailTextLabel.text=ReadKey(@"https://api.search.tinyfish.ai").length?@"iPhone のキーチェーンに保存済み・再表示不可":@"未設定。Mac の認証情報は使用しません";
        if(ip.row==9)c.detailTextLabel.text=@"会話履歴は送信せず、実際の検索回数を表示します";
    }else if(ip.section==1){c.textLabel.text=ip.row==0?@"認識後のテキストを別途保存":@"Markdown / JSON を書き出す";if(ip.row==0){UISwitch *s=[UISwitch new];s.on=[Prefs boolForKey:@"captureFinalText"];[s addTarget:self action:@selector(capture:) forControlEvents:UIControlEventValueChanged];c.accessoryView=s;}}
    else{c.textLabel.text=HooksReady?@"コールバックの署名を確認済み":@"無効：バージョンまたはコールバックが不一致";c.detailTextLabel.text=[Diagnostic stringByAppendingFormat:@"\n公式アプリの完了通知：%lu；音声終了処理：%@",(unsigned long)CompletionEvents,VoiceExitReady?@"確認済み":@"使用不可"];}
    return c;
}
- (void)thinking:(UISwitch *)sender {[Prefs setBool:sender.on forKey:@"deepseekDisableThinking"];}
- (void)ttsToggle:(UISwitch *)sender {
    if(sender.on&&![[Prefs stringForKey:@"ttsEngine"] isEqual:@"local"]&&!ReadKey(TIOVoiceTTSService()).length){sender.on=NO;Alert(@"クラウド音声を設定してください",@"Ali Flash の利用には API キーが必要です。iPhone 内の読み上げには不要です。");return;}
    [Prefs setBool:sender.on forKey:@"ttsEnabled"];if(!sender.on)[VoiceTTS cancel];
    [self.tableView reloadData];
}
- (void)configureTTSEngine {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"回答の読み上げ" message:@"会話の回答だけを読み上げます。初期設定はキー不要の iPhone 内音声です。Ali Flash は任意の実験機能です。" preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"iPhone 内で読み上げ · 初期設定・キー不要" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[Prefs setObject:@"local" forKey:@"ttsEngine"];[Prefs setBool:YES forKey:@"ttsEnabled"];VoiceTTS.localMode=YES;[self.tableView reloadData];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"Ali Flash · クラウド音声" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        if(!ReadKey(TIOVoiceTTSService()).length){Alert(@"クラウドのキーが未設定です",@"先に Ali Flash TTS を設定するか、iPhone 内の読み上げを利用してください。");return;}
        [Prefs setObject:@"cloud" forKey:@"ttsEngine"];[Prefs setBool:YES forKey:@"ttsEnabled"];VoiceTTS.localMode=NO;[self.tableView reloadData];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView=self.view;a.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,100,1,1);
    [self presentViewController:a animated:YES completion:nil];
}
- (void)configureTTS {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Ali Flash TTS" message:@"任意のクラウド機能です。公式 WebSocket の URL と自分のキーを入力します。キーは iPhone のキーチェーンにのみ保存し、再表示しません。空欄なら同じ URL の既存キーを維持します。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"wss://…/api-ws/v1/inference";f.text=TIOVoiceTTSService();f.keyboardType=UIKeyboardTypeURL;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"新しい TTS API キー（再表示不可）";f.secureTextEntry=YES;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
        NSString *endpoint=a.textFields[0].text?:@"",*key=a.textFields[1].text?:@"";a.textFields[1].text=@"";
        if(!TIOVoiceTTSServiceURLValid(endpoint)||!([key hasPrefix:@"sk-"]||!key.length)||key.length>1024||[key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound){Alert(@"保存できませんでした",@"Ali 公式の wss URL と有効なキーが必要です。");return;}
        if(key.length&&!StoreKey(endpoint,key)){Alert(@"保存できませんでした",@"キーチェーンへの書き込みに失敗しました。");return;}
        if(!ReadKey(endpoint).length){Alert(@"保存できませんでした",@"この URL のキーが未設定です。");return;}
        [VoiceTTS cancel];[Prefs setObject:endpoint forKey:@"ttsEndpoint"];[self.tableView reloadData];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"現在のクラウド用キーを削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[VoiceTTS cancel];StoreKey(TIOVoiceTTSService(),@"");[Prefs setObject:@"local" forKey:@"ttsEngine"];VoiceTTS.localMode=YES;[self.tableView reloadData];}]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)testTTS {
    if(!TTSOn()){Alert(@"読み上げを有効にしてください",@"回答の読み上げをオンにしてください。TTS キーが必要なのはクラウドモードだけです。");return;}
    [VoiceTTS beginTurn];[VoiceTTS appendFullText:@"Turbo IO の音声テストです。声が聞こえていますか。" finished:YES];
    [self.tableView reloadData];
    __weak typeof(self) weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak.tableView reloadData];});
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{[weak.tableView reloadData];});
}
- (void)voiceExit:(UISwitch *)sender {[Prefs setBool:sender.on forKey:@"voiceExitCommands"];}
- (void)searchToggle:(UISwitch *)sender {if(sender.on&&!ReadKey(@"https://api.search.tinyfish.ai").length){sender.on=NO;Alert(@"请先配置",@"需要你自己的 TinyFish API Key。");return;}[Prefs setBool:sender.on forKey:@"tinyfishEnabled"];[Controller cancel];}
- (void)configureSearch {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"TinyFish 搜索配置" message:@"开启后，自有模型可把必要检索词发给 TinyFish，将搜索摘要交回模型。官方 ASR 不变。不适合检索敏感信息。Key 仅存本机钥匙串；留空保留已有 Key。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"TinyFish API Key（不回显）";f.secureTextEntry=YES;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存并启用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSString *key=a.textFields[0].text?:@"";a.textFields[0].text=@"";if((key.length&&(![key hasPrefix:@"sk-tinyfish-"]||[key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound||!StoreKey(@"https://api.search.tinyfish.ai",key)))||(!key.length&&!ReadKey(@"https://api.search.tinyfish.ai").length)){Alert(@"未保存",@"Key 格式或钥匙串写入失败。");return;}[Controller cancel];[Prefs setBool:YES forKey:@"tinyfishEnabled"];[self.tableView reloadData];}]];
    [a addAction:[UIAlertAction actionWithTitle:@"移除本机搜索 Key" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[Controller cancel];[Prefs setBool:NO forKey:@"tinyfishEnabled"];BOOL ok=StoreKey(@"https://api.search.tinyfish.ai",@"");[self.tableView reloadData];if(!ok)Alert(@"未移除",@"钥匙串删除失败；搜索已关闭。");}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)testSearch {
    if(![Prefs boolForKey:@"tinyfishEnabled"]||!ReadKey(@"https://api.search.tinyfish.ai").length){Alert(@"無効です",@"先に TinyFish 検索を設定して有効にしてください。");return;}
    [_testRequest cancel];_testRequest=[TIORequest new];__weak typeof(self) weak=self;
    _testRequest.update=^(NSString *text,BOOL done,NSString *error){if(done){typeof(self) strong=weak;Alert(@"ウェブ検索のテスト結果",[NSString stringWithFormat:@"実際の検索回数：%lu 回\n%@",(unsigned long)strong.testRequest.searchCount,error?:text]);}};
    [_testRequest startQuestion:@"TinyFish Search API の公式 URL を実際に検索し、公式の出典 URL を添えて日本語で一文で説明してください。"];
}
- (void)capture:(UISwitch *)sender {
    if(!sender.on){[Prefs setBool:NO forKey:@"captureFinalText"];return;}
    sender.on=NO;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"ライフログのテキストを保存しますか？" message:@"今後受け取る認識済みのテキストだけを、公式アプリ内の拡張機能用フォルダに別途保存します。実際の会話が含まれるため、録音と保存について関係者の同意を確認してください。位置情報は取得せず、自動アップロードもしません。" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"iPhone 内に保存する" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){Controller.captureEpoch=NSUUID.UUID.UUIDString;[Prefs setBool:YES forKey:@"captureFinalText"];[self.tableView reloadData];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)configure {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"独自モデルの API" message:@"HTTPS の /chat/completions URL を入力してください。キーは iPhone のキーチェーンにのみ保存します。空欄なら同じ URL の既存キーを維持し、URL を変えてもキーは引き継ぎません。" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"https://…/v1/chat/completions";f.text=[Prefs stringForKey:@"endpoint"];f.keyboardType=UIKeyboardTypeURL;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"モデル名";f.text=[Prefs stringForKey:@"model"];f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"新しい API キー（再表示不可）";f.secureTextEntry=YES;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
    [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){NSString *url=a.textFields[0].text?:@"",*model=a.textFields[1].text?:@"",*key=a.textFields[2].text?:@"";NSURL *valid=TIOValidateEndpoint(url);if(!valid||!TIOChatRequest(model,@"テスト")){Alert(@"保存できませんでした",@"有効な HTTPS の chat/completions URL とモデル名が必要です。");return;}url=valid.absoluteString;if(key.length&&!StoreKey(url,key)){Alert(@"保存できませんでした",@"キーチェーンへの書き込みに失敗しました。");return;}[Controller cancel];if(![[Prefs stringForKey:@"endpoint"] isEqual:url]||![[Prefs stringForKey:@"model"] isEqual:model])[Controller.history clear];[Prefs setInteger:0 forKey:@"mode"];[Prefs setObject:url forKey:@"endpoint"];[Prefs setObject:model forKey:@"model"];[self.tableView reloadData];}]];[self presentViewController:a animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r=self.sections[ip.section][@"rows"][ip.row];[tableView deselectRowAtIndexPath:ip animated:YES];
    if([r[@"key"] isEqual:@"agent"])return;
#if TIO_MUSIC
    if([r[@"key"] isEqual:@"music"]){[self.navigationController pushViewController:TMMusicController() animated:YES];return;}
#endif
#if TIO_LOCAL_TRANSLATION
    if([r[@"key"] isEqual:@"localTranslation"]){TIOOpenLocalTranslation(self);return;}
#endif
    if([r[@"key"] isEqual:@"knowledge"]){TIOOpenKnowledge(self);return;}
    if([r[@"key"] isEqual:@"ttsEngine"]){[self configureTTSEngine];return;}
    if([r[@"key"] isEqual:@"ttsKey"]){[self configureTTS];return;}
    if([r[@"key"] isEqual:@"ttsTest"]){[self testTTS];return;}
    if([r[@"key"] isEqual:@"navigation"]){[self.navigationController pushViewController:TIONavigationController() animated:YES];return;}
#if TIO_OTA_RESEARCH_ENABLED
    #if TIO_NATIVE_NAV
    if([r[@"key"] isEqual:@"displayPhone"]){[self.navigationController pushViewController:TDPPhoneController() animated:YES];return;}
    #endif
    if([r[@"key"] isEqual:@"experimentalOTA"]){[self.navigationController pushViewController:TIOExperimentalOTAController() animated:YES];return;}
#endif
    if([@[@"thinking",@"search",@"exit",@"capture",@"tts"] containsObject:r[@"key"]])return;
    NSInteger section=[r[@"section"] integerValue],row=[r[@"row"] integerValue];
    if(section>=0){[self legacySelect:tableView at:[NSIndexPath indexPathForRow:row inSection:section]];return;}
    Class cls=NSClassFromString(@[@"TIORecordingExportsPanel",@"TIORecordingTextPanel",@"TIOLifelogExportsPanel",@"TIOAlwaysOnAudioPanel"][row]);
    UIViewController *p=[cls isSubclassOfClass:UITableViewController.class]?[(UITableViewController *)[cls alloc]initWithStyle:UITableViewStyleInsetGrouped]:[cls new];if(p)[self.navigationController pushViewController:p animated:YES];
}
- (void)legacySelect:(UITableView *)tableView at:(NSIndexPath *)ip {
    if(ip.section==0&&ip.row==0){
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"回答モデル" message:@"実験モードでは認識された質問を設定先のサービスへ送ります。未対応の処理は公式アプリへ戻します。検証済みの会話データ形式がない場合、選択だけを記録します。" preferredStyle:UIAlertControllerStyleActionSheet];
        NSArray *titles=@[@"公式の回答",@"ランダム文字列で検証（独自 API は呼ばない）",@"独自モデル（実験）"];
        for(NSInteger i=0;i<3;i++){[a addAction:[UIAlertAction actionWithTitle:titles[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){[Controller cancel];[Prefs setInteger:i forKey:@"mode"];[self.tableView reloadData];if(i&&![Prefs stringForKey:@"verifiedChatDomain"])Alert(@"切り替えは保留中です",@"このバージョンの会話応答 domain を確認する必要があります。先に公式モードで一度質問し、開発者が確認してから切り替えます。");}]];}
        [a addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=self.view;a.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,100,1,1);[self presentViewController:a animated:YES completion:nil];
    }else if(ip.section==0&&ip.row==1)[self configure];
    else if(ip.section==0&&ip.row==8)[self configureSearch];
    else if(ip.section==0&&ip.row==9)[self testSearch];
    else if(ip.section==0&&ip.row==10)TIOOpenTodoRuntime(self);
    else if(ip.section==0&&ip.row==12)TIOOpenNewsReader(self);
    else if(ip.section==0&&ip.row==11)Alert(@"当前语音模型 Tools",[NSString stringWithFormat:@"knowledge_query / knowledge_query_status：%@。Codex只读检索微信归档、项目与学习资料，引用来源；不修改知识库。\n\ncreate_todo：标题新增，交给官方入口；等待列表新ID才确认，超时不重试。\nweb_search：TinyFish公开搜索，需开启联网。\n\n待办工具不支持修改、删除、完成、提醒时间，暂不写入知识库网页。只有真实语音会话拥有待办执行上下文。",TIOKnowledgeEnabled()?@"已开启":@"未开启，请在知识库配置连接"]);
    else if(ip.section==0&&ip.row==4){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"清空自有模型上下文？" message:@"仅清空本扩展内存中的聊天历史，不删除官方记录。正在进行的自有请求会取消并恢复官方模式。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[a addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){[Controller cancel];[Controller.history clear];[Prefs setInteger:0 forKey:@"mode"];[self.tableView reloadData];}]];[self presentViewController:a animated:YES completion:nil];}
    else if(ip.section==0&&ip.row==5)TIOOpenProfile(self);
    else if(ip.section==0&&ip.row==2){[_testRequest cancel];_testRequest=[TIORequest new];__weak typeof(self) weakSelf=self;_testRequest.update=^(NSString *text,BOOL done,NSString *error){if(done){Alert(error?@"API テスト失敗":@"API テスト結果",error?:text);weakSelf.testRequest=nil;}};[_testRequest startQuestion:@"「独自 API のテストに成功しました」とだけ日本語で答えてください。"];
    }else if(ip.section==1&&ip.row==1){dispatch_async(ArchiveQueue,^{NSError *error=nil;NSArray *urls=[Archive exportAt:NSDate.date error:&error];dispatch_async(dispatch_get_main_queue(),^{if(!urls){Alert(@"暂无可分享文件",error.localizedDescription?:@"导出失败，原件未改。");return;}UIActivityViewController *sheet=[[UIActivityViewController alloc]initWithActivityItems:urls applicationActivities:nil];sheet.popoverPresentationController.sourceView=self.view;sheet.popoverPresentationController.sourceRect=CGRectMake(self.view.bounds.size.width/2,100,1,1);[self presentViewController:sheet animated:YES completion:nil];});});}
    else if(ip.section==2)[self.tableView reloadData];
}
@end

// Simulator-only host uses these same UIKit controllers, no official binary,
// credentials, hardware hooks or network-backed model service.
#if TIO_UI_PREVIEW
UITabBarController *TIOCreateResearchPreview(void){
    Prefs=[[NSUserDefaults alloc]initWithSuiteName:@"io.turboio.research.preview"];
    [Prefs registerDefaults:@{@"mode":@0,@"voiceExitCommands":@YES,@"ttsEnabled":@YES,@"ttsEngine":@"local"}];
    VoiceTTS=[[TIOVoiceTTS alloc]initWithKeyProvider:^{return @"";}];
    VoiceTTS.localMode=YES;
    Controller=[TIOController new];Diagnostic=@"界面预览：未连接眼镜，未加载官方通信库";
    ArchiveQueue=dispatch_queue_create("io.turboio.preview.archive",DISPATCH_QUEUE_SERIAL);
    Archive=[[TIOTranscriptArchive alloc]initWithDirectory:[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ResearchPreview"]]];
    TIONewsConfigure(^TIONewsCancel(NSString *prompt,void (^done)(NSString *,NSString *)){
        __block BOOL cancelled=NO;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{if(!cancelled)done(@"界面预览样稿\n\n这是合成内容，不是真实新闻。本预览不联网、不连接眼镜，也不包含任何私人配置。",nil);});return [^{cancelled=YES;} copy];
    });
    NSMutableArray *pages=[NSMutableArray new];for(NSString *key in @[@"model",@"library",@"diagnostics"]){TIOPanel *p=[[TIOPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];p.page=key;[pages addObject:p];}
    return TIOCreateResearchTabs(@[pages[0],TIONewsReaderController(),pages[1],pages[2]]);
}
#endif

@interface TIOEntryTarget : NSObject
+ (void)show;
@end
@implementation TIOEntryTarget
+ (void)show {UIViewController *top=TopController();if(!top||top.tabBarController.view.tag==7920||top.view.tag==7920)return;static UITabBarController *shell;
    if(!shell){NSMutableArray *pages=[NSMutableArray new];for(NSString *key in @[@"model",@"library",@"diagnostics"]){TIOPanel *p=[[TIOPanel alloc]initWithStyle:UITableViewStyleInsetGrouped];p.page=key;[pages addObject:p];}shell=TIOCreateResearchTabs(@[pages[0],TIONewsReaderController(),pages[1],pages[2]]);}
    for(UINavigationController *nav in shell.viewControllers)[nav popToRootViewControllerAnimated:NO];Entry.hidden=YES;[top presentViewController:shell animated:YES completion:nil];}
@end

static BOOL Signature(Class cls,NSString *name,NSUInteger argc,const char *returnType,NSArray<NSString *> *types) {
    Method m=class_getInstanceMethod(cls,NSSelectorFromString(name));if(!m||method_getNumberOfArguments(m)!=argc)return NO;
    char *r=method_copyReturnType(m);BOOL ok=r&&r[0]==returnType[0];free(r);
    for(NSUInteger i=2;i<argc;i++){char *t=method_copyArgumentType(m,(unsigned)i);NSString *allowed=types[i-2];if(!t||![allowed containsString:[NSString stringWithFormat:@"%c",t[0]]])ok=NO;free(t);}return ok;
}
#import "HostCompatibility.h"
static BOOL VersionMatches(void) {
    if(![NSBundle.mainBundle.bundleIdentifier isEqual:TargetBundle])return NO;
    const struct mach_header *h=NULL;
    const char *executable=NSBundle.mainBundle.executablePath.fileSystemRepresentation;
    for(uint32_t i=0;i<_dyld_image_count();i++){const char *name=_dyld_get_image_name(i);if(name&&executable&&strcmp(name,executable)==0){h=_dyld_get_image_header(i);break;}}
    return TIOHostImageMatches(h,NSBundle.mainBundle.infoDictionary);
}
static void AddEntry(void) {
    UIViewController *top=TopController();UIWindow *window=top.view.window;if(!window)return;
    if(top.tabBarController.view.tag==7920||top.view.tag==7920){Entry.hidden=YES;return;}
    if(!Entry){Entry=[UIButton buttonWithType:UIButtonTypeSystem];[Entry setTitle:@"Turbo" forState:UIControlStateNormal];Entry.accessibilityLabel=@"Turbo IO の追加機能を開く";Entry.backgroundColor=UIColor.systemIndigoColor;[Entry setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];Entry.layer.cornerRadius=20;[Entry addTarget:TIOEntryTarget.class action:@selector(show) forControlEvents:UIControlEventTouchUpInside];}
    Entry.hidden=NO;Entry.frame=CGRectMake(window.bounds.size.width-66,window.safeAreaInsets.top+80,54,40);[window addSubview:Entry];
    if(VersionMatches())TIOStartHomeTabBridge(Entry,^{[TIOEntryTarget show];});
}
__attribute__((constructor)) static void Load(void) {
    // Do not message Foundation/UIKit or create an ObjC autorelease pool under
    // the remote loader lock. All setup runs on main after scheduling via C API.
    dispatch_async(dispatch_get_main_queue(),^{
        @autoreleasepool {
            if(![NSBundle.mainBundle.bundleIdentifier isEqual:TargetBundle])return;
#if TIO_OTA_RESEARCH_ENABLED
            TIOStartExperimentalOTAFeedIfMarked();
#endif
            Prefs=[[NSUserDefaults alloc]initWithSuiteName:Domain];
            [Prefs registerDefaults:@{@"voiceExitCommands":@YES,@"ttsEnabled":@YES,@"ttsEngine":@"local"}];
            Controller=[TIOController new];
            ImportPrivateBootstrap();
            VoiceTTS=[[TIOVoiceTTS alloc]initWithKeyProvider:^{return ReadKey(TIOVoiceTTSService());}];
            VoiceTTS.localMode=[[Prefs stringForKey:@"ttsEngine"] isEqual:@"local"];
            TIONewsConfigure(^TIONewsCancel(NSString *prompt,void (^completion)(NSString *,NSString *)){
                TIORequest *request=[TIORequest new];request.newsMode=YES;request.history=@[];
                request.update=^(NSString *text,BOOL done,NSString *error){if(done)completion(text,error);};
                // Start next turn so even immediate config errors do not race
                // assignment of the cancellation handle in the news controller.
                __block BOOL cancelled=NO;dispatch_async(dispatch_get_main_queue(),^{if(!cancelled)[request startQuestion:prompt];});
                return [^{cancelled=YES;[request cancel];} copy];
            });
            // Research rows are explicit routes now, not a chain of table hooks.
            [Prefs registerDefaults:@{@"voiceExitCommands":@YES,@"ttsEnabled":@YES,@"ttsEngine":@"local"}];
            // Do not automatically resume text capture or a model takeover after relaunch/crash.
            [Prefs setBool:NO forKey:@"captureFinalText"];[Prefs setInteger:0 forKey:@"mode"];
            [Prefs removeObjectForKey:@"verifiedChatDomain"];
            NSURL *library=[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
            Archive=[[TIOTranscriptArchive alloc]initWithDirectory:[library URLByAppendingPathComponent:@"TurboIOPrivateAddon" isDirectory:YES]];ArchiveQueue=dispatch_queue_create("io.turboio.private.archive",DISPATCH_QUEUE_SERIAL);
            Class voice=NSClassFromString(@"rayneo_venus_sdk_plugin.AiResultListenerBridge"),ao=NSClassFromString(@"rayneo_venus_sdk_plugin.AlwaysOnResultListenerBridge");
            BOOL valid=VersionMatches()&&Signature(voice,@"onAsrResult:isFinish:sessionId:",5,"v",@[@"@",@"Bc",@"@"])&&Signature(voice,@"onNlpResult:",3,"v",@[@"@"])&&Signature(voice,@"onResponseComplete",2,"v",@[])&&Signature(ao,@"onAlwaysOnResponse:",3,"v",@[@"@"]);
            if(valid){OriginalAsr=(void *)method_setImplementation(class_getInstanceMethod(voice,NSSelectorFromString(@"onAsrResult:isFinish:sessionId:")),(IMP)AsrHook);OriginalNlp=(void *)method_setImplementation(class_getInstanceMethod(voice,NSSelectorFromString(@"onNlpResult:")),(IMP)NlpHook);OriginalComplete=(void *)method_setImplementation(class_getInstanceMethod(voice,NSSelectorFromString(@"onResponseComplete")),(IMP)CompleteHook);OriginalAlwaysOn=(void *)method_setImplementation(class_getInstanceMethod(ao,NSSelectorFromString(@"onAlwaysOnResponse:")),(IMP)AlwaysOnHook);HooksReady=YES;Diagnostic=@"版本和 ObjC 回调签名匹配，等待真实事件";}else Diagnostic=@"版本或 ABI 不匹配：未修改任何回调";
            Class helper=NSClassFromString(@"rayneo_venus_sdk_plugin.VoiceAssistantHelper");
            VoiceExitReady=valid&&Signature(object_getClass(helper),@"shared",2,"@",@[])&&Signature(helper,@"stopWorkflow",2,"v",@[])&&Signature(voice,@"onAudioRecordStart",2,"v",@[]);
            if(VoiceExitReady)OriginalAudioStart=(void *)method_setImplementation(class_getInstanceMethod(voice,NSSelectorFromString(@"onAudioRecordStart")),(IMP)AudioStartHook);
            if(valid)TIOInstallTodoRuntime();
            NSMutableString *loadInfo=[NSMutableString stringWithFormat:@"setup reached; hooks=%d; version=%d; voiceClass=%d; alwaysOnClass=%d\n",valid,VersionMatches(),voice!=Nil,ao!=Nil];
            [loadInfo appendFormat:@"bundle=%@; version=%@; build=%@\n",NSBundle.mainBundle.bundleIdentifier,[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"]];
            for(uint32_t i=0;i<_dyld_image_count();i++){const char *name=_dyld_get_image_name(i);if(name&&[[NSString stringWithUTF8String:name].lastPathComponent isEqual:@"Runner"]){const struct mach_header *h=_dyld_get_image_header(i);[loadInfo appendFormat:@"Runner image index=%u magic=%x\n",i,h->magic];}}
            for(NSString *sel in @[@"onAsrResult:isFinish:sessionId:",@"onNlpResult:",@"onResponseComplete",@"onAlwaysOnResponse:"]){Method m=class_getInstanceMethod([sel isEqual:@"onAlwaysOnResponse:"]?ao:voice,NSSelectorFromString(sel));[loadInfo appendFormat:@"%@ %s\n",sel,m?method_getTypeEncoding(m):"missing"];}
            [loadInfo writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"TurboIOPrivateAddon-load.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){AddEntry();}];
            [NSNotificationCenter.defaultCenter addObserverForName:@"TIOResearchClosed" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){AddEntry();}];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{AddEntry();});
        }
    });
}
