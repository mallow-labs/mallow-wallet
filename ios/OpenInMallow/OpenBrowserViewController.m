#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MallowOpenBrowserViewController : UIViewController
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL finished;
@end

@implementation MallowOpenBrowserViewController

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (self.started) return;
  self.started = YES;
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  [self loadSharedURL];
}

- (void)loadSharedURL {
  // Prefer the actual URL to an accompanying page title or description.
  for (NSString *type in @[UTTypeURL.identifier, UTTypePlainText.identifier]) {
    for (NSExtensionItem *item in self.extensionContext.inputItems) {
      for (NSItemProvider *provider in item.attachments) {
        if (![provider hasItemConformingToTypeIdentifier:type]) continue;
        __weak typeof(self) weakSelf = self;
        [provider loadItemForTypeIdentifier:type options:nil
                         completionHandler:^(id value, NSError *error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self = weakSelf;
            if (!self || self.finished) return;
            NSString *text = [value isKindOfClass:NSURL.class]
                ? [(NSURL *)value absoluteString]
                : ([value isKindOfClass:NSString.class] ? value : nil);
            if (error || !text) {
              [self showError:@"The shared link could not be read."];
              return;
            }
            [self openWebsite:[text stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]];
          });
        }];
        return;
      }
    }
  }
  [self showError:@"Share a website link to open it in mallow browser."];
}

- (void)openWebsite:(NSString *)text {
  NSURLComponents *website = [NSURLComponents componentsWithString:text];
  if (![website.scheme.lowercaseString isEqualToString:@"https"] ||
      website.host.length == 0 || website.user != nil || website.password != nil ||
      [text rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
    [self showError:@"Only HTTPS website links without embedded credentials can be opened."];
    return;
  }
  NSURLComponents *handoff = [[NSURLComponents alloc] init];
  handoff.scheme = @"mallowwallet";
  handoff.host = @"browser";
  handoff.path = @"/open";
  handoff.queryItems = @[
    [NSURLQueryItem queryItemWithName:@"url" value:text],
    [NSURLQueryItem queryItemWithName:@"request" value:NSUUID.UUID.UUIDString],
  ];
  // Dart decodes query parameters as form data, where a literal + means a
  // space. NSURLComponents leaves + unescaped, so protect it explicitly.
  handoff.percentEncodedQuery = [handoff.percentEncodedQuery
      stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
  NSURL *url = handoff.URL;
  if (!url) {
    [self showError:@"The shared link could not be opened."];
    return;
  }

  // Action extensions have no supported API to launch their containing app.
  // This responder-chain handoff is also used by Chromium's Open extension;
  // keep it isolated because iOS updates can stop providing this responder.
  SEL selector = NSSelectorFromString(@"openURL:options:completionHandler:");
  UIResponder *responder = self;
  while ((responder = responder.nextResponder)) {
    if (![responder respondsToSelector:selector]) continue;
    NSMethodSignature *signature = [responder methodSignatureForSelector:selector];
    if (!signature) continue;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = responder;
    invocation.selector = selector;
    // UIApplication takes an options dictionary, but UIScene, which iOS 26
    // puts first in an extension's chain, takes an options object and aborts
    // on a dictionary (-universalLinksOnly sent to it).
    id options = [responder isKindOfClass:UIScene.class]
        ? [[UISceneOpenExternalURLOptions alloc] init]
        : @{};
    __weak typeof(self) weakSelf = self;
    void (^completion)(BOOL) = ^(BOOL success) {
      dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self = weakSelf;
        if (!self || self.finished) return;
        if (success) {
          self.finished = YES;
          [self.extensionContext completeRequestReturningItems:nil completionHandler:nil];
        } else {
          [self showError:@"mallow could not be opened. Open the app and try again."];
        }
      });
    };
    [invocation setArgument:&url atIndex:2];
    [invocation setArgument:&options atIndex:3];
    [invocation setArgument:&completion atIndex:4];
    [invocation retainArguments];
    [invocation invoke];
    // Some hosts never call the completion handler. Leave an exit instead of
    // stranding the user in a blank extension if the handoff stops working.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (self && !self.finished) {
        [self showError:@"mallow could not be opened. Open the app and try again."];
      }
    });
    return;
  }
  [self showError:@"mallow could not be opened. Open the app and try again."];
}

- (void)showError:(NSString *)message {
  if (self.finished) return;
  self.finished = YES;
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Open in mallow browser" message:message
      preferredStyle:UIAlertControllerStyleAlert];
  __weak typeof(self) weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault
      handler:^(UIAlertAction *action) {
        [weakSelf.extensionContext completeRequestReturningItems:nil completionHandler:nil];
      }]];
  [self presentViewController:alert animated:YES completion:nil];
}
@end
