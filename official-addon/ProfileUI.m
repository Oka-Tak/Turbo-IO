#import "ProfileUI.h"
#import "Profile.h"
@interface TIOProfilePanel:UIViewController
@property(nonatomic) UITextField *nameField,*identityField;
@property(nonatomic) UITextView *preferences;
@end
@implementation TIOProfilePanel
- (void)viewDidLoad{[super viewDidLoad];self.title=@"プロフィールと指示";self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:@"保存" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;[self.view addSubview:scroll];
    UIStackView *stack=[UIStackView new];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=14;stack.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],[stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],[stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],[stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]]];
    NSDictionary *p=TIOProfile();NSArray *labels=@[@"呼び名（80文字まで）",@"立場・背景（500文字まで）",@"回答の希望・追加の指示（2000文字まで）"];
    for(NSUInteger i=0;i<3;i++){UILabel *label=[UILabel new];label.text=labels[i];label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];[stack addArrangedSubview:label];
        if(i<2){UITextField *field=[UITextField new];field.borderStyle=UITextBorderStyleRoundedRect;field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];field.text=p[i?@"identity":@"name"];field.placeholder=i?@"例：ソフトウェア開発者、AIに関心がある":@"AIに呼んでほしい名前";[field.heightAnchor constraintGreaterThanOrEqualToConstant:48].active=YES;[stack addArrangedSubview:field];if(i)self.identityField=field;else self.nameField=field;}
        else{self.preferences=[UITextView new];self.preferences.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.preferences.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;self.preferences.layer.cornerRadius=12;self.preferences.textContainerInset=UIEdgeInsetsMake(12,12,12,12);self.preferences.text=p[@"preferences"];[self.preferences.heightAnchor constraintEqualToConstant:200].active=YES;[stack addArrangedSubview:self.preferences];}
    }
    UILabel *note=[UILabel new];note.numberOfLines=0;note.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];note.textColor=UIColor.secondaryLabelColor;note.text=@"初期値はすべて空欄です。保存すると次の独自モデルとの会話から反映されます。公式モデルの設定は変わりません。\n入力内容は端末内に保存され、独自モデルとの会話時に設定したサービスへ送信されます。APIキー、パスワード、送信したくない個人情報は入力しないでください。\n初期値に戻すには欄を空にして保存します。保存せずに戻った場合、設定は変わりません。";[stack addArrangedSubview:note];
}
- (void)save{BOOL ok=TIOSaveProfile(@{@"name":self.nameField.text?:@"",@"identity":self.identityField.text?:@"",@"preferences":self.preferences.text?:@""});if(ok){[self.view endEditing:YES];[self.navigationController popViewControllerAnimated:YES];}else{UIAlertController *a=[UIAlertController alertControllerWithTitle:@"保存できませんでした" message:@"文字数と、使用できない制御文字を確認してください。" preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil];}}
@end
void TIOOpenProfile(UIViewController *host){[host.navigationController pushViewController:[TIOProfilePanel new] animated:YES];}
