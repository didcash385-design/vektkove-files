#import "VKEngine.h"
#include "portable/vkcodec.h"
#include "portable/vkai.h"

static int fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && (!strcmp(argv[1], "--version") || !strcmp(argv[1], "-V"))) {
            puts("Vektkove 1.4.4");
            return 0;
        }
        if (argc == 2 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h"))) {
            puts("Vektkove 1.4.4\nUsage: vk run file.vk|file.vkb\n       vk compile file.vk out.vkb\n       vk check file.vk\n       vk ast file.vk\n       vk score file.vk\n       vk encode FORMAT [input|-] [output|-]\n       vk decode FORMAT [input|-] [output|-]\n       vk formats\n       vk keywords\n       vk --version\n\nUI instructions are validated but require the macOS app to display.");
            return 0;
        }
        if (argc == 2 && !strcmp(argv[1], "formats")) { puts(vkc_format_list()); return 0; }
        if (argc >= 3 && argc <= 5 && (!strcmp(argv[1], "encode") || !strcmp(argv[1], "decode")))
            return vkc_cli(!strcmp(argv[1], "encode"), argv[2], argc > 3 ? argv[3] : NULL, argc > 4 ? argv[4] : NULL);
        if (argc == 2 && !strcmp(argv[1], "keywords")) {
            for (NSUInteger index = 0; index < [VKEngine keywordCount]; index++) printf("%s\n", [VKEngine keywordAtIndex:index].UTF8String);
            return 0;
        }
        if (argc < 3 || argc > 4) return fail(@"Usage: vk run file.vk|file.vkb | vk compile file.vk file.vkb | vk check file.vk | vk keywords");
        NSString *action = [NSString stringWithUTF8String:argv[1]];
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        if (![action isEqualToString:@"run"] && ![action isEqualToString:@"compile"] && ![action isEqualToString:@"check"] && ![action isEqualToString:@"ast"] && ![action isEqualToString:@"score"]) return fail(@"Unknown action. Use run, compile, check, ast, score, or keywords.");
        if (([action isEqualToString:@"compile"] && argc != 4) || (![action isEqualToString:@"compile"] && argc != 3)) return fail(@"Incorrect number of arguments.");
        NSError *fileError = nil;
        NSData *input = [NSData dataWithContentsOfFile:path options:0 error:&fileError];
        if (!input) return fail(fileError.localizedDescription);
        NSString *error = nil;
        NSData *bytecode = nil;
        if ([path.pathExtension.lowercaseString isEqualToString:@"vkb"] && [action isEqualToString:@"run"]) bytecode = input;
        else {
            NSString *source = [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding];
            if (!source) return fail(@"Source must be UTF-8 text.");
            bytecode = [VKEngine compile:source error:&error];
        }
        if ([action isEqualToString:@"score"]) { puts(bytecode ? "1" : "0"); return 0; }
        if (!bytecode) return fail(error);
        if ([action isEqualToString:@"check"]) { puts("Syntax OK"); return 0; }
        if ([action isEqualToString:@"ast"]) {
            NSString *source = [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding];
            char message[512] = {0};
            char *tree = vk_ai_code_tree(bytecode.bytes, bytecode.length, source.UTF8String, message, sizeof(message));
            if (!tree) return fail([NSString stringWithUTF8String:message]);
            puts(tree);
            free(tree);
            return 0;
        }
        if ([action isEqualToString:@"compile"]) {
            if (![bytecode writeToFile:[NSString stringWithUTF8String:argv[3]] options:NSDataWritingAtomic error:&fileError]) return fail(fileError.localizedDescription);
            return 0;
        }
        NSMutableArray *ui = [NSMutableArray array];
        NSString *output = [VKEngine run:bytecode ui:ui error:&error];
        if (!output) return fail(error);
        printf("%s", output.UTF8String);
        if (ui.count) fprintf(stderr, "UI instructions require the Vektkove app.\n");
        return 0;
    }
}