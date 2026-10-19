#import <Foundation/Foundation.h>
#import "OmnibarPaletteModel.h"
#import "OmnibarURLResolver.h"

static NSUInteger checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

static void TestModes(void) {
    for (NSArray *row in @[@[@"search words", @"search", @"search words"], @[@"  > rld  ", @"commands", @"rld"],
                           @[@"@example", @"tabs", @"example"], @[@">", @"commands", @""], @[@"@", @"tabs", @""],
                           @[@"email@example.com", @"search", @"email@example.com"], @[@".cnn", @"search", @".cnn"],
                           @[@"  >>literal  ", @"commands", @">literal"], @[@"  ", @"search", @""]]) {
        NSDictionary *parsed = [OmnibarPaletteModel parsedInput:row[0]];
        Check([parsed[@"mode"] isEqual:row[1]] && [parsed[@"query"] isEqual:row[2]], @"Mode parser consumes only the first leading marker");
    }
}

static void TestAddressPreview(void) {
    for (NSString *query in @[@"", @" ", @"ordinary query", @"café & tea", @"site:apple.com", @"weather: London"]) {
        Check([OmnibarPaletteModel addressPreviewForInput:query defaultURLSuffix:@".co.uk"] == nil,
              @"Ordinary searches do not expose the inert classification URL");
    }
    NSArray *cases = @[
        @[@".cnn", @"https://www.cnn.co.uk/", @YES],
        @[@".bsky.app", @"https://www.bsky.app/", @YES],
        @[@".www.cnn.com:8443/a?q=one%2Ftwo#here", @"https://www.cnn.com:8443/a?q=one%2Ftwo#here", @YES],
        @[@".bücher.de/café%2Ftest?q=a%2Bb 中文#frag", @"https://www.xn--bcher-kva.de/caf%C3%A9%2Ftest?q=a%2Bb%20%E4%B8%AD%E6%96%87#frag", @YES],
        @[@"example.com", @"https://example.com/", @NO],
        @[@"localhost:3000", @"http://localhost:3000/", @NO],
        @[@"about:blank", @"about:blank", @NO]
    ];
    for (NSArray *row in cases) {
        NSDictionary *preview = [OmnibarPaletteModel addressPreviewForInput:row[0] defaultURLSuffix:@".co.uk"];
        Check([preview[@"isAddress"] boolValue] && [preview[@"valid"] boolValue]
              && [preview[@"shorthand"] isEqual:row[2]] && [preview[@"destination"] isEqual:row[1]] && !preview[@"error"],
              @"Local address preview uses the authoritative native destination");
    }
    for (NSString *input in @[@".", @".cnn.", @".cnn:65536", @"https://", @"https://user:FAKE_SECRET@example.com",
                              @".user:FAKE_SECRET@example.com", @"line\nbreak"]) {
        NSDictionary *preview = [OmnibarPaletteModel addressPreviewForInput:input defaultURLSuffix:@".com"];
        Check([preview[@"isAddress"] boolValue] && ![preview[@"valid"] boolValue] && !preview[@"destination"]
              && [preview[@"error"] length] && ![preview[@"error"] containsString:@"FAKE_SECRET"],
              @"Invalid address preview remains an address with a credential-free error");
    }
}

static void TestRanking(void) {
    NSObject *tabReference = [NSObject new];
    NSArray *items = @[
        @{ @"identifier": @"reload", @"kind": @"command", @"title": @"Reload Tab", @"subtitle": @"View → Reload Page", @"keywords": @"refresh" },
        @{ @"identifier": @"new", @"kind": @"command", @"title": @"New Tab", @"subtitle": @"File → New Tab", @"keywords": @"create open" },
        @{ @"identifier": @"cafe", @"kind": @"tab", @"title": @"Café Notes", @"subtitle": @"notes.example", @"tab": tabReference },
        @{ @"identifier": @"tab", @"kind": @"tab", @"title": @"Tab", @"subtitle": @"example.com" }
    ];
    NSArray *result = [OmnibarPaletteModel rankedItems:items query:@"rld"];
    Check(result.count == 1 && [result[0][@"identifier"] isEqual:@"reload"], @"Subsequence abbreviation matches a command");
    Check([[OmnibarPaletteModel rankedItems:items query:@"REFRESH"] isEqual:@[items[0]]], @"Keywords match without case sensitivity");
    result = [OmnibarPaletteModel rankedItems:items query:@"cafe notes.example"];
    Check(result.count == 1 && result[0] == items[2] && result[0][@"tab"] == tabReference,
          @"Words match across accent-normalized fields and preserve exact item metadata");
    result = [OmnibarPaletteModel rankedItems:items query:@"tab"];
    Check([result.firstObject[@"identifier"] isEqual:@"tab"], @"Exact title ranks above a contained word");
    Check([[OmnibarPaletteModel rankedItems:items query:@" "] isEqual:items], @"Empty query preserves source order");
    Check([OmnibarPaletteModel rankedItems:items query:@"no possible matching phrase"].count == 0,
          @"Every query word must match somewhere in an item");
    NSArray *ties = @[@{@"title": @"Equal", @"identifier": @1}, @{@"title": @"Equal", @"identifier": @2}];
    Check([[OmnibarPaletteModel rankedItems:ties query:@"eq"] isEqual:ties], @"Equal scores remain stable");
    Check([OmnibarPaletteModel rankedItems:@[@{@"title": @27}, (id)@"invalid"] query:@"reload"].count == 0,
          @"Malformed candidate values do not crash ranking");
    NSMutableArray *many = [NSMutableArray new];
    for (NSUInteger index = 0; index < 1000; index++) [many addObject:@{@"title": [NSString stringWithFormat:@"Other tab %lu", (unsigned long)index]}];
    NSDictionary *last = @{@"title": @"Needle", @"identifier": @"last"};
    [many addObject:last];
    result = [OmnibarPaletteModel rankedItems:many query:@"needle"];
    Check(result.count == 1 && result.firstObject == last, @"Items past the display limit are still searched");
    Check([OmnibarPaletteModel rankedItems:many query:@"tab"].count == OmnibarPaletteMaximumResults,
          @"Large result sets are bounded to 50");
    Check([[OmnibarPaletteModel rankedItems:many query:@""] isEqual:[many subarrayWithRange:NSMakeRange(0, 50)]],
          @"Empty large lists preserve the first 50 source items");
    NSMutableArray *rankedLate = [NSMutableArray new];
    for (NSUInteger index = 0; index < 50; index++) [rankedLate addObject:@{@"title": @"Other needle result"}];
    [rankedLate addObject:last];
    result = [OmnibarPaletteModel rankedItems:rankedLate query:@"needle"];
    Check(result.count == 50 && result.firstObject == last, @"A late exact match displaces a weaker early result");
}

int main(void) {
    @autoreleasepool {
        TestModes();
        TestAddressPreview();
        TestRanking();
        printf("Passed %lu native palette-model checks; no browser, preferences, or credentials accessed.\n", (unsigned long)checks);
    }
    return 0;
}
