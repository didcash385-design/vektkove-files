#import "VKEngine.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct { NSData *code; NSString *output; NSString *error; } VKNetworkTestServer;
typedef struct { NSData *code; NSString *output; NSString *error; } VKNetworkTestClient;

static void *runNetworkTestServer(void *context) {
    @autoreleasepool {
        VKNetworkTestServer *server = context;
        NSString *error = nil;
        server->output = [VKEngine run:server->code error:&error];
        server->error = error;
    }
    return NULL;
}

static void *runNetworkTestClient(void *context) {
    @autoreleasepool {
        VKNetworkTestClient *client = context;
        for (NSUInteger attempt = 0; attempt < 100 && !client->output; attempt++) {
            NSString *error = nil;
            client->output = [VKEngine run:client->code error:&error];
            client->error = error;
            if (!client->output) usleep(10000);
        }
    }
    return NULL;
}

static unsigned short availableLoopbackPort(void) {
    int descriptor = socket(AF_INET, SOCK_STREAM, 0);
    if (descriptor < 0) return 0;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(descriptor, (struct sockaddr *)&address, sizeof(address)) != 0) { close(descriptor); return 0; }
    socklen_t length = sizeof(address);
    if (getsockname(descriptor, (struct sockaddr *)&address, &length) != 0) { close(descriptor); return 0; }
    unsigned short port = ntohs(address.sin_port);
    close(descriptor);
    return port;
}

static BOOL expect(NSString *source, NSString *expected) {
    NSString *error = nil;
    NSData *bytecode = [VKEngine compile:source error:&error];
    NSString *output = bytecode ? [VKEngine run:bytecode error:&error] : nil;
    if (![output isEqualToString:expected]) { NSLog(@"FAIL: %@, output: %@, error: %@", source, output, error); return NO; }
    return YES;
}

int main(void) {
    @autoreleasepool {
        NSString *error = nil;
        NSData *code = [VKEngine compile:@"text greeting \"Hello\"\nout $greeting\nset total 2\nadd total 3\nout $total\nhalt\nout \"unreachable\"" error:&error];
        if (!code || ![[VKEngine run:code error:&error] isEqualToString:@"Hello\n5\n"]) { NSLog(@"FAIL: %@", error); return 1; }
        if ([VKEngine compile:@"unknown" error:&error] != nil) return 2;
        if ([VKEngine compile:@"window \"Missing import\" 400 300" error:&error] || ![error containsString:@"import ui"]) return 45;
        if ([VKEngine compile:@"window \"Late import\" 400 300\nimport ui" error:&error] || ![error containsString:@"must come before"]) return 46;
        if ([VKEngine run:[@"bad" dataUsingEncoding:NSUTF8StringEncoding] error:&error] != nil) return 3;
        if ([VKEngine keywordCount] != [VKEngine baseKeywordCount]) return 4;
        if ([VKEngine dimensionForKeyword:@"ui_scene2d"] != 2 || [VKEngine dimensionForKeyword:@"op_game_rect"] != 2 ||
            [VKEngine dimensionForKeyword:@"ui_scene3d"] != 3 || [VKEngine dimensionForKeyword:@"vk_box3d"] != 3 ||
            [VKEngine dimensionForKeyword:@"ui_id"] != -1 || [VKEngine dimensionForKeyword:@"add"] != 0) return 74;
        if ([VKEngine compile:@"add_0 n" error:nil] || [VKEngine compile:@"add_99999 n" error:nil] || [VKEngine compile:@"plus n 1" error:nil] || [VKEngine compile:@"vk_add n 1" error:nil]) return 24;
        if (!expect(@"set total 1e300\nadd total 1e300\nout $total", @"2e+300\n")) return 25;
        for (NSUInteger keywordIndex = 0; keywordIndex < [VKEngine baseKeywordCount]; keywordIndex++) {
            NSString *keyword = [VKEngine keywordAtIndex:keywordIndex];
            if (![VKEngine helpForKeyword:keyword]) return 22;
            NSString *base = keyword;
            for (NSString *prefix in @[@"vk_", @"do_", @"op_"]) if ([base hasPrefix:prefix]) { base = [base substringFromIndex:prefix.length]; break; }
            NSString *header = [[VKEngine categoryForKeyword:base] isEqualToString:@"UI"] && ![base isEqualToString:@"import"] ? @"import ui\n" : @"";
            BOOL matched = NO;
            for (NSUInteger count = 0; count <= 7; count++) {
                NSString *arguments = [base isEqualToString:@"import"] ? @" ui" : [@" value" stringByPaddingToLength:count * 6 withString:@" value" startingAtIndex:0];
                NSData *original = [VKEngine compile:[header stringByAppendingFormat:@"%@%@", base, arguments] error:nil];
                NSData *alias = [VKEngine compile:[header stringByAppendingFormat:@"%@%@", keyword, arguments] error:nil];
                if (original && [original isEqualToData:alias]) { matched = YES; break; }
            }
            if (!matched) { NSLog(@"Invalid alias: %@", keyword); return 13; }
        }
        if (!expect(@"set n 12\nsubtract n 2\nmultiply n 3\ndivide n 5\nmodulo n 4\npower n 2\nout $n", @"4\n")) return 5;
        if (!expect(@"text x \"Hi\"\nconcat x \" there\"\nupper x\nout $x\nlower x\nlength x\nout $x", @"HI THERE\n8\n")) return 6;
        if (!expect(@"text message \"Hello\"\nencode message \"base64\"\nout $message\ndecode message \"base64\"\nout $message", @"SGVsbG8=\nHello\n")) return 70;
        if (!expect(@"text message \"Hello\"\nencode message \"zstd+base64\"\ndecode message \"base64+zstd\"\nout $message", @"Hello\n")) return 71;
        NSMutableArray *key3DUI = [NSMutableArray array];
        NSData *key3DCode = [VKEngine compile:@"import ui\nwindow \"3D\" 100 100\nui_scene3d 0 0 100 100\nui_box3d 0 0 0 1 1 1 \"#FF0000\"\nui_id \"cube\"\nui_keymove3d \"cube\" \"w\" 0 0 -1" error:&error];
        if (!key3DCode || ![VKEngine run:key3DCode ui:key3DUI error:&error]) { NSLog(@"3D key binding failed: %@", error); return 75; }
        NSArray *voxelDiagnostics = [VKEngine diagnose:@"import ui\nwindow \"World\" 100 100\nui_voxel3d 0 0 0 \"#FFFFFF\""];
        if (![[voxelDiagnostics componentsJoinedByString:@"\n"] containsString:@"Add ui_scene3d"]) return 76;
        NSData *codecList = [VKEngine compile:@"codec_list" error:&error];
        if (!codecList || ![[VKEngine run:codecList error:&error] containsString:@"base64"]) return 72;
        NSMutableString *largeSource = [NSMutableString stringWithString:@"text shared \"value\"\nimport ui\nwindow \"Many controls\" 100 100\n"];
        for (NSUInteger index = 0; index < 220; index++) {
            [largeSource appendFormat:@"ui_label \"Item\" 0 0 1 1\nui_id \"item%lu\"\nui_bind \"item%lu\" shared\n", (unsigned long)index, (unsigned long)index];
        }
        NSMutableArray *largeUI = [NSMutableArray array];
        NSData *largeCode = [VKEngine compile:largeSource error:&error];
        if (!largeCode || ![VKEngine run:largeCode ui:largeUI error:&error] || largeUI.count != 661) { NSLog(@"Large UI failed: %@", error); return 73; }
        if (!expect(@"set n 0\nlabel loop\nadd n 1\nset check $n\nless check 3\nif $check loop\nout $n", @"3\n")) return 7;
        if (!expect(@"vk_set n -9\ndo_absolute n\nop_sqrt n\nprint $n", @"3\n")) return 8;
        if (!expect(@"set n 12\nadd n 8\nsubtract n 5\nmultiply n 2\ndivide n 3\nout $n", @"10\n")) return 17;
        for (NSString *shortcut in @[@"set_0 n", @"subtract_1 n", @"multiply_1 n", @"divide_1 n", @"add_1 n", @"plus n 1", @"sum n 1", @"vk_add n 1"]) {
            if ([VKEngine compile:shortcut error:nil]) { NSLog(@"Unexpected shortcut accepted: %@", shortcut); return 18; }
        }
        if (!expect(@"set n 5\nequal n 5\nnot n\nunless $n done\nout \"bad\"\nlabel done\nout \"ok\"", @"ok\n")) return 9;
        NSArray *operationCases = @[
            @[@"set n 5\nmin n 2\nout $n", @"2\n"],
            @[@"set n 5\nmax n 8\nout $n", @"8\n"],
            @[@"set n 0\nsin n\nout $n", @"0\n"],
            @[@"set n 0\ncos n\nout $n", @"1\n"],
            @[@"set n 0\ntan n\nout $n", @"0\n"],
            @[@"set n 0\nasin n\nout $n", @"0\n"],
            @[@"set n 1\nacos n\nout $n", @"0\n"],
            @[@"set n 0\natan n\nout $n", @"0\n"],
            @[@"set n 1\nlog n\nout $n", @"0\n"],
            @[@"set n 100\nlog10 n\nout $n", @"2\n"],
            @[@"set n 0\nexp n\nout $n", @"1\n"],
            @[@"set n -5\nsign n\nout $n", @"-1\n"],
            @[@"set n -2.6\ntruncate n\nout $n", @"-2\n"],
            @[@"set n 3\nis_number n\nout $n", @"1\n"],
            @[@"text n \"hello\"\nis_text n\nout $n", @"1\n"],
            @[@"text n \"\"\nempty n\nout $n", @"1\n"],
            @[@"text n \"  hi  \"\ntrim n\nout $n", @"hi\n"],
            @[@"text n \"hello\"\ncontains n \"ell\"\nout $n", @"1\n"],
            @[@"text n \"hello\"\nstarts_with n \"he\"\nout $n", @"1\n"],
            @[@"text n \"hello\"\nends_with n \"lo\"\nout $n", @"1\n"],
            @[@"text n \"hello\"\nreplace n \"l\" \"x\"\nout $n", @"hexxo\n"],
            @[@"set n 5\nnot_equal n 4\nout $n", @"1\n"],
            @[@"set n 5\nless_equal n 5\nout $n", @"1\n"],
            @[@"set n 5\ngreater n 4\nout $n", @"1\n"],
            @[@"set n 5\ngreater_equal n 6\nout $n", @"0\n"],
            @[@"set n 1\nand n 0\nout $n", @"0\n"],
            @[@"set n 0\nor n 1\nout $n", @"1\n"],
            @[@"set n 5\nnegate n\nout $n", @"-5\n"],
            @[@"set n 2.6\nround n\nout $n", @"3\n"],
            @[@"set n 2.6\nfloor n\nout $n", @"2\n"],
            @[@"set n 2.1\nceil n\nout $n", @"3\n"]
        ];
        for (NSArray *test in operationCases) if (!expect(test[0], test[1])) return 14;
        if ([VKEngine run:[VKEngine compile:@"set n 1\ndivide n 0" error:&error] error:&error] != nil) return 10;
        if ([VKEngine run:[VKEngine compile:@"label loop\njump loop" error:&error] error:&error] != nil) return 11;
        if ([VKEngine run:[VKEngine compile:@"jump missing" error:&error] error:&error] != nil) return 15;
        if ([VKEngine run:[VKEngine compile:@"set n 1\nsqrt n\nadd n $missing" error:&error] error:&error] != nil) return 16;
        if ([VKEngine run:[VKEngine compile:@"text n \"hello\"\nreplace n \"\" \"x\"" error:&error] error:&error] != nil) return 20;
        NSMutableArray *ui = [NSMutableArray array];
        NSData *uiCode = [VKEngine compile:@"import ui\nwindow \"Hello\" 400 300\nui_label \"Welcome\" 10 20 100 30\nui_button \"OK\" 10 60 100 30 \"Clicked\"\nui_input \"Name\" 10 100 100 30" error:&error];
        if (![VKEngine run:uiCode ui:ui error:&error] || ui.count != 4) return 12;
        [ui removeAllObjects];
        uiCode = [VKEngine compile:@"import ui\nwindow \"Music\" 400 300\nui_shortcut \"F1\" \"Help\"\nui_note \"piano\" 60 0.5\nui_keynote \"A\" \"guitar\" 64 1\nui_sound \"audio.wav\"" error:&error];
        if (![VKEngine run:uiCode ui:ui error:&error] || ui.count != 5) { NSLog(@"Action failure: %@", error); return 28; }
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"Music\" 400 300\nui_note \"piano\" 128 1" error:&error] ui:[NSMutableArray array] error:&error]) return 29;
        if ([VKEngine run:[VKEngine compile:@"import ui\nui_keynote \"A\" \"piano\" 60 1" error:&error] ui:[NSMutableArray array] error:&error]) return 30;
        [ui removeAllObjects];
        uiCode = [VKEngine compile:@"import ui\nwindow \"Music\" 400 300\nui_keyboard \"piano\" 60\nui_label \"Spin\" 10 10 100 30\nauto_turn 2" error:&error];
        if (![VKEngine run:uiCode ui:ui error:&error] || ui.count != 4) return 31;
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"Music\" 400 300\nauto_turn 2" error:&error] ui:[NSMutableArray array] error:&error]) return 32;
        if ([VKEngine run:[VKEngine compile:@"window \"Missing import\" 400 300" error:&error] ui:[NSMutableArray array] error:&error]) return 43;
        [ui removeAllObjects];
        uiCode = [VKEngine compile:@"text username \"guest\"\nimport ui\nwindow \"Bound\" 400 300\nui_input \"Name\" 10 10 100 30\nui_id \"name_input\"\nui_label \"Guest\" 10 50 100 30\nui_id \"name_label\"\nui_bind \"name_input\" username\nui_bind \"name_label\" username" error:&error];
        if (![VKEngine run:uiCode ui:ui error:&error] || ui.count != 7 || ![ui[5][1][2] isEqualToString:@"guest"] || ![ui[6][1][2] isEqualToString:@"guest"]) return 44;
        if ([VKEngine diagnose:@"text username \"guest\"\nimport ui\nwindow \"Bound\" 400 300\nui_input \"Name\" 10 10 100 30\nui_id \"name\"\nui_bind \"name\" username"].count != 0) return 47;
        if (!expect(@"terminal_echo \"hello\"", @"hello\n")) return 53;
        if (!expect(@"terminal_run \"help\"", @"Available terminal_run keywords: date, help, pwd. Use terminal_echo to print text.\n")) return 54;
        if (!expect(@"terminal_keywords", @"terminal_run help|date|pwd; terminal_echo value; terminal_keywords\n")) return 55;
        if (!expect(@"cite \"Ada Lovelace\" \"Notes\" 1843 \"https://example.test/notes\"", @"Ada Lovelace. (1843). Notes. https://example.test/notes\n")) return 59;
        if ([VKEngine run:[VKEngine compile:@"cite \"\" \"Title\" 2024 \"https://example.test\"" error:&error] error:&error] != nil) return 60;
        NSData *dateCode = [VKEngine compile:@"terminal_run \"date\"" error:&error];
        NSString *dateOutput = dateCode ? [VKEngine run:dateCode error:&error] : nil;
        NSRegularExpression *isoDate = [NSRegularExpression regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}\\n$" options:0 error:nil];
        if (!dateOutput || [isoDate numberOfMatchesInString:dateOutput options:0 range:NSMakeRange(0, dateOutput.length)] != 1) return 57;
        if (!expect(@"terminal_run \"pwd\"", [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingString:@"\n"])) return 58;
        if ([VKEngine run:[VKEngine compile:@"terminal_run \"rm\"" error:&error] error:&error] != nil || ![error containsString:@"Unsupported terminal keyword"]) return 56;
        [ui removeAllObjects];
        uiCode = [VKEngine compile:@"import ui\nwindow \"3D\" 640 480\nui_scene3d 20 20 600 440\nui_camera3d 0 0 12\nui_light3d 4 6 8 900\nui_box3d 0 0 0 2 2 2 \"#FF5533\"\nui_id \"box\"\nui_spin3d \"box\" 3\nui_sphere3d 3 0 0 1 \"#33AAFF\"" error:&error];
        if (![VKEngine run:uiCode ui:ui error:&error] || ui.count != 8 || [VKEngine categoryForKeyword:@"ui_scene3d"] == nil) { NSLog(@"3D scene failure: %@", error); return 48; }
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"3D\" 640 480\nui_box3d 0 0 0 1 1 1 \"#FFFFFF\"" error:&error] ui:[NSMutableArray array] error:&error]) return 49;
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"3D\" 640 480\nui_scene3d 0 0 500 400\nui_sphere3d 0 0 0 -1 \"#FFFFFF\"" error:&error] ui:[NSMutableArray array] error:&error]) return 50;
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"3D\" 640 480\nui_scene3d 0 0 500 400\nui_camera3d 0 0 0" error:&error] ui:[NSMutableArray array] error:&error]) return 52;
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"3D\" 640 480\nui_scene3d 0 0 500 400\nui_box3d 0 0 0 1 1 1 \"#FFFFFF\"\nui_id \"box\"\nui_spin3d \"missing\" 2" error:&error] ui:[NSMutableArray array] error:&error]) return 51;
        [ui removeAllObjects];
        uiCode = [VKEngine compile:@"import ui\nwindow \"Arcade\" 480 300\nui_scene2d 0 0 480 300\nui_circle2d \"player\" 20 30 36 \"#32C8B2\"\nui_rect2d \"orb\" 220 80 28 28 \"#FF7059\"\nui_velocity2d \"orb\" -38 27\nui_keymove2d \"player\" \"a\" -12 0" error:&error];
        if (!uiCode) { NSLog(@"2D game compile failure: %@", error); return 61; }
        if (![VKEngine run:uiCode ui:ui error:&error] || ui.count != 6 || [VKEngine categoryForKeyword:@"ui_scene2d"] == nil) { NSLog(@"2D game scene failure: %@", error); return 61; }
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"Arcade\" 480 300\nui_rect2d \"orphan\" 0 0 20 20 \"#FFFFFF\"" error:&error] ui:[NSMutableArray array] error:&error]) return 62;
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"Arcade\" 480 300\nui_scene2d 0 0 480 300\nui_circle2d \"bad\" 0 0 0 \"#FFFFFF\"" error:&error] ui:[NSMutableArray array] error:&error]) return 63;
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"Arcade\" 480 300\nui_scene2d 0 0 480 300\nui_circle2d \"player\" 0 0 20 \"#FFFFFF\"\nui_velocity2d \"missing\" 1 1" error:&error] ui:[NSMutableArray array] error:&error]) return 64;
        [ui removeAllObjects];
        NSString *frameSource = @"set frames 0\nset hits 0\nimport ui\nwindow \"Physics\" 480 300\nui_scene2d 0 0 480 300\nui_circle2d \"ball\" 80 80 24 \"#FF5533\"\nui_physics2d \"ball\" 1 0.8\nui_gravity2d 0 120\nui_frame2d\nadd frames 1\nif $collision hit\njump done\nlabel hit\nadd hits 1\nui_force2d \"ball\" -2 0\nlabel done\nui_end_frame2d\nhalt";
        uiCode = [VKEngine compile:frameSource error:&error];
        if (!uiCode || ![VKEngine run:uiCode ui:ui error:&error]) { NSLog(@"Frame callback setup failed: %@", error); return 72; }
        NSArray *frameData = ui.lastObject;
        if ([frameData[0] unsignedCharValue] != VKUIFrameData || [frameData[1][0] unsignedCharValue] != VKUIScene2D || [ui[3][0] unsignedCharValue] != VKUIPhysics2D) return 73;
        NSMutableDictionary *frameVariables = frameData[1][2];
        frameVariables[@"collision"] = @1;
        NSArray *frameActions = [VKEngine runFrameCallback:frameData[1][1] variables:frameVariables error:&error];
        if (![frameVariables[@"frames"] isEqual:@1] || ![frameVariables[@"hits"] isEqual:@1] || frameActions.count != 1 || [frameActions[0][0] unsignedCharValue] != VKUIForce2D) return 74;
        frameVariables[@"collision"] = @0;
        frameActions = [VKEngine runFrameCallback:frameData[1][1] variables:frameVariables error:&error];
        if (![frameVariables[@"frames"] isEqual:@2] || ![frameVariables[@"hits"] isEqual:@1] || frameActions.count != 0) return 75;
        if ([VKEngine run:[VKEngine compile:@"import ui\nwindow \"Bad frame\" 100 100\nui_scene2d 0 0 100 100\nui_frame2d\nadd frames 1" error:&error] ui:[NSMutableArray array] error:&error] || ![error containsString:@"missing ui_end_frame2d"]) return 76;
        if ([VKEngine compile:@"set n 1\nserver_script" error:&error] || ![error containsString:@"first instruction"]) return 65;
        if ([VKEngine run:[VKEngine compile:@"local_script\nnet_listen \"127.0.0.1\" 41001" error:&error] error:&error] || ![error containsString:@"net_listen requires server_script"]) return 66;
        if ([VKEngine run:[VKEngine compile:@"server_script\nimport ui\nwindow \"No UI\" 100 100" error:&error] error:&error] || ![error containsString:@"Server scripts cannot create UI"]) return 67;
        unsigned short port = availableLoopbackPort();
        if (!port) return 68;
        NSString *serverSource = [NSString stringWithFormat:@"server_script\nnet_listen \"127.0.0.1\" %u\nnet_receive incoming\nnet_send $incoming\nnet_close\n", port];
        NSString *clientSource = [NSString stringWithFormat:@"local_script\nnet_connect \"127.0.0.1\" %u\nnet_send \"Vektkove loopback\"\nnet_receive reply\nout $reply\nnet_close\n", port];
        VKNetworkTestServer networkServer = { [VKEngine compile:serverSource error:&error], nil, nil };
        NSData *clientCode = [VKEngine compile:clientSource error:&error];
        if (!networkServer.code || !clientCode) return 69;
        pthread_t serverThread;
        if (pthread_create(&serverThread, NULL, runNetworkTestServer, &networkServer) != 0) return 70;
        NSString *networkOutput = nil;
        for (NSUInteger attempt = 0; attempt < 100 && !networkOutput; attempt++) {
            networkOutput = [VKEngine run:clientCode error:&error];
            if (!networkOutput) usleep(10000);
        }
        if (!networkOutput) pthread_cancel(serverThread);
        pthread_join(serverThread, NULL);
        if (![networkOutput isEqualToString:@"Vektkove loopback\n"] || !networkServer.output || networkServer.error) {
            NSLog(@"TCP loopback failure: client=%@ server=%@ error=%@", networkOutput, networkServer.output, networkServer.error);
            return 71;
        }
        unsigned short multiPort = availableLoopbackPort();
        if (!multiPort) return 77;
        NSString *multiServerSource = [NSString stringWithFormat:@"server_script\nnet_listen_multi \"127.0.0.1\" %u 2\nnet_receive_from sender message\nnet_send_to $sender $message\nnet_receive_from sender2 message2\nnet_send_to $sender2 $message2\nnet_broadcast \"ready\"\nnet_close\n", multiPort];
        NSString *firstClientSource = [NSString stringWithFormat:@"local_script\nnet_connect \"127.0.0.1\" %u\nnet_send \"player one\"\nnet_receive reply\nnet_receive status\nout $reply\nout $status\nnet_close\n", multiPort];
        NSString *secondClientSource = [NSString stringWithFormat:@"local_script\nnet_connect \"127.0.0.1\" %u\nnet_send \"player two\"\nnet_receive reply\nnet_receive status\nout $reply\nout $status\nnet_close\n", multiPort];
        VKNetworkTestServer multiServer = { [VKEngine compile:multiServerSource error:&error], nil, nil };
        VKNetworkTestClient firstClient = { [VKEngine compile:firstClientSource error:&error], nil, nil };
        VKNetworkTestClient secondClient = { [VKEngine compile:secondClientSource error:&error], nil, nil };
        if (!multiServer.code || !firstClient.code || !secondClient.code) return 78;
        pthread_t multiServerThread, firstClientThread, secondClientThread;
        if (pthread_create(&multiServerThread, NULL, runNetworkTestServer, &multiServer) != 0) return 79;
        if (pthread_create(&firstClientThread, NULL, runNetworkTestClient, &firstClient) != 0 || pthread_create(&secondClientThread, NULL, runNetworkTestClient, &secondClient) != 0) {
            pthread_cancel(multiServerThread); pthread_join(multiServerThread, NULL); return 80;
        }
        pthread_join(firstClientThread, NULL);
        pthread_join(secondClientThread, NULL);
        if (!firstClient.output || !secondClient.output) pthread_cancel(multiServerThread);
        pthread_join(multiServerThread, NULL);
        if (![firstClient.output isEqualToString:@"player one\nready\n"] || ![secondClient.output isEqualToString:@"player two\nready\n"] || !multiServer.output || multiServer.error) {
            NSLog(@"Multi-client loopback failure: one=%@ two=%@ server=%@ error=%@", firstClient.output, secondClient.output, multiServer.output, multiServer.error);
            return 81;
        }
        unsigned short nativeMultiPort = availableLoopbackPort();
        if (!nativeMultiPort) return 82;
        NSString *nativeMultiServerSource = [NSString stringWithFormat:@"server_script\nnet_listen_multi \"127.0.0.1\" %u 2\nnet_receive_from sender message\nnet_send_to $sender $message\nnet_receive_from sender2 message2\nnet_send_to $sender2 $message2\nnet_broadcast \"ready\"\nnet_close\n", nativeMultiPort];
        NSString *nativeFirstClientSource = [NSString stringWithFormat:@"local_script\nnet_connect \"127.0.0.1\" %u\nnet_send \"native one\"\nnet_receive reply\nnet_receive status\nout $reply\nout $status\nnet_close\n", nativeMultiPort];
        NSString *nativeSecondClientSource = [NSString stringWithFormat:@"local_script\nnet_connect \"127.0.0.1\" %u\nnet_send \"native two\"\nnet_receive reply\nnet_receive status\nout $reply\nout $status\nnet_close\n", nativeMultiPort];
        VKNetworkTestServer nativeMultiServer = { [VKEngine compile:nativeMultiServerSource error:&error], nil, nil };
        VKNetworkTestClient nativeFirstClient = { [VKEngine compile:nativeFirstClientSource error:&error], nil, nil };
        VKNetworkTestClient nativeSecondClient = { [VKEngine compile:nativeSecondClientSource error:&error], nil, nil };
        if (!nativeMultiServer.code || !nativeFirstClient.code || !nativeSecondClient.code) return 83;
        pthread_t nativeServerThread, nativeFirstThread, nativeSecondThread;
        if (pthread_create(&nativeServerThread, NULL, runNetworkTestServer, &nativeMultiServer) != 0) return 84;
        if (pthread_create(&nativeFirstThread, NULL, runNetworkTestClient, &nativeFirstClient) != 0) { pthread_cancel(nativeServerThread); pthread_join(nativeServerThread, NULL); return 85; }
        if (pthread_create(&nativeSecondThread, NULL, runNetworkTestClient, &nativeSecondClient) != 0) {
            pthread_cancel(nativeFirstThread); pthread_cancel(nativeServerThread); pthread_join(nativeFirstThread, NULL); pthread_join(nativeServerThread, NULL); return 86;
        }
        pthread_join(nativeFirstThread, NULL);
        pthread_join(nativeSecondThread, NULL);
        if (!nativeFirstClient.output || !nativeSecondClient.output) pthread_cancel(nativeServerThread);
        pthread_join(nativeServerThread, NULL);
        if (![nativeFirstClient.output isEqualToString:@"native one\nready\n"] || ![nativeSecondClient.output isEqualToString:@"native two\nready\n"] || !nativeMultiServer.output || nativeMultiServer.error) {
            NSLog(@"Native multi-client failure: one=%@ two=%@ server=%@ error=%@", nativeFirstClient.output, nativeSecondClient.output, nativeMultiServer.output, nativeMultiServer.error);
            return 87;
        }
        {
            NSString *bad = @"bogus 1\nadd missing 1\nout $nothing\njump nowhere\nlabel a\nlabel a\nhalt\nout \"dead\"\ntext unused \"x\"\nui_label \"x\" 1 1 1 1\nset 5";
            NSString *joined = [[VKEngine diagnose:bad] componentsJoinedByString:@"\n"];
            NSArray *expected = @[@"Error line 1: Unknown command", @"Error line 2: Variable $missing", @"Error line 3: Variable $nothing", @"Error line 4: Unknown label nowhere", @"Error line 6: Label a is already defined", @"Warning line 8: Unreachable", @"Warning line 9: Variable $unused", @"Error line 10: Create a window", @"Error line 11: set needs 2"];
            for (NSString *piece in expected) if (![joined containsString:piece]) { NSLog(@"Missing diagnostic '%@' in:\n%@", piece, joined); return 40; }
            if ([VKEngine compile:bad error:&error] || ![error containsString:@"Line 1"] || ![error containsString:@"Line 11"]) return 41;
            if ([VKEngine diagnose:@"text n 1\nout $n"].count != 0) return 42;
        }
        NSLog(@"Bytecode smoke tests passed");
    }
    return 0;
}