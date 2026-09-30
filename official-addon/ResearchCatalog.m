#import "ResearchCatalog.h"
static NSDictionary *Row(NSString *key,NSString *title,NSString *icon,NSInteger section,NSInteger row){return @{@"key":key,@"title":title,@"icon":icon,@"section":@(section),@"row":@(row)};}
NSArray<NSDictionary *> *TIOResearchSections(NSString *page){
    if([page isEqual:@"model"])return @[
        @{@"title":@"エージェント",@"rows":@[Row(@"agent",@"実行エージェント",@"cpu",-2,0),Row(@"knowledge",@"知識ベースと参照元",@"books.vertical",-2,1)]},
        @{@"title":@"回答方法",@"rows":@[Row(@"mode",@"現在の回答方法",@"square.stack.3d.up",0,0)]},
        @{@"title":@"独自モデル",@"rows":@[Row(@"api",@"APIとキー",@"cube",0,1),Row(@"thinking",@"深い推論を無効化",@"bolt",0,3)]},
        @{@"title":@"検索とツール",@"rows":@[Row(@"search",@"ウェブ検索を許可",@"globe",0,7),Row(@"searchKey",@"検索サービスの設定",@"key",0,8),Row(@"tools",@"モデルが使えるツール",@"wrench.and.screwdriver",0,11)]},
        @{@"title":@"音声と会話履歴",@"rows":@[Row(@"exit",@"音声で会話を終了",@"waveform",0,6),Row(@"prompt",@"プロフィールと指示",@"text.bubble",0,5),Row(@"history",@"今回の会話履歴",@"clock.arrow.circlepath",0,4)]},
        @{@"title":@"眼鏡での読み上げ・実験",@"rows":@[Row(@"tts",@"回答を読み上げる",@"waveform.circle",-2,13),Row(@"ttsEngine",@"読み上げエンジン",@"slider.horizontal.3",-2,16),Row(@"ttsKey",@"Ali Flash TTS の設定",@"key",-2,14),Row(@"ttsTest",@"テスト音声を再生",@"play.circle",-2,15)]}];
    if([page isEqual:@"library"])return @[
#if TIO_LOCAL_TRANSLATION
        @{@"title":@"オフライン字幕と翻訳・iOS 26以降",@"rows":@[Row(@"localTranslation",@"Apple / Hy-MT2 端末内翻訳",@"character.bubble",-2,21)]},
#endif
#if TIO_MUSIC
        @{@"title":@"音楽",@"rows":@[Row(@"music",@"NetEase Cloud Music・10番目のメニュー",@"music.note",-2,20)]},
#endif
        @{@"title":@"地図と眼鏡のナビ",@"rows":@[Row(@"navigation",@"徒歩・自転車・車のナビ",@"map",-3,0)]},
        @{@"title":@"録音と整理",@"rows":@[Row(@"recordings",@"録音とファイル共有",@"waveform",-1,0),Row(@"summary",@"文字起こしの整理",@"text.badge.star",-1,1)]},
        @{@"title":@"ライフログ",@"rows":@[Row(@"lifelogText",@"保存したテキスト",@"doc.text",-1,2),Row(@"lifelogAudio",@"音声の保存と共有",@"waveform.circle",-1,3),Row(@"capture",@"今後の確定テキストを保存",@"square.and.arrow.down",1,0),Row(@"archive",@"テキストをエクスポート",@"square.and.arrow.up",1,1)]}];
    if([page isEqual:@"diagnostics"])return @[
#if TIO_OTA_RESEARCH_ENABLED
#if TIO_MUSIC
        @{@"title":@"TMU1 実験ファームウェア・起動不能のリスク",@"rows":@[Row(@"experimentalOTA",@"TMU1 音楽ファームウェア・初期状態はロック",@"exclamationmark.shield",-4,0),Row(@"displayPhone",@"Turbo Display・画像転送テスト",@"rectangle.connected.to.line.below",-4,1)]},
#elif TIO_NATIVE_NAV
        @{@"title":@"TNV1 実験ファームウェア・起動不能のリスク",@"rows":@[Row(@"experimentalOTA",@"TNV1 ナビ用ファームウェア・初期状態はロック",@"exclamationmark.shield",-4,0),Row(@"displayPhone",@"Turbo Display・画像転送テスト",@"rectangle.connected.to.line.below",-4,1)]},
#else
        @{@"title":@"高リスクのファームウェア実験・日常使用不可",@"rows":@[Row(@"experimentalOTA",@"R3 実験版・先にリスクを確認",@"exclamationmark.shield",-4,0)]},
#endif
#endif
        @{@"title":@"動作状況",@"rows":@[Row(@"status",@"対応状況とコールバック",@"checkmark.shield",2,0)]},
        @{@"title":@"手動テスト",@"rows":@[Row(@"apiTest",@"モデル API をテスト",@"bubble.left.and.bubble.right",0,2),Row(@"searchTest",@"ウェブ検索をテスト",@"globe",0,9),Row(@"todoTest",@"ToDo プロトコルを確認",@"checklist",0,10)]}];
    return @[];
}
