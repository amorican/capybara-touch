#import "CTCapybaraClient.h"
#import "CTInterface.h"
#import "NSArray+Enumerable.h"
#import "UIFakeTouch.h"
#import "UIFakeKeypress.h"

@interface CTCapybaraClient ()

@property (strong, nonatomic) CTInterface *interface;
@property (copy, nonatomic) void (^webViewLoadCompletionBlock)();
@property (strong, nonatomic) NSString *capybaraJS;
@property (strong, nonatomic) UIFakeKeypress *fakeKeypress;
@property (strong, nonatomic) NSHTTPURLResponse *lastResponse;

@end

@implementation CTCapybaraClient

- (instancetype)init
{
    if (self = [super init]) {
        self.interface = [[CTInterface alloc] init];
        self.interface.delegate = self;

        self.webView = [[UIWebView alloc] init];
        self.webView.delegate = self;

        self.fakeKeypress = [[UIFakeKeypress alloc] init];
    }
    return self;
}

- (void)connect {
    [self.interface startWithPort:9292 domain:@"localhost"];
}

#pragma mark - CTCapybaraDelegate methods

- (void)visit:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    [self.webView loadRequest:request];

    __weak CTCapybaraClient *weakSelf = self;
    self.webViewLoadCompletionBlock = ^{
        [weakSelf.interface sendSuccessMessage];
    };
}

- (void)reset {
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    for (NSHTTPCookie *cookie in [storage cookies]) {
        [storage deleteCookie:cookie];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];

    [self.webView loadHTMLString:@"" baseURL:nil];

    CTInterface *interface = self.interface;
    self.webViewLoadCompletionBlock = ^{
        [interface sendSuccessMessage];
    };
}

- (void)javascriptCommand:(NSArray *)arguments {
    NSString *command = arguments[0];

    NSArray *args = [arguments subarrayWithRange:NSMakeRange(1, arguments.count - 1)];
    args = [args map:^id(NSString *argument, NSUInteger idx) {
        return [NSString stringWithFormat:@"\"%@\"", [self stripJsonArrayFromNodeIndex:argument]];
    }];

    NSString *js = [NSString stringWithFormat:@"Capybara.%@(%@);", command, [args componentsJoinedByString:@", "]];

    NSString *result = [self execute:js];
    if (![result isEqualToString:@"wait"]) {
        [self.interface sendSuccessMessage:result];
    }
}

- (void)executeScript:(NSString *)script {
    NSString *result = [self execute:script];
    [self.interface sendSuccessMessage:result];
}

#pragma mark - Traversing the DOM
- (void)findXpath:(NSString *)xpath {
    NSString *escapedXpath = [xpath stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *jsString = [NSString stringWithFormat:@"Capybara.findXpath(\"%@\");", escapedXpath];
    NSString *result = [self execute:jsString];

    [self.interface sendSuccessMessage:result];
}

- (void)findCSS:(NSString *)selector {
    NSString *escapedSelector = [selector stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *jsString = [NSString stringWithFormat:@"Capybara.findCss(\"%@\");", escapedSelector];
    NSString *result = [self execute:jsString];

    [self.interface sendSuccessMessage:result];
}

#pragma mark - Returning information
- (void)currentURL {
    [self.interface sendSuccessMessage:self.webView.request.URL.absoluteString];
}

- (void)body {
    NSString *result = [self execute:@"Capybara.body();"];
    [self.interface sendSuccessMessage:result];
}

- (void)title {
    NSString *result = [self execute:@"document.title"];
    [self.interface sendSuccessMessage:result];
}

- (void)headers {
    if (!self.lastResponse) return;

    NSError *error;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:self.lastResponse.allHeaderFields options:NSJSONWritingPrettyPrinted error:&error];

    if (!jsonData) return;

    NSString *headerString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    headerString = [headerString stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];

    [self.interface sendSuccessMessage:headerString];
}

- (void)statusCode {
    if (!self.lastResponse) return;
    [self.interface sendSuccessMessage:[@(self.lastResponse.statusCode) stringValue]];
}

#pragma mark - UIWebViewDelegate
- (void)webViewDidFinishLoad:(UIWebView *)webView {
    NSCachedURLResponse *resp = [[NSURLCache sharedURLCache] cachedResponseForRequest:webView.request];
    self.lastResponse = (NSHTTPURLResponse*)resp.response;

    [self injectCapybaraIntoCurrentPage];

    if (self.webViewLoadCompletionBlock) {
        self.webViewLoadCompletionBlock();
        self.webViewLoadCompletionBlock = nil;
    }
}

- (BOOL)webView:(UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType {

    NSDictionary *mapping = @{
                              @"click": @"tapAtPoint:",
                              @"focus": @"partialTapAtPoint:",
                              @"keypress": @"keypress:"
                              };

    if ([request.URL.scheme isEqualToString:@"capybara"]) {

        NSString *action = mapping[request.URL.host];
        if (action) {
            SEL actionSelector = NSSelectorFromString(action);

            NSString *jsonString = [request.URL.path substringFromIndex:1];
            NSData *jsonData = [jsonString dataUsingEncoding:NSStringEncodingConversionAllowLossy];
            NSError *jsonError;

            id data = [NSJSONSerialization JSONObjectWithData:jsonData options:NSJSONReadingAllowFragments error:&jsonError];

            if ([self respondsToSelector:actionSelector]) {
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [self performSelector:actionSelector withObject:data];
                #pragma clang diagnostic pop
            }
        }
        return NO;
    }

    return YES;
}

#pragma mark - Generate fake events
- (void)tapAtPoint:(NSDictionary *)point {
    UIFakeTouch *touch = [[UIFakeTouch alloc] initInView:self.webView point:CGPointMake([point[@"x"] floatValue], [point[@"y"] floatValue])];
    [touch sendTap];

    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        if (self.webView.isLoading) {
            CTCapybaraClient *weakSelf = self;
            self.webViewLoadCompletionBlock = ^{
                [weakSelf.interface sendSuccessMessage];
            };
        } else {
            [self.interface sendSuccessMessage];
        }
    });

}

- (void)partialTapAtPoint:(NSDictionary *)point {
    UIFakeTouch *touch = [[UIFakeTouch alloc] initInView:self.webView point:CGPointMake([point[@"x"] floatValue], [point[@"y"] floatValue])];
    [touch sendTap];
}

- (void)keypress:(NSString *)key {
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC));
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        UIFakeKeypress *keypress = [[UIFakeKeypress alloc] init];
        [keypress sendKeypressForString:key];
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC));
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self.interface sendSuccessMessage];
        });
    });
}

#pragma mark - Private
- (NSString *)execute:(NSString *)js {
    return [self.webView stringByEvaluatingJavaScriptFromString:js];
}

- (void)injectCapybaraIntoCurrentPage {
    if (!self.capybaraJS) {
        NSString *fileName = [[NSBundle mainBundle] pathForResource:@"capybara" ofType:@"js"];
        NSData *fileData = [NSData dataWithContentsOfFile:fileName];
        self.capybaraJS = [[NSString alloc] initWithData:fileData encoding:NSStringEncodingConversionAllowLossy];
    }

    [self execute:self.capybaraJS];
}

// Turns '["5"]' into "5"
- (NSString *)stripJsonArrayFromNodeIndex:(NSString *)string {
    NSError *error;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[\\\"(\\d+)\\\"\\]" options:0 error:&error];
    NSTextCheckingResult *result = [regex firstMatchInString:string options:0 range:NSMakeRange(0, string.length)];
    if (result && result.numberOfRanges == 2) {
        return [string substringWithRange:[result rangeAtIndex:1]];
    } else {
        return string;
    }
}

@end
