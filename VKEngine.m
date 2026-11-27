#import "VKEngine.h"
#include "portable/vkcodec.h"
#include "portable/vkai.h"
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

static const NSUInteger VKNetworkMaxMessage = 16 * 1024;

@interface VKAIState : NSObject {
@public
    VKAIContext context;
}
@end

@implementation VKAIState
- (instancetype)init {
    self = [super init];
    if (self) vk_ai_init(&context);
    return self;
}
- (void)dealloc { vk_ai_destroy(&context); }
@end

@interface VKTCPChannel : NSObject
@property int descriptor;
- (instancetype)initWithDescriptor:(int)descriptor;
- (void)closeChannel;
@end

@implementation VKTCPChannel
- (instancetype)initWithDescriptor:(int)descriptor {
    self = [super init];
    if (self) _descriptor = descriptor;
    return self;
}
- (void)closeChannel {
    if (self.descriptor >= 0) { shutdown(self.descriptor, SHUT_RDWR); close(self.descriptor); self.descriptor = -1; }
}
- (void)dealloc { [self closeChannel]; }
@end

static BOOL VKSocketSendAll(int descriptor, const void *buffer, size_t length) {
    const unsigned char *bytes = buffer;
    while (length) {
        ssize_t sent = send(descriptor, bytes, length, 0);
        if (sent <= 0) return NO;
        bytes += sent;
        length -= (size_t)sent;
    }
    return YES;
}

static BOOL VKSocketReceiveAll(int descriptor, void *buffer, size_t length) {
    unsigned char *bytes = buffer;
    while (length) {
        ssize_t received = recv(descriptor, bytes, length, 0);
        if (received <= 0) return NO;
        bytes += received;
        length -= (size_t)received;
    }
    return YES;
}

static void VKConfigureSocket(int descriptor) {
#ifdef SO_NOSIGPIPE
    int noSignal = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
#endif
    struct timeval timeout = {60, 0};
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static int VKOpenTCPConnection(NSString *host, NSUInteger port, BOOL listenForPeer) {
    char portString[8]; snprintf(portString, sizeof(portString), "%lu", (unsigned long)port);
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = listenForPeer ? AI_PASSIVE : 0;
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host.length ? host.UTF8String : NULL, portString, &hints, &addresses) != 0) return -1;
    int descriptor = -1;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        int candidate = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (candidate < 0) continue;
        VKConfigureSocket(candidate);
        if (listenForPeer) {
            int reuse = 1;
            setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
            if (bind(candidate, address->ai_addr, (socklen_t)address->ai_addrlen) == 0 && listen(candidate, 1) == 0) {
                descriptor = accept(candidate, NULL, NULL);
                close(candidate);
                if (descriptor >= 0) VKConfigureSocket(descriptor);
                break;
            }
        } else if (connect(candidate, address->ai_addr, (socklen_t)address->ai_addrlen) == 0) {
            descriptor = candidate;
            break;
        }
        close(candidate);
    }
    freeaddrinfo(addresses);
    return descriptor;
}

static int VKOpenTCPListener(NSString *host, NSUInteger port) {
    char portString[8]; snprintf(portString, sizeof(portString), "%lu", (unsigned long)port);
    struct addrinfo hints = {0};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host.UTF8String, portString, &hints, &addresses) != 0) return -1;
    int descriptor = -1;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        int candidate = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (candidate < 0) continue;
        VKConfigureSocket(candidate);
        int reuse = 1;
        setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
        if (bind(candidate, address->ai_addr, (socklen_t)address->ai_addrlen) == 0 && listen(candidate, 16) == 0) { descriptor = candidate; break; }
        close(candidate);
    }
    freeaddrinfo(addresses);
    return descriptor;
}

static int VKAcceptTCPClient(int listener) {
    int descriptor = accept(listener, NULL, NULL);
    if (descriptor >= 0) VKConfigureSocket(descriptor);
    return descriptor;
}

static BOOL VKSendNetworkMessage(VKTCPChannel *channel, NSString *message) {
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length > VKNetworkMaxMessage) return NO;
    uint32_t length = CFSwapInt32HostToBig((uint32_t)data.length);
    return VKSocketSendAll(channel.descriptor, &length, sizeof(length)) && VKSocketSendAll(channel.descriptor, data.bytes, data.length);
}

static NSString *VKReceiveNetworkMessage(VKTCPChannel *channel) {
    uint32_t encodedLength = 0;
    if (!VKSocketReceiveAll(channel.descriptor, &encodedLength, sizeof(encodedLength))) return nil;
    uint32_t length = CFSwapInt32BigToHost(encodedLength);
    if (length > VKNetworkMaxMessage) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    if (length && !VKSocketReceiveAll(channel.descriptor, data.mutableBytes, length)) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSDictionary *commandTable(void) {
    static NSDictionary *commands;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *definitions = @[
            @[@(VKText), @2, @"text string_text declare_text"],
            @[@(VKSet), @2, @"set assign store"],
            @[@(VKAdd), @2, @"add"],
            @[@(VKSubtract), @2, @"subtract sub minus"],
            @[@(VKMultiply), @2, @"multiply mul times"],
            @[@(VKDivide), @2, @"divide div quotient"],
            @[@(VKModulo), @2, @"modulo mod remainder"],
            @[@(VKPower), @2, @"power pow exponent"],
            @[@(VKConcat), @2, @"concat append join"],
            @[@(VKUpper), @1, @"upper uppercase capitalize"],
            @[@(VKLower), @1, @"lower lowercase decapitalize"],
            @[@(VKLength), @1, @"length len size"],
            @[@(VKEqual), @2, @"equal equals eq"],
            @[@(VKNotEqual), @2, @"not_equal differs neq"],
            @[@(VKLess), @2, @"less below lt"],
            @[@(VKLessEqual), @2, @"less_equal at_most lte"],
            @[@(VKGreater), @2, @"greater above gt"],
            @[@(VKGreaterEqual), @2, @"greater_equal at_least gte"],
            @[@(VKNot), @1, @"not invert negate_boolean"],
            @[@(VKAnd), @2, @"and both logical_and"],
            @[@(VKOr), @2, @"or either logical_or"],
            @[@(VKNegate), @1, @"negate negative negate_number"],
            @[@(VKAbs), @1, @"abs absolute magnitude"],
            @[@(VKRound), @1, @"round nearest round_number"],
            @[@(VKFloor), @1, @"floor round_down downward"],
            @[@(VKCeil), @1, @"ceil round_up ceiling"],
            @[@(VKSqrt), @1, @"sqrt square_root root"],
            @[@(VKOut), @1, @"out print output"],
            @[@(VKHalt), @0, @"halt stop end"],
            @[@(VKLabel), @1, @"label mark anchor"],
            @[@(VKJump), @1, @"jump goto branch"],
            @[@(VKIf), @2, @"if when branch_if"],
            @[@(VKUnless), @2, @"unless when_not branch_unless"],
            @[@(VKWindow), @3, @"window ui_window make_window"],
            @[@(VKUILabel), @5, @"ui_label ui_text make_label"],
            @[@(VKUIButton), @6, @"ui_button ui_action make_button"],
            @[@(VKUIInput), @5, @"ui_input ui_field make_input"],
            @[@(VKMin), @2, @"min minimum smaller"],
            @[@(VKMax), @2, @"max maximum larger"],
            @[@(VKSin), @1, @"sin sine sine_radians"],
            @[@(VKCos), @1, @"cos cosine cosine_radians"],
            @[@(VKTan), @1, @"tan tangent tangent_radians"],
            @[@(VKAsin), @1, @"asin arcsine inverse_sine"],
            @[@(VKAcos), @1, @"acos arccosine inverse_cosine"],
            @[@(VKAtan), @1, @"atan arctangent inverse_tangent"],
            @[@(VKLog), @1, @"log natural_log ln"],
            @[@(VKLog10), @1, @"log10 common_log decimal_log"],
            @[@(VKExp), @1, @"exp exponential e_power"],
            @[@(VKSign), @1, @"sign signum number_sign"],
            @[@(VKTruncate), @1, @"truncate trunc integer_part"],
            @[@(VKIsNumber), @1, @"is_number numeric is_numeric"],
            @[@(VKIsText), @1, @"is_text textual is_string"],
            @[@(VKEmpty), @1, @"empty is_empty text_empty"],
            @[@(VKTrim), @1, @"trim strip trim_whitespace"],
            @[@(VKContains), @2, @"contains includes text_contains"],
            @[@(VKStartsWith), @2, @"starts_with begins_with has_prefix"],
            @[@(VKEndsWith), @2, @"ends_with finishes_with has_suffix"],
            @[@(VKReplace), @3, @"replace replace_all text_replace"],
            @[@(VKUIColor), @1, @"ui_color ui_colour set_ui_color"],
            @[@(VKUIShortcut), @2, @"ui_shortcut shortcut ui_key"],
            @[@(VKUINote), @3, @"ui_note play_note note"],
            @[@(VKUIKeynote), @4, @"ui_keynote key_note instrument_key"],
            @[@(VKUISound), @1, @"ui_sound play_sound sound_file"],
            @[@(VKUIKeyboard), @2, @"ui_keyboard instrument_keyboard keyboard"],
            @[@(VKUIAutoTurn), @1, @"ui_auto_turn auto_turn ui_rotate"],
            @[@(VKImport), @1, @"import"],
            @[@(VKUIID), @1, @"ui_id"],
            @[@(VKUIBind), @2, @"ui_bind"],
            @[@(VKUIScene3D), @4, @"ui_scene3d scene3d make_scene3d"],
            @[@(VKUICamera3D), @3, @"ui_camera3d camera3d scene_camera"],
            @[@(VKUILight3D), @4, @"ui_light3d light3d scene_light"],
            @[@(VKUIBox3D), @7, @"ui_box3d box3d cube3d ui_cube"],
            @[@(VKUISphere3D), @5, @"ui_sphere3d sphere3d ui_sphere"],
            @[@(VKUICylinder3D), @6, @"ui_cylinder3d cylinder3d ui_cylinder"],
            @[@(VKUICone3D), @7, @"ui_cone3d cone3d ui_cone"],
            @[@(VKUITorus3D), @6, @"ui_torus3d torus3d ui_torus"],
            @[@(VKUIPlane3D), @6, @"ui_plane3d plane3d ui_plane"],
            @[@(VKUISpin3D), @2, @"ui_spin3d spin3d spin_object"],
            @[@(VKTerminalRun), @1, @"terminal_run run_terminal terminal_command"],
            @[@(VKTerminalEcho), @1, @"terminal_echo echo_terminal"],
            @[@(VKTerminalKeywords), @0, @"terminal_keywords terminal_help"],
            @[@(VKCite), @4, @"cite citation reference source_cite"],
            @[@(VKUIScene2D), @4, @"ui_scene2d scene2d game2d"],
            @[@(VKUIRect2D), @6, @"ui_rect2d rect2d game_rect"],
            @[@(VKUICircle2D), @5, @"ui_circle2d circle2d game_circle"],
            @[@(VKUIVelocity2D), @3, @"ui_velocity2d velocity2d game_velocity"],
            @[@(VKUIKeyMove2D), @4, @"ui_keymove2d keymove2d game_keymove"],
            @[@(VKServerScript), @0, @"server_script serverscript"],
            @[@(VKLocalScript), @0, @"local_script localscript"],
            @[@(VKNetListen), @2, @"net_listen network_listen"],
            @[@(VKNetConnect), @2, @"net_connect connect_ip network_connect"],
            @[@(VKNetSend), @1, @"net_send network_send"],
            @[@(VKNetReceive), @1, @"net_receive network_receive"],
            @[@(VKNetClose), @0, @"net_close network_close"],
            @[@(VKNetListenMulti), @3, @"net_listen_multi network_listen_multi"],
            @[@(VKNetSendTo), @2, @"net_send_to network_send_to"],
            @[@(VKNetReceiveFrom), @2, @"net_receive_from network_receive_from"],
            @[@(VKNetBroadcast), @1, @"net_broadcast network_broadcast"],
            @[@(VKUIPhysics2D), @3, @"ui_physics2d physics2d game_physics"],
            @[@(VKUIGravity2D), @2, @"ui_gravity2d gravity2d game_gravity"],
            @[@(VKUIFrame2D), @0, @"ui_frame2d frame2d game_update"],
            @[@(VKUIEndFrame2D), @0, @"ui_end_frame2d end_frame2d game_end_update"],
            @[@(VKUIMove2D), @3, @"ui_move2d move2d game_move"],
            @[@(VKUIForce2D), @3, @"ui_force2d force2d game_force"],
            @[@(VKUISetVelocity2D), @3, @"ui_set_velocity2d set_velocity2d game_set_velocity"],
            @[@(VKUIPhysics3D), @3, @"ui_physics3d physics3d game_physics3d"],
            @[@(VKUIGravity3D), @3, @"ui_gravity3d gravity3d game_gravity3d"],
            @[@(VKUIFrame3D), @0, @"ui_frame3d frame3d game_update3d"],
            @[@(VKUIEndFrame3D), @0, @"ui_end_frame3d end_frame3d game_end_update3d"],
            @[@(VKUIMove3D), @4, @"ui_move3d move3d game_move3d"],
            @[@(VKUIForce3D), @4, @"ui_force3d force3d game_force3d"],
            @[@(VKUISetVelocity3D), @4, @"ui_set_velocity3d set_velocity3d game_set_velocity3d"],
            @[@(VKUIVelocity3D), @4, @"ui_velocity3d velocity3d game_velocity3d"],
            @[@(VKUIMesh3D), @6, @"ui_mesh3d"],
            @[@(VKEncode), @2, @"encode encode_text text_encode"],
            @[@(VKDecode), @2, @"decode decode_text text_decode"],
            @[@(VKCodecList), @0, @"codec_list list_codecs codecs"],
            @[@(VKAIConfigure), @2, @"ai_config ai_configure"],
            @[@(VKTrain), @2, @"train ai_train"],
            @[@(VKAIClear), @0, @"ai_clear clear_knowledge"],
            @[@(VKAIAsk), @2, @"ai_ask ask_ai"],
            @[@(VKUIKeyMove3D), @5, @"ui_keymove3d keymove3d game_keymove3d"],
            @[@(VKUIVoxel3D), @4, @"ui_voxel3d"],
            @[@(VKUIVoxelControls3D), @2, @"ui_voxel_controls3d"],
            @[@(VKUIRemove3D), @1, @"ui_remove3d"]
        ];
        NSMutableDictionary *table = [NSMutableDictionary dictionary];
        for (NSArray *definition in definitions) {
            for (NSString *alias in [definition[2] componentsSeparatedByString:@" "]) {
                NSArray *prefixes = ([definition[0] unsignedCharValue] == VKAdd || [definition[0] unsignedCharValue] == VKImport) ? @[@""] : @[@"", @"vk_", @"do_", @"op_"];
                for (NSString *prefix in prefixes) table[[prefix stringByAppendingString:alias]] = @[definition[0], definition[1]];
            }
        }
        commands = [table copy];
    });
    return commands;
}

static NSArray<NSString *> *baseKeywords(void) {
    static NSArray *keywords;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ keywords = [[commandTable() allKeys] sortedArrayUsingSelector:@selector(compare:)]; });
    return keywords;
}

static BOOL opcodeIs2DGameInstruction(VKOpcode opcode) {
    return opcode == VKUIScene2D || opcode == VKUIRect2D || opcode == VKUICircle2D ||
    opcode == VKUIVelocity2D || opcode == VKUIKeyMove2D || opcode == VKUIPhysics2D ||
    opcode == VKUIGravity2D || opcode == VKUIFrame2D || opcode == VKUIEndFrame2D ||
    opcode == VKUIMove2D || opcode == VKUIForce2D || opcode == VKUISetVelocity2D;
}

static BOOL opcodeIs3DGameInstruction(VKOpcode opcode) {
    return opcode == VKUIPhysics3D || opcode == VKUIGravity3D || opcode == VKUIFrame3D || opcode == VKUIEndFrame3D ||
        opcode == VKUIMove3D || opcode == VKUIForce3D || opcode == VKUISetVelocity3D || opcode == VKUIVelocity3D || opcode == VKUIMesh3D || opcode == VKUIKeyMove3D ||
        opcode == VKUIVoxel3D || opcode == VKUIVoxelControls3D || opcode == VKUIRemove3D;
}

static BOOL opcodeIsUIInstruction(VKOpcode opcode) {
    return (opcode >= VKWindow && opcode <= VKUIInput) ||
        (opcode >= VKUIColor && opcode <= VKUIAutoTurn) || opcode == VKUIID || opcode == VKUIBind ||
        (opcode >= VKUIScene3D && opcode <= VKUISpin3D) || opcodeIs2DGameInstruction(opcode) || opcodeIs3DGameInstruction(opcode);
}

static BOOL opcodeIsFrameCallbackInstruction(VKOpcode opcode) {
    switch (opcode) {
        case VKText: case VKSet: case VKAdd: case VKSubtract: case VKMultiply: case VKDivide: case VKModulo: case VKPower:
        case VKMin: case VKMax: case VKEqual: case VKNotEqual: case VKLess: case VKLessEqual: case VKGreater: case VKGreaterEqual:
        case VKNot: case VKAnd: case VKOr: case VKNegate: case VKAbs: case VKRound: case VKFloor: case VKCeil: case VKSqrt:
        case VKSin: case VKCos: case VKTan: case VKAsin: case VKAcos: case VKAtan: case VKLog: case VKLog10: case VKExp:
        case VKSign: case VKTruncate: case VKLabel: case VKJump: case VKIf: case VKUnless:
        case VKUIMove2D: case VKUIForce2D: case VKUISetVelocity2D:
        case VKUIMove3D: case VKUIForce3D: case VKUISetVelocity3D: case VKUIRemove3D: return YES;
        default: return NO;
    }
}

static NSArray *commandForKeyword(NSString *keyword) {
    return commandTable()[keyword];
}

static NSArray<NSString *> *tokenize(NSString *line, NSString **error) {
    NSMutableArray *tokens = [NSMutableArray array];
    NSUInteger position = 0;
    NSCharacterSet *spaces = [NSCharacterSet whitespaceCharacterSet];
    while (position < line.length) {
        unichar character = [line characterAtIndex:position];
        if ([spaces characterIsMember:character]) { position++; continue; }
        if (character == '#') break;
        NSUInteger start = position;
        if (character == '"') {
            position++;
            BOOL escaped = NO;
            BOOL closed = NO;
            while (position < line.length) {
                character = [line characterAtIndex:position++];
                if (!escaped && character == '"') { closed = YES; break; }
                if (!escaped && character == '\\') escaped = YES;
                else escaped = NO;
            }
            if (!closed) { *error = @"Unterminated string."; return nil; }
        } else {
            while (position < line.length && ![spaces characterIsMember:[line characterAtIndex:position]] && [line characterAtIndex:position] != '#') position++;
        }
        [tokens addObject:[line substringWithRange:NSMakeRange(start, position - start)]];
    }
    return tokens;
}

static void appendString(NSMutableData *data, NSString *string) {
    NSData *encoded = [string dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t length = CFSwapInt32HostToBig((uint32_t)encoded.length);
    [data appendBytes:&length length:4];
    [data appendData:encoded];
}

static id valueOf(NSString *token, NSDictionary *variables, NSString **error) {
    if ([token hasPrefix:@"$"]) {
        id value = variables[[token substringFromIndex:1]];
        if (!value) *error = [NSString stringWithFormat:@"Unknown variable %@.", token];
        return value;
    }
    if ([token hasPrefix:@"\""]) {
        NSData *json = [[NSString stringWithFormat:@"[%@]", token] dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *array = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if (!array || ![array.firstObject isKindOfClass:[NSString class]]) *error = @"Invalid quoted string.";
        return array.firstObject;
    }
    NSScanner *scanner = [NSScanner scannerWithString:token];
    double number;
    if ([scanner scanDouble:&number] && scanner.isAtEnd && isfinite(number)) return @(number);
    return token;
}

@implementation VKEngine
+ (NSArray<NSString *> *)keywords {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:self.keywordCount];
    for (NSUInteger index = 0; index < self.keywordCount; index++) [result addObject:[self keywordAtIndex:index]];
    return result;
}

+ (NSUInteger)baseKeywordCount { return baseKeywords().count; }
+ (NSUInteger)keywordCount { return self.baseKeywordCount; }
+ (NSString *)keywordAtIndex:(NSUInteger)index {
    return index < self.baseKeywordCount ? baseKeywords()[index] : nil;
}

+ (NSString *)helpForKeyword:(NSString *)keyword {
    NSArray *command = commandForKeyword(keyword.lowercaseString);
    if (!command) return nil;
    static NSDictionary *descriptions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        descriptions = @{
            @(VKText): @"name value - Store the value as text.", @(VKSet): @"name value - Store a value in a variable.",
            @(VKAdd): @"name value - Add a number to the variable.", @(VKSubtract): @"name value - Subtract a number from the variable.",
            @(VKMultiply): @"name value - Multiply the variable by a number.", @(VKDivide): @"name value - Divide the variable by a nonzero number.",
            @(VKModulo): @"name value - Store the remainder after division by a nonzero number.", @(VKPower): @"name value - Raise the variable to a power.",
            @(VKConcat): @"name value - Append the value as text.", @(VKUpper): @"name - Convert the value to uppercase text.",
            @(VKLower): @"name - Convert the value to lowercase text.", @(VKLength): @"name - Replace the value with its UTF-16 text length.",
            @(VKEqual): @"name value - Store 1 when the values are equal, otherwise 0.", @(VKNotEqual): @"name value - Store 1 when the values differ, otherwise 0.",
            @(VKLess): @"name value - Store 1 if the number is smaller, otherwise 0.", @(VKLessEqual): @"name value - Store 1 if the number is no greater, otherwise 0.",
            @(VKGreater): @"name value - Store 1 if the number is larger, otherwise 0.", @(VKGreaterEqual): @"name value - Store 1 if the number is no smaller, otherwise 0.",
            @(VKNot): @"name - Invert the numeric boolean.", @(VKAnd): @"name value - Store the logical AND of two numbers.",
            @(VKOr): @"name value - Store the logical OR of two numbers.", @(VKNegate): @"name - Negate the number.",
            @(VKAbs): @"name - Store the absolute value.", @(VKRound): @"name - Round to the nearest integer, halfway away from zero.",
            @(VKFloor): @"name - Round down.", @(VKCeil): @"name - Round up.", @(VKSqrt): @"name - Calculate the square root.",
            @(VKOut): @"value - Write the value to output.", @(VKHalt): @"- Stop execution.",
            @(VKLabel): @"label - Mark a jump destination.", @(VKJump): @"label - Jump to a label.",
            @(VKIf): @"value label - Jump when the value is true.", @(VKUnless): @"value label - Jump when the value is false.",
            @(VKWindow): @"title width height - Create the program window.", @(VKUILabel): @"text x y width height - Add a label to the window.",
            @(VKUIButton): @"text x y width height message - Add a button that displays a message.", @(VKUIInput): @"placeholder x y width height - Add a text input.",
            @(VKMin): @"name value - Store the smaller number.", @(VKMax): @"name value - Store the larger number.",
            @(VKSin): @"name - Store the sine in radians.", @(VKCos): @"name - Store the cosine in radians.", @(VKTan): @"name - Store the tangent in radians.",
            @(VKAsin): @"name - Store the inverse sine in radians.", @(VKAcos): @"name - Store the inverse cosine in radians.", @(VKAtan): @"name - Store the inverse tangent in radians.",
            @(VKLog): @"name - Store the natural logarithm.", @(VKLog10): @"name - Store the base-10 logarithm.", @(VKExp): @"name - Store e raised to the number.",
            @(VKSign): @"name - Store -1, 0, or 1 according to the number's sign.", @(VKTruncate): @"name - Remove the fractional part toward zero.",
            @(VKIsNumber): @"name - Store 1 if the value is numeric, otherwise 0.", @(VKIsText): @"name - Store 1 if the value is text, otherwise 0.",
            @(VKEmpty): @"name - Store 1 if the text representation is empty, otherwise 0.", @(VKTrim): @"name - Remove leading and trailing whitespace.",
            @(VKContains): @"name value - Store 1 if the text contains the value, otherwise 0.", @(VKStartsWith): @"name value - Store 1 if the text starts with the value, otherwise 0.",
            @(VKEndsWith): @"name value - Store 1 if the text ends with the value, otherwise 0.", @(VKReplace): @"name search replacement - Replace all non-empty search text with the replacement.",
            @(VKUIColor): @"\"#RRGGBB\" - Set the color of subsequent UI elements.",
            @(VKUIShortcut): @"key message - Show a message when the key is pressed in the program window.",
            @(VKUINote): @"instrument note seconds - Play a piano or guitar MIDI note when the window opens.",
            @(VKUIKeynote): @"key instrument note seconds - Play a MIDI note when the key is pressed in the program window.",
            @(VKUISound): @"path - Play a local audio file when the window opens.",
            @(VKUIKeyboard): @"instrument base_note - Bind piano or guitar notes to a focused window keyboard.",
            @(VKUIAutoTurn): @"seconds - Rotate the preceding UI control continuously.",
            @(VKImport): @"ui - Enable native UI instructions for this program.",
            @(VKUIID): @"id - Name the preceding label, input, button, or 3D object.",
            @(VKUIBind): @"id variable - Bind an input or label to a text variable.",
            @(VKUIScene3D): @"x y width height - Add an interactive 3D viewport.",
            @(VKUICamera3D): @"x y z - Position the 3D camera looking at the origin.",
            @(VKUILight3D): @"x y z intensity - Add a white point light.",
            @(VKUIBox3D): @"x y z width height depth color - Add a colored box.",
            @(VKUISphere3D): @"x y z radius color - Add a colored sphere.",
            @(VKUICylinder3D): @"x y z radius height color - Add a colored cylinder.",
            @(VKUICone3D): @"x y z top_radius bottom_radius height color - Add a colored cone.",
            @(VKUITorus3D): @"x y z ring_radius pipe_radius color - Add a colored torus.",
            @(VKUIPlane3D): @"x y z width height color - Add a colored plane.",
            @(VKUISpin3D): @"id seconds - Rotate a named 3D object continuously.",
            @(VKTerminalRun): @"keyword - Run a built-in utility: help, date, or pwd. Does not launch a shell.",
            @(VKTerminalEcho): @"value - Write text to program output without invoking a shell.",
            @(VKTerminalKeywords): @"- List the available terminal utility keywords.",
            @(VKCite): @"author title year url - Format and print an author-date citation.",
            @(VKUIScene2D): @"x y width height - Add a bounded interactive 2D game scene.",
            @(VKUIRect2D): @"id x y width height color - Add a moving rectangle to the 2D scene.",
            @(VKUICircle2D): @"id x y diameter color - Add a moving circle to the 2D scene.",
            @(VKUIVelocity2D): @"id dx dy - Set an object's velocity in scene units per second; it bounces at scene edges.",
            @(VKUIKeyMove2D): @"id key dx dy - Move an object by dx and dy when the key is pressed.",
            @(VKServerScript): @"- Mark this file as the server entry point. Must be the first instruction.",
            @(VKLocalScript): @"- Mark this file as the local/client entry point. Must be the first instruction.",
            @(VKNetListen): @"address port - Bind the specified address and accept one TCP client. Server scripts only.",
            @(VKNetConnect): @"address port - Connect to the explicitly supplied TCP server. Local scripts only.",
            @(VKNetSend): @"value - Send one UTF-8 message (maximum 16 KiB) over the current connection.",
            @(VKNetReceive): @"name - Receive one UTF-8 message (maximum 16 KiB) into a variable.",
            @(VKNetClose): @"- Close the current network connection and all server clients.",
            @(VKNetListenMulti): @"address port clients - Accept 2 to 16 clients. Server scripts only.",
            @(VKNetSendTo): @"client_id value - Send one message to an accepted client.",
            @(VKNetReceiveFrom): @"client_variable message_variable - Receive from any accepted client and store its 1-based id and message.",
            @(VKNetBroadcast): @"value - Send one message to every accepted client.",
            @(VKUIPhysics2D): @"id mass restitution - Configure a body; mass 0 is static and restitution is 0 to 1.",
            @(VKUIGravity2D): @"x y - Set the 2D scene gravity vector.",
            @(VKUIFrame2D): @"- Begin a per-frame script callback block.",
            @(VKUIEndFrame2D): @"- End the per-frame callback block.",
            @(VKUIMove2D): @"id dx dy - Move an object from a frame callback.",
            @(VKUIForce2D): @"id fx fy - Apply force to a dynamic object from a frame callback.",
            @(VKUISetVelocity2D): @"id vx vy - Set an object's velocity from a frame callback.",
            @(VKUIPhysics3D): @"id mass restitution - Configure a 3D rigid body using bounding-sphere collision.",
            @(VKUIGravity3D): @"x y z - Set the 3D scene gravity vector.",
            @(VKUIFrame3D): @"- Begin a per-frame 3D callback block.",
            @(VKUIEndFrame3D): @"- End the 3D callback block.",
            @(VKUIMove3D): @"id dx dy dz - Move a 3D object from a frame callback.",
            @(VKUIForce3D): @"id fx fy fz - Apply force to a dynamic 3D object.",
            @(VKUISetVelocity3D): @"id vx vy vz - Set 3D object velocity from a frame callback.",
            @(VKUIVelocity3D): @"id vx vy vz - Set initial 3D object velocity.",
            @(VKUIMesh3D): @"path x y z scale color - Import a local 3D mesh.",
            @(VKEncode): @"name format - Encode the variable's text. Formats include base64, hex, base58, url, json, and chains such as zstd+base64.",
            @(VKDecode): @"name format - Decode the variable's text from base64, hex, base64+gzip, base64+zstd, and other formats; the result must be UTF-8 text.",
            @(VKCodecList): @"- List every supported encoding and compression format.",
            @(VKAIConfigure): @"backend model - Select the ollama or openai backend and model.",
            @(VKTrain): @"source value - Add knowledge from text, file, HTTPS URL, or a Wikipedia topic.",
            @(VKAIClear): @"- Clear the current program's AI knowledge.",
            @(VKAIAsk): @"name question - Ask the configured AI and store its answer in name.",
            @(VKUIKeyMove3D): @"id key dx dy dz - Move a named 3D object when a key is pressed.",
            @(VKUIVoxel3D): @"x y z color - Add a unit block at integer coordinates.",
            @(VKUIVoxelControls3D): @"step color - Enable fly controls and mouse block editing.",
            @(VKUIRemove3D): @"id - Remove a named 3D object, including from a 3D frame callback."
        };
    });
    return descriptions[command[0]];
}

+ (NSString *)categoryForKeyword:(NSString *)keyword {
    NSArray *command = commandForKeyword(keyword.lowercaseString);
    if (!command) return nil;
    switch ([command[0] unsignedCharValue]) {
        case VKWindow: case VKUILabel: case VKUIButton: case VKUIInput: case VKUIColor:
        case VKUIShortcut: case VKUINote: case VKUIKeynote: case VKUISound: case VKUIKeyboard: case VKUIAutoTurn:
        case VKImport: case VKUIID: case VKUIBind: case VKUIScene3D: case VKUICamera3D:
        case VKUILight3D: case VKUIBox3D: case VKUISphere3D: case VKUICylinder3D:
        case VKUICone3D: case VKUITorus3D: case VKUIPlane3D: case VKUISpin3D:
        case VKUIScene2D: case VKUIRect2D: case VKUICircle2D: case VKUIVelocity2D: case VKUIKeyMove2D:
        case VKUIPhysics2D: case VKUIGravity2D: case VKUIFrame2D: case VKUIEndFrame2D:
        case VKUIMove2D: case VKUIForce2D: case VKUISetVelocity2D:
        case VKUIPhysics3D: case VKUIGravity3D: case VKUIFrame3D: case VKUIEndFrame3D:
        case VKUIMove3D: case VKUIForce3D: case VKUISetVelocity3D: case VKUIVelocity3D: case VKUIMesh3D: case VKUIKeyMove3D:
        case VKUIVoxel3D: case VKUIVoxelControls3D: case VKUIRemove3D: return @"UI";
        case VKIf: case VKUnless: case VKJump: case VKLabel: case VKEqual: case VKNotEqual:
        case VKLess: case VKLessEqual: case VKGreater: case VKGreaterEqual: case VKAnd: case VKOr: case VKNot:
            return @"Logic";
        case VKAdd: case VKSubtract: case VKMultiply: case VKDivide: case VKModulo: case VKPower:
        case VKMin: case VKMax: case VKSin: case VKCos: case VKTan: case VKAsin: case VKAcos:
        case VKAtan: case VKLog: case VKLog10: case VKExp: case VKSign: case VKTruncate:
        case VKAbs: case VKRound: case VKFloor: case VKCeil: case VKSqrt:
            return @"Math";
        case VKConcat: case VKUpper: case VKLower: case VKLength: case VKEmpty: case VKTrim:
        case VKContains: case VKStartsWith: case VKEndsWith: case VKReplace: case VKText: case VKIsText:
        case VKEncode: case VKDecode: case VKCodecList:
            return @"Text";
        default: return @"Code";
    }
}

+ (NSInteger)dimensionForKeyword:(NSString *)keyword {
    NSArray *command = commandForKeyword(keyword.lowercaseString);
    if (!command) return 0;
    VKOpcode opcode = [command[0] unsignedCharValue];
    if (opcodeIs2DGameInstruction(opcode)) return 2;
    if ((opcode >= VKUIScene3D && opcode <= VKUISpin3D) || opcodeIs3DGameInstruction(opcode)) return 3;
    if (opcode == VKImport || opcode == VKWindow || opcode == VKUIID || opcode == VKUIBind) return -1;
    return 0;
}

+ (NSData *)compile:(NSString *)source error:(NSString **)error {
    NSMutableData *bytecode = [NSMutableData dataWithBytes:"VK01" length:4];
    NSArray *lines = [source componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    BOOL importedUI = NO, sawUI = NO, declaredScriptRole = NO, sawInstruction = NO;
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *tokenError = nil;
        NSArray *tokens = tokenize(lines[index], &tokenError);
        if (!tokens) { [problems addObject:[NSString stringWithFormat:@"Line %lu: %@", (unsigned long)index + 1, tokenError]]; continue; }
        if (!tokens.count) continue;
        NSArray *command = commandForKeyword([tokens[0] lowercaseString]);
        if (!command || tokens.count != [command[1] unsignedIntegerValue] + 1) {
            [problems addObject:[NSString stringWithFormat:@"Line %lu: Unknown command or wrong number of operands: %@", (unsigned long)index + 1, lines[index]]];
            continue;
        }
        VKOpcode currentOpcode = [command[0] unsignedCharValue];
        if (currentOpcode == VKServerScript || currentOpcode == VKLocalScript) {
            if (declaredScriptRole || sawInstruction) [problems addObject:[NSString stringWithFormat:@"Line %lu: Declare one script role as the first instruction.", (unsigned long)index + 1]];
            declaredScriptRole = YES;
        } else sawInstruction = YES;
        if (currentOpcode == VKImport) {
            if (![tokens[1] isEqualToString:@"ui"]) [problems addObject:[NSString stringWithFormat:@"Line %lu: Only import ui is supported.", (unsigned long)index + 1]];
            else if (importedUI) [problems addObject:[NSString stringWithFormat:@"Line %lu: UI is already imported.", (unsigned long)index + 1]];
            else if (sawUI) [problems addObject:[NSString stringWithFormat:@"Line %lu: import ui must come before UI instructions.", (unsigned long)index + 1]];
            else importedUI = YES;
        } else if (opcodeIsUIInstruction(currentOpcode)) {
            sawUI = YES;
            if (!importedUI) [problems addObject:[NSString stringWithFormat:@"Line %lu: Add import ui before using UI instructions.", (unsigned long)index + 1]];
        }
        uint8_t opcode = [command[0] unsignedCharValue], count = (uint8_t)(tokens.count - 1 + (command.count == 3 ? 1 : 0));
        [bytecode appendBytes:&opcode length:1];
        [bytecode appendBytes:&count length:1];
        for (NSUInteger operand = 1; operand < tokens.count; operand++) appendString(bytecode, tokens[operand]);
        if (command.count == 3) appendString(bytecode, command[2]);
    }
    if (problems.count) { if (error) *error = [problems componentsJoinedByString:@"\n"]; return nil; }
    return bytecode;
}

static BOOL opcodeIs3DPrimitive(VKOpcode opcode) {
    return (opcode >= VKUIBox3D && opcode <= VKUIPlane3D) || opcode == VKUIMesh3D;
}

static BOOL opcodeHasNoName(VKOpcode opcode) {
    return opcode == VKOut || opcode == VKHalt || opcode == VKLabel || opcode == VKJump || opcode == VKIf || opcode == VKUnless ||
        (opcode >= VKWindow && opcode <= VKUIInput) || (opcode >= VKUIColor && opcode <= VKUIAutoTurn) ||
        opcode == VKImport || opcode == VKUIID || opcode == VKUIBind || (opcode >= VKUIScene3D && opcode <= VKUISpin3D) || opcodeIs2DGameInstruction(opcode) ||
        opcode == VKTerminalRun || opcode == VKTerminalEcho || opcode == VKTerminalKeywords || opcode == VKCite || opcode == VKCodecList ||
        opcode == VKAIConfigure || opcode == VKTrain || opcode == VKAIClear ||
        opcode == VKServerScript || opcode == VKLocalScript || (opcode >= VKNetListen && opcode <= VKNetBroadcast) ||
        opcode == VKUIGravity2D || opcode == VKUIFrame2D || opcode == VKUIEndFrame2D ||
        opcode == VKUIPhysics2D || opcode == VKUIMove2D || opcode == VKUIForce2D || opcode == VKUISetVelocity2D ||
        opcode == VKUIGravity3D || opcode == VKUIFrame3D || opcode == VKUIEndFrame3D || opcodeIs3DGameInstruction(opcode);
}

+ (NSArray<NSString *> *)diagnose:(NSString *)source {
    NSArray *lines = [source componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *labels = [NSMutableDictionary dictionary], *definitions = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *reads = [NSMutableSet set], *usedLabels = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *uiIDTypes = [NSMutableDictionary dictionary];
    NSMutableArray *parsed = [NSMutableArray array];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *tokenError = nil;
        NSArray *tokens = tokenize(lines[index], &tokenError);
        NSString *position = [NSString stringWithFormat:@"line %lu", (unsigned long)index + 1];
        if (!tokens) { [result addObject:[NSString stringWithFormat:@"Error %@: %@", position, tokenError]]; continue; }
        if (!tokens.count) continue;
        NSArray *command = commandForKeyword([tokens[0] lowercaseString]);
        if (!command) { [result addObject:[NSString stringWithFormat:@"Error %@: Unknown command: %@", position, tokens[0]]]; continue; }
        NSUInteger expected = [command[1] unsignedIntegerValue];
        if (tokens.count != expected + 1) {
            [result addObject:[NSString stringWithFormat:@"Error %@: %@ needs %lu operand%@ but has %lu.", position, tokens[0], (unsigned long)expected, expected == 1 ? @"" : @"s", (unsigned long)tokens.count - 1]];
            continue;
        }
        [parsed addObject:@[@(index + 1), command[0], tokens]];
    }
    BOOL sawWindow = NO, importedUI = NO, sawUI = NO, sawScene3D = NO, sawScene2D = NO, afterEnd = NO, reportedDead = NO;
    BOOL declaredScriptRole = NO, sawInstruction = NO;
    VKOpcode scriptRole = 0;
    NSMutableSet<NSString *> *uiIDs = [NSMutableSet set];
    VKOpcode previousUI = 0;
    for (NSArray *entry in parsed) {
        NSUInteger number = [entry[0] unsignedIntegerValue];
        VKOpcode opcode = [entry[1] unsignedCharValue];
        NSArray *tokens = entry[2];
        NSString *position = [NSString stringWithFormat:@"line %lu", (unsigned long)number];
        if (opcode == VKServerScript || opcode == VKLocalScript) {
            if (declaredScriptRole || sawInstruction) [result addObject:[NSString stringWithFormat:@"Error %@: Declare one script role as the first instruction.", position]];
            else scriptRole = opcode;
            declaredScriptRole = YES;
            continue;
        }
        sawInstruction = YES;
        if (scriptRole == VKServerScript && opcodeIsUIInstruction(opcode)) [result addObject:[NSString stringWithFormat:@"Error %@: Server scripts cannot create UI.", position]];
        if (opcode >= VKNetListen && opcode <= VKNetBroadcast) {
            if (!scriptRole) [result addObject:[NSString stringWithFormat:@"Error %@: Declare server_script or local_script before networking.", position]];
            if (opcode == VKNetListen && scriptRole != VKServerScript) [result addObject:[NSString stringWithFormat:@"Error %@: net_listen requires server_script.", position]];
            if (opcode == VKNetConnect && scriptRole != VKLocalScript) [result addObject:[NSString stringWithFormat:@"Error %@: net_connect requires local_script.", position]];
            if (opcode == VKNetListenMulti && scriptRole != VKServerScript) [result addObject:[NSString stringWithFormat:@"Error %@: net_listen_multi requires server_script.", position]];
            if ((opcode == VKNetSendTo || opcode == VKNetReceiveFrom || opcode == VKNetBroadcast) && scriptRole != VKServerScript) [result addObject:[NSString stringWithFormat:@"Error %@: Multi-client networking requires server_script.", position]];
        }
        if (opcode == VKImport) {
            if (![tokens[1] isEqualToString:@"ui"]) [result addObject:[NSString stringWithFormat:@"Error %@: Only import ui is supported.", position]];
            else if (importedUI) [result addObject:[NSString stringWithFormat:@"Error %@: UI is already imported.", position]];
            else if (sawUI) [result addObject:[NSString stringWithFormat:@"Error %@: import ui must come before UI instructions.", position]];
            else importedUI = YES;
            continue;
        }
        BOOL uiInstruction = opcodeIsUIInstruction(opcode);
        if (uiInstruction) {
            sawUI = YES;
            if (!importedUI) [result addObject:[NSString stringWithFormat:@"Error %@: Add import ui before using UI instructions.", position]];
        }
        if (opcode == VKUIScene3D) {
            if (sawScene3D) [result addObject:[NSString stringWithFormat:@"Error %@: A window can only have one 3D viewport.", position]];
            sawScene3D = YES;
        } else if (((opcode >= VKUICamera3D && opcode <= VKUISpin3D) || opcodeIs3DGameInstruction(opcode)) && !sawScene3D) {
            [result addObject:[NSString stringWithFormat:@"Error %@: Add ui_scene3d before 3D scene instructions.", position]];
        }
        if (opcode == VKUIScene2D) {
            if (sawScene2D) [result addObject:[NSString stringWithFormat:@"Error %@: A window can only have one 2D game scene.", position]];
            sawScene2D = YES;
        } else if (opcodeIs2DGameInstruction(opcode) && !sawScene2D) {
            [result addObject:[NSString stringWithFormat:@"Error %@: Add ui_scene2d before 2D game instructions.", position]];
        }
        if (opcode == VKUIID) {
            NSString *identifier = tokens[1];
            if (!(previousUI == VKUILabel || previousUI == VKUIButton || previousUI == VKUIInput || opcodeIs3DPrimitive(previousUI)))
                [result addObject:[NSString stringWithFormat:@"Error %@: ui_id must follow a control or 3D object.", position]];
            if ([uiIDs containsObject:identifier]) [result addObject:[NSString stringWithFormat:@"Error %@: UI id %@ is already defined.", position, identifier]];
            else { [uiIDs addObject:identifier]; uiIDTypes[identifier] = @(previousUI); }
            previousUI = opcode;
            continue;
        }
        if (opcode == VKUIBind) {
            [reads addObject:tokens[2]];
            if (![uiIDs containsObject:tokens[1]])
                [result addObject:[NSString stringWithFormat:@"Error %@: ui_bind refers to unknown UI id %@.", position, tokens[1]]];
            else {
                VKOpcode target = [uiIDTypes[tokens[1]] unsignedCharValue];
                if (target != VKUILabel && target != VKUIInput)
                    [result addObject:[NSString stringWithFormat:@"Error %@: ui_bind requires a label or input id.", position]];
            }
            previousUI = opcode;
        }
        if (opcode == VKLabel) {
            NSString *name = tokens[1];
            if (labels[name]) [result addObject:[NSString stringWithFormat:@"Error %@: Label %@ is already defined on line %@.", position, name, labels[name]]];
            else labels[name] = @(number);
            afterEnd = NO; reportedDead = NO;
            continue;
        }
        if (afterEnd && !reportedDead) { [result addObject:[NSString stringWithFormat:@"Warning %@: Unreachable code after halt or jump.", position]]; reportedDead = YES; }
        BOOL noName = opcodeHasNoName(opcode);
        if (!noName) {
            NSString *name = tokens[1];
            if ((opcode == VKText || opcode == VKSet || opcode == VKAIAsk) && !definitions[name]) definitions[name] = @(number);
            if (opcode != VKText && opcode != VKSet && opcode != VKAIAsk) [reads addObject:name];
        }
        for (NSUInteger operand = noName ? 1 : 2; operand < tokens.count; operand++) {
            if ([tokens[operand] hasPrefix:@"$"]) [reads addObject:[tokens[operand] substringFromIndex:1]];
        }
        if (opcode == VKJump) [usedLabels addObject:tokens[1]];
        if (opcode == VKIf || opcode == VKUnless) [usedLabels addObject:tokens[2]];
        if (opcode == VKHalt || opcode == VKJump) afterEnd = YES;
        if (opcode == VKWindow) {
            if (sawWindow) [result addObject:[NSString stringWithFormat:@"Error %@: A program can only have one window.", position]];
            sawWindow = YES;
        } else if (opcodeIsUIInstruction(opcode) && !sawWindow) {
            [result addObject:[NSString stringWithFormat:@"Error %@: Create a window before this UI command.", position]];
        }
        if (opcode == VKUIAutoTurn && !(previousUI == VKUILabel || previousUI == VKUIButton || previousUI == VKUIInput))
            [result addObject:[NSString stringWithFormat:@"Error %@: auto_turn must follow a label, button, or input.", position]];
        if ((opcode >= VKUILabel && opcode <= VKUIInput) || (opcode >= VKUIShortcut && opcode <= VKUIKeyboard) ||
            (opcode >= VKUIScene3D && opcode <= VKUISpin3D) || opcode == VKUIMesh3D || opcode == VKUIScene2D || opcode == VKUIRect2D || opcode == VKUICircle2D) previousUI = opcode;
        NSString *firstToken = tokens.count > 1 ? tokens[1] : @"";
        if (opcode == VKUIColor && [firstToken hasPrefix:@"\""] && firstToken.length >= 2) {
            NSString *color = [firstToken substringWithRange:NSMakeRange(1, firstToken.length - 2)];
            NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$" options:0 error:nil];
            if ([hex numberOfMatchesInString:color options:0 range:NSMakeRange(0, color.length)] != 1)
                [result addObject:[NSString stringWithFormat:@"Error %@: ui_color expects a #RRGGBB color.", position]];
        }
    }
    BOOL insideFrameCallback = NO;
    NSSet<NSString *> *frameVariables = [NSSet setWithArray:@[@"delta_time", @"collision", @"collision_count", @"collision_a", @"collision_b", @"collision_entered", @"collision_exited"]];
    for (NSArray *entry in parsed) {
        VKOpcode opcode = [entry[1] unsignedCharValue];
        NSArray *tokens = entry[2];
        NSString *position = [NSString stringWithFormat:@"line %@", entry[0]];
        if (opcode == VKUIFrame2D || opcode == VKUIFrame3D) insideFrameCallback = YES;
        else if (opcode == VKUIEndFrame2D || opcode == VKUIEndFrame3D) insideFrameCallback = NO;
        if (opcode == VKJump || opcode == VKIf || opcode == VKUnless) {
            NSString *target = tokens[opcode == VKJump ? 1 : 2];
            if (!labels[target]) [result addObject:[NSString stringWithFormat:@"Error %@: Unknown label %@.", position, target]];
        }
        if (opcode == VKUISpin3D) {
            NSString *identifier = tokens[1];
            if (![uiIDs containsObject:identifier] || !opcodeIs3DPrimitive([uiIDTypes[identifier] unsignedCharValue]))
                [result addObject:[NSString stringWithFormat:@"Error %@: ui_spin3d needs an ID assigned to a 3D object.", position]];
        }
        BOOL noName = opcodeHasNoName(opcode);
        if (opcode == VKUIBind && !definitions[tokens[2]])
            [result addObject:[NSString stringWithFormat:@"Error %@: Variable $%@ is used but never defined with text or set.", position, tokens[2]]];
        if (!noName && opcode != VKText && opcode != VKSet && opcode != VKAIAsk && !definitions[tokens[1]])
            [result addObject:[NSString stringWithFormat:@"Error %@: Variable $%@ is used but never defined with text or set.", position, tokens[1]]];
        for (NSUInteger operand = noName ? 1 : 2; operand < tokens.count; operand++) {
            NSString *variable = [tokens[operand] hasPrefix:@"$"] ? [tokens[operand] substringFromIndex:1] : nil;
            if (variable && !definitions[variable] && !(insideFrameCallback && [frameVariables containsObject:variable]))
                [result addObject:[NSString stringWithFormat:@"Error %@: Variable %@ is never defined.", position, tokens[operand]]];
        }
    }
    for (NSString *name in labels) if (![usedLabels containsObject:name]) [result addObject:[NSString stringWithFormat:@"Warning line %@: Label %@ is never used.", labels[name], name]];
    for (NSString *name in definitions) if (![reads containsObject:name]) [result addObject:[NSString stringWithFormat:@"Warning line %@: Variable $%@ is set but never used.", definitions[name], name]];
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger first = [[a componentsSeparatedByString:@"line "].lastObject integerValue], second = [[b componentsSeparatedByString:@"line "].lastObject integerValue];
        return first < second ? NSOrderedAscending : first > second ? NSOrderedDescending : [a compare:b];
    }];
}

+ (NSString *)run:(NSData *)bytecode error:(NSString **)error {
    return [self run:bytecode ui:[NSMutableArray array] error:error];
}

+ (NSString *)run:(NSData *)bytecode ui:(NSMutableArray *)ui error:(NSString **)error {
    const uint8_t *bytes = bytecode.bytes;
    if (bytecode.length < 4 || memcmp(bytes, "VK01", 4)) { if (error) *error = @"Invalid Vektkove bytecode."; return nil; }
    NSUInteger position = 4;
    NSMutableArray *instructions = [NSMutableArray array];
    NSMutableDictionary *labels = [NSMutableDictionary dictionary];
    NSMutableDictionary *arity = [NSMutableDictionary dictionary];
    for (NSArray *command in commandTable().allValues) arity[command[0]] = command[1];
    while (position < bytecode.length) {
        if (position + 2 > bytecode.length) { if (error) *error = @"Truncated instruction."; return nil; }
        uint8_t opcode = bytes[position++], count = bytes[position++];
        NSMutableArray *operands = [NSMutableArray array];
        for (NSUInteger index = 0; index < count; index++) {
            if (position + 4 > bytecode.length) { if (error) *error = @"Truncated operand."; return nil; }
            uint32_t length; memcpy(&length, bytes + position, 4); position += 4; length = CFSwapInt32BigToHost(length);
            if (length > bytecode.length - position) { if (error) *error = @"Truncated operand."; return nil; }
            NSString *operand = [[NSString alloc] initWithBytes:bytes + position length:length encoding:NSUTF8StringEncoding];
            if (!operand) { if (error) *error = @"Invalid operand encoding."; return nil; }
            [operands addObject:operand]; position += length;
        }
        NSNumber *expected = arity[@(opcode)];
        if (!expected || count != expected.unsignedIntegerValue) { if (error) *error = @"Invalid instruction."; return nil; }
        if (opcode == VKLabel) {
            if (labels[operands[0]]) { if (error) *error = @"Duplicate label."; return nil; }
            labels[operands[0]] = @(instructions.count);
        }
        [instructions addObject:@[@(opcode), operands]];
    }
    NSMutableDictionary *variables = [NSMutableDictionary dictionary];
    VKAIState *aiState = [[VKAIState alloc] init];
    NSMutableSet<NSString *> *uiIDs = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *uiIDTypes = [NSMutableDictionary dictionary];
    NSMutableString *output = [NSMutableString string];
    NSString *uiColor = @"#DCE7F5";
    BOOL importedUI = NO;
    VKOpcode previousUI = 0;
    VKOpcode scriptRole = 0;
    VKTCPChannel *networkChannel = nil;
    NSMutableArray<VKTCPChannel *> *networkClients = [NSMutableArray array];
    BOOL sawScene3D = NO, sawCamera3D = NO, sawScene2D = NO, sawFrame2D = NO, sawGravity2D = NO, sawFrame3D = NO, sawGravity3D = NO;
    NSMutableSet<NSString *> *scene2DIDs = [NSMutableSet set];
    NSUInteger steps = 0;
    for (NSUInteger index = 0; index < instructions.count; index++) {
        if (++steps > 100000) { if (error) *error = @"Execution limit exceeded."; return nil; }
        VKOpcode opcode = [instructions[index][0] unsignedCharValue];
        NSArray *operands = instructions[index][1];
        if (opcode == VKImport) {
            if (operands.count != 1 || ![operands[0] isEqualToString:@"ui"] || importedUI || ui.count) {
                if (error) *error = @"Place one 'import ui' before all UI instructions.";
                return nil;
            }
            importedUI = YES;
            continue;
        }
        BOOL uiInstruction = opcodeIsUIInstruction(opcode);
        if (uiInstruction && !importedUI) { if (error) *error = @"Add 'import ui' before using UI instructions."; return nil; }
        if (opcode == VKServerScript || opcode == VKLocalScript) {
            if (scriptRole || index != 0) { if (error) *error = @"Declare one script role as the first instruction."; return nil; }
            scriptRole = opcode;
            continue;
        }
        if (scriptRole == VKServerScript && uiInstruction) { if (error) *error = @"Server scripts cannot create UI."; return nil; }
        if (opcode >= VKNetListen && opcode <= VKNetBroadcast) {
            if (!scriptRole) { if (error) *error = @"Declare server_script or local_script before networking."; return nil; }
            if (opcode == VKNetListen && scriptRole != VKServerScript) { if (error) *error = @"net_listen requires server_script."; return nil; }
            if (opcode == VKNetConnect && scriptRole != VKLocalScript) { if (error) *error = @"net_connect requires local_script."; return nil; }
            if (opcode == VKNetListenMulti && scriptRole != VKServerScript) { if (error) *error = @"net_listen_multi requires server_script."; return nil; }
            if ((opcode == VKNetSendTo || opcode == VKNetReceiveFrom || opcode == VKNetBroadcast) && scriptRole != VKServerScript) { if (error) *error = @"Multi-client networking requires server_script."; return nil; }
            if (opcode == VKNetListenMulti) {
                NSString *runtimeError = nil;
                id hostValue = valueOf(operands[0], variables, &runtimeError);
                id portValue = valueOf(operands[1], variables, &runtimeError);
                id countValue = valueOf(operands[2], variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                if (![hostValue isKindOfClass:NSString.class] || ![hostValue length] || [hostValue length] > 255 ||
                    ![portValue isKindOfClass:NSNumber.class] || [(NSNumber *)portValue doubleValue] < 1 || [(NSNumber *)portValue doubleValue] > 65535 || floor([(NSNumber *)portValue doubleValue]) != [(NSNumber *)portValue doubleValue] ||
                    ![countValue isKindOfClass:NSNumber.class] || [(NSNumber *)countValue doubleValue] < 2 || [(NSNumber *)countValue doubleValue] > 16 || floor([(NSNumber *)countValue doubleValue]) != [(NSNumber *)countValue doubleValue]) {
                    if (error) *error = @"net_listen_multi needs an address, port 1 to 65535, and client count 2 to 16.";
                    return nil;
                }
                int listener = VKOpenTCPListener(hostValue, [portValue unsignedIntegerValue]);
                if (listener < 0) { if (error) *error = [NSString stringWithFormat:@"Could not listen on %@:%@.", hostValue, portValue]; return nil; }
                NSMutableArray<VKTCPChannel *> *accepted = [NSMutableArray arrayWithCapacity:[countValue unsignedIntegerValue]];
                for (NSUInteger clientIndex = 0; clientIndex < [countValue unsignedIntegerValue]; clientIndex++) {
                    int descriptor = VKAcceptTCPClient(listener);
                    if (descriptor < 0) {
                        close(listener);
                        for (VKTCPChannel *client in accepted) [client closeChannel];
                        if (error) *error = @"Could not accept every requested TCP client.";
                        return nil;
                    }
                    [accepted addObject:[[VKTCPChannel alloc] initWithDescriptor:descriptor]];
                }
                close(listener);
                [networkChannel closeChannel];
                networkChannel = nil;
                for (VKTCPChannel *client in networkClients) [client closeChannel];
                networkClients = accepted;
                continue;
            }
            if (opcode == VKNetListen || opcode == VKNetConnect) {
                NSString *runtimeError = nil;
                id hostValue = valueOf(operands[0], variables, &runtimeError);
                id portValue = valueOf(operands[1], variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                if (![hostValue isKindOfClass:NSString.class] || ![hostValue length] || [hostValue length] > 255 ||
                    ![portValue isKindOfClass:NSNumber.class] || [portValue doubleValue] < 1 || [portValue doubleValue] > 65535 || floor([portValue doubleValue]) != [portValue doubleValue]) {
                    if (error) *error = @"Network address must be nonempty text and port must be an integer from 1 to 65535.";
                    return nil;
                }
                int descriptor = VKOpenTCPConnection(hostValue, [portValue unsignedIntegerValue], opcode == VKNetListen);
                if (descriptor < 0) { if (error) *error = [NSString stringWithFormat:@"Could not %@ %@:%@.", opcode == VKNetListen ? @"accept a peer on" : @"connect to", hostValue, portValue]; return nil; }
                [networkChannel closeChannel];
                networkChannel = [[VKTCPChannel alloc] initWithDescriptor:descriptor];
                continue;
            }
            if (opcode == VKNetSend) {
                if (!networkChannel || networkChannel.descriptor < 0) { if (error) *error = @"net_send requires an open connection."; return nil; }
                NSString *runtimeError = nil;
                id message = valueOf(operands[0], variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                if (!VKSendNetworkMessage(networkChannel, [message description])) { if (error) *error = @"Could not send message; messages are limited to 16 KiB."; return nil; }
                continue;
            }
            if (opcode == VKNetReceive) {
                if (!networkChannel || networkChannel.descriptor < 0) { if (error) *error = @"net_receive requires an open connection."; return nil; }
                NSString *name = operands[0];
                NSCharacterSet *invalidName = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
                if (!name.length || [name rangeOfCharacterFromSet:invalidName].location != NSNotFound || [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[name characterAtIndex:0]]) { if (error) *error = @"Invalid variable name for net_receive."; return nil; }
                NSString *message = VKReceiveNetworkMessage(networkChannel);
                if (!message) { if (error) *error = @"Could not receive a valid UTF-8 message within 16 KiB."; return nil; }
                variables[name] = message;
                continue;
            }
            if (opcode == VKNetSendTo) {
                NSString *runtimeError = nil;
                id clientValue = valueOf(operands[0], variables, &runtimeError);
                id messageValue = valueOf(operands[1], variables, &runtimeError);
                NSUInteger clientID = [clientValue respondsToSelector:@selector(unsignedIntegerValue)] ? [clientValue unsignedIntegerValue] : 0;
                if (runtimeError || ![clientValue isKindOfClass:NSNumber.class] || clientID < 1 || clientID > networkClients.count) { if (error) *error = runtimeError ?: @"net_send_to client id must identify an accepted client."; return nil; }
                if (!VKSendNetworkMessage(networkClients[clientID - 1], [messageValue description])) { if (error) *error = @"Could not send message; messages are limited to 16 KiB."; return nil; }
                continue;
            }
            if (opcode == VKNetReceiveFrom) {
                NSString *clientName = operands[0], *messageName = operands[1];
                NSCharacterSet *invalidName = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
                if (!networkClients.count || !clientName.length || !messageName.length ||
                    [clientName rangeOfCharacterFromSet:invalidName].location != NSNotFound || [messageName rangeOfCharacterFromSet:invalidName].location != NSNotFound ||
                    [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[clientName characterAtIndex:0]] || [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[messageName characterAtIndex:0]]) {
                    if (error) *error = @"net_receive_from needs an open multi-client server and two valid variable names.";
                    return nil;
                }
                fd_set readable;
                FD_ZERO(&readable);
                int maximumDescriptor = -1;
                for (VKTCPChannel *client in networkClients) { FD_SET(client.descriptor, &readable); maximumDescriptor = MAX(maximumDescriptor, client.descriptor); }
                struct timeval timeout = {60, 0};
                int ready = select(maximumDescriptor + 1, &readable, NULL, NULL, &timeout);
                if (ready <= 0) { if (error) *error = @"Timed out waiting for a client message."; return nil; }
                for (NSUInteger clientIndex = 0; clientIndex < networkClients.count; clientIndex++) {
                    VKTCPChannel *client = networkClients[clientIndex];
                    if (!FD_ISSET(client.descriptor, &readable)) continue;
                    NSString *message = VKReceiveNetworkMessage(client);
                    if (!message) { if (error) *error = @"Could not receive a valid UTF-8 message within 16 KiB."; return nil; }
                    variables[clientName] = @(clientIndex + 1);
                    variables[messageName] = message;
                    break;
                }
                continue;
            }
            if (opcode == VKNetBroadcast) {
                NSString *runtimeError = nil;
                id message = valueOf(operands[0], variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                if (!networkClients.count) { if (error) *error = @"net_broadcast requires accepted clients."; return nil; }
                for (VKTCPChannel *client in networkClients) if (!VKSendNetworkMessage(client, [message description])) { if (error) *error = @"Could not broadcast message; messages are limited to 16 KiB."; return nil; }
                continue;
            }
            [networkChannel closeChannel];
            networkChannel = nil;
            for (VKTCPChannel *client in networkClients) [client closeChannel];
            [networkClients removeAllObjects];
            continue;
        }
        if (opcode == VKHalt) break;
        if (opcode == VKLabel) continue;
        if (opcode == VKJump || opcode == VKIf || opcode == VKUnless) {
            NSString *runtimeError = nil;
            id condition = opcode == VKJump ? @YES : valueOf(operands[0], variables, &runtimeError);
            if (runtimeError) { if (error) *error = runtimeError; return nil; }
            BOOL truth = [condition isKindOfClass:[NSNumber class]] ? [condition doubleValue] != 0 : [[condition description] length] != 0;
            NSString *target = operands[opcode == VKJump ? 0 : 1];
            NSNumber *destination = labels[target];
            if (!destination) { if (error) *error = [NSString stringWithFormat:@"Unknown label %@.", target]; return nil; }
            if ((opcode == VKJump) || (opcode == VKIf && truth) || (opcode == VKUnless && !truth)) index = destination.unsignedIntegerValue;
            continue;
        }
        if (opcode == VKUIID) {
            NSString *runtimeError = nil;
            id identifier = valueOf(operands[0], variables, &runtimeError);
            if (runtimeError) { if (error) *error = runtimeError; return nil; }
            VKOpcode control = ui.count ? [ui.lastObject[0] unsignedCharValue] : 0;
            if (![identifier isKindOfClass:NSString.class] || ![identifier length] ||
                    !(control == VKUILabel || control == VKUIButton || control == VKUIInput || opcodeIs3DPrimitive(control)) || [uiIDs containsObject:identifier]) {
                if (error) *error = @"ui_id needs a unique nonempty id after a control or 3D object.";
                return nil;
            }
            [uiIDs addObject:identifier];
            uiIDTypes[identifier] = @(previousUI);
            [ui addObject:@[@(opcode), @[identifier]]];
            continue;
        }
        if (opcode == VKUIBind) {
            NSString *runtimeError = nil;
            id identifier = valueOf(operands[0], variables, &runtimeError);
            if (runtimeError) { if (error) *error = runtimeError; return nil; }
            NSString *name = operands[1];
            id value = variables[name];
            VKOpcode target = [uiIDTypes[identifier] unsignedCharValue];
            if (![identifier isKindOfClass:NSString.class] || ![uiIDs containsObject:identifier] || !value || (target != VKUILabel && target != VKUIInput)) {
                if (error) *error = @"ui_bind needs an existing UI id and defined variable name.";
                return nil;
            }
            [ui addObject:@[@(opcode), @[identifier, name, [value description]]]];
            continue;
        }
        if (opcode >= VKUIScene3D && opcode <= VKUISpin3D) {
            if (!ui.count) { if (error) *error = @"Create a window before adding a 3D scene."; return nil; }
            NSString *runtimeError = nil;
            if (opcode == VKUIScene3D) {
                if (sawScene3D) { if (error) *error = @"A window can only have one 3D viewport."; return nil; }
                NSMutableArray *values = [NSMutableArray array];
                for (NSString *operand in operands) {
                    id value = valueOf(operand, variables, &runtimeError);
                    if (runtimeError) { if (error) *error = runtimeError; return nil; }
                    [values addObject:value];
                }
                for (NSUInteger index = 0; index < values.count; index++) {
                    NSNumber *number = values[index];
                    if (![number isKindOfClass:NSNumber.class] || number.doubleValue < 0 || number.doubleValue > 10000) {
                        if (error) *error = @"3D viewport positions and sizes must be numbers from 0 to 10000.";
                        return nil;
                    }
                }
                if ([values[2] doubleValue] < 1 || [values[3] doubleValue] < 1) { if (error) *error = @"3D viewport dimensions must be positive."; return nil; }
                [ui addObject:@[@(opcode), values]];
                sawScene3D = YES;
                previousUI = opcode;
                continue;
            }
            if (!sawScene3D) { if (error) *error = @"Add ui_scene3d before 3D scene instructions."; return nil; }
            if (opcode == VKUISpin3D) {
                id identifier = valueOf(operands[0], variables, &runtimeError);
                id durationValue = valueOf(operands[1], variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                NSNumber *duration = [durationValue isKindOfClass:NSNumber.class] ? durationValue : nil;
                if (![identifier isKindOfClass:NSString.class] || !opcodeIs3DPrimitive([uiIDTypes[identifier] unsignedCharValue]) ||
                        ![duration isKindOfClass:NSNumber.class] || duration.doubleValue < 0.1 || duration.doubleValue > 3600) {
                    if (error) *error = @"ui_spin3d needs a 3D object id and duration from 0.1 to 3600 seconds.";
                    return nil;
                }
                [ui addObject:@[@(opcode), @[identifier, duration]]];
                previousUI = opcode;
                continue;
            }
            NSMutableArray *values = [NSMutableArray array];
            for (NSString *operand in operands) {
                id value = valueOf(operand, variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                [values addObject:value];
            }
            if (opcode == VKUICamera3D && sawCamera3D) { if (error) *error = @"A 3D scene can only have one camera."; return nil; }
            if (opcode == VKUICamera3D && [values[0] doubleValue] == 0 && [values[1] doubleValue] == 0 && [values[2] doubleValue] == 0) { if (error) *error = @"3D camera cannot be placed at the origin."; return nil; }
            NSUInteger numericCount = values.count - ((opcode == VKUICamera3D || opcode == VKUILight3D) ? 0 : 1);
            for (NSUInteger index = 0; index < numericCount; index++) {
                id value = values[index];
                if (![value isKindOfClass:NSNumber.class] || [value doubleValue] < -10000 || [value doubleValue] > 10000) {
                    if (error) *error = @"3D coordinates and dimensions must be numbers from -10000 to 10000.";
                    return nil;
                }
            }
            if (opcode == VKUILight3D && [values[3] doubleValue] < 0) { if (error) *error = @"3D light intensity must be nonnegative."; return nil; }
            if (opcode == VKUIBox3D && ([values[3] doubleValue] <= 0 || [values[4] doubleValue] <= 0 || [values[5] doubleValue] <= 0)) { if (error) *error = @"3D box dimensions must be positive."; return nil; }
            if (opcode == VKUISphere3D && [values[3] doubleValue] <= 0) { if (error) *error = @"3D sphere radius must be positive."; return nil; }
            if (opcode == VKUICylinder3D && ([values[3] doubleValue] <= 0 || [values[4] doubleValue] <= 0)) { if (error) *error = @"3D cylinder dimensions must be positive."; return nil; }
            if (opcode == VKUICone3D && ([values[3] doubleValue] < 0 || [values[4] doubleValue] <= 0 || [values[5] doubleValue] <= 0 || ([values[3] doubleValue] == 0 && [values[4] doubleValue] == 0))) { if (error) *error = @"3D cone dimensions are invalid."; return nil; }
            if (opcode == VKUITorus3D && ([values[3] doubleValue] <= 0 || [values[4] doubleValue] <= 0)) { if (error) *error = @"3D torus radii must be positive."; return nil; }
            if (opcode == VKUIPlane3D && ([values[3] doubleValue] <= 0 || [values[4] doubleValue] <= 0)) { if (error) *error = @"3D plane dimensions must be positive."; return nil; }
            if (opcode >= VKUIBox3D && opcode <= VKUIPlane3D) {
                NSString *color = [values.lastObject isKindOfClass:NSString.class] ? values.lastObject : nil;
                NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$" options:0 error:nil];
                if (!color || [hex numberOfMatchesInString:color options:0 range:NSMakeRange(0, color.length)] != 1) { if (error) *error = @"3D primitive color must use #RRGGBB."; return nil; }
            }
            [ui addObject:@[@(opcode), values]];
            if (opcode == VKUICamera3D) sawCamera3D = YES;
            if (opcodeIs3DPrimitive(opcode)) previousUI = opcode;
            continue;
        }
        if (opcode == VKUIFrame2D || opcode == VKUIFrame3D) {
            BOOL frame3D = opcode == VKUIFrame3D;
            if (frame3D ? (!sawScene3D || sawFrame3D) : (!sawScene2D || sawFrame2D)) {
                if (error) *error = frame3D ? @"ui_frame3d needs a 3D scene and may be used once." : @"ui_frame2d needs a 2D scene and may be used once.";
                return nil;
            }
            NSUInteger end = index + 1;
            VKOpcode endOpcode = frame3D ? VKUIEndFrame3D : VKUIEndFrame2D;
            while (end < instructions.count && [instructions[end][0] unsignedCharValue] != endOpcode) end++;
            if (end == instructions.count) { if (error) *error = frame3D ? @"ui_frame3d is missing ui_end_frame3d." : @"ui_frame2d is missing ui_end_frame2d."; return nil; }
            NSArray *callback = [instructions subarrayWithRange:NSMakeRange(index + 1, end - index - 1)];
            for (NSArray *instruction in callback) {
                VKOpcode callbackOpcode = [instruction[0] unsignedCharValue];
                if (!opcodeIsFrameCallbackInstruction(callbackOpcode)) {
                    if (error) *error = @"Frame callbacks allow variable, branch, and 2D action instructions only.";
                    return nil;
                }
                if (callbackOpcode == VKUIMove2D || callbackOpcode == VKUIForce2D || callbackOpcode == VKUISetVelocity2D ||
                    callbackOpcode == VKUIMove3D || callbackOpcode == VKUIForce3D || callbackOpcode == VKUISetVelocity3D || callbackOpcode == VKUIRemove3D) {
                    BOOL action3D = callbackOpcode == VKUIMove3D || callbackOpcode == VKUIForce3D || callbackOpcode == VKUISetVelocity3D || callbackOpcode == VKUIRemove3D;
                    if (action3D != frame3D) { if (error) *error = @"Frame callback actions must match the scene dimension."; return nil; }
                    NSString *callbackError = nil;
                    NSArray *callbackOperands = instruction[1];
                    NSString *identifierToken = callbackOperands[0];
                    id identifier = [identifierToken hasPrefix:@"$"] ? nil : valueOf(identifierToken, variables, &callbackError);
                    BOOL knownObject = [identifierToken hasPrefix:@"$"] || ([identifier isKindOfClass:NSString.class] && (action3D ? opcodeIs3DPrimitive([uiIDTypes[identifier] unsignedCharValue]) : [scene2DIDs containsObject:identifier]));
                    BOOL validNumbers = YES;
                    for (NSUInteger operand = 1; operand < callbackOperands.count; operand++) {
                        NSString *token = callbackOperands[operand];
                        if (![token hasPrefix:@"$"] && ![valueOf(token, variables, &callbackError) isKindOfClass:NSNumber.class]) validNumbers = NO;
                    }
                    if (callbackError || !knownObject || !validNumbers) {
                        if (error) *error = action3D ? @"3D callback action needs an existing 3D object id and numeric values." : @"Frame callback action needs an existing 2D object id and numeric values.";
                        return nil;
                    }
                }
            }
            [ui addObject:@[@(VKUIFrameData), @[@(frame3D ? VKUIScene3D : VKUIScene2D), callback, variables]]];
            if (frame3D) sawFrame3D = YES;
            else sawFrame2D = YES;
            index = end;
            continue;
        }
        if (opcode == VKUIEndFrame2D) { if (error) *error = @"ui_end_frame2d must close ui_frame2d."; return nil; }
        if (opcode == VKUIEndFrame3D) { if (error) *error = @"ui_end_frame3d must close ui_frame3d."; return nil; }
        if (opcodeIs3DGameInstruction(opcode)) {
            if (!sawScene3D) { if (error) *error = @"Add ui_scene3d before 3D physics instructions."; return nil; }
            NSString *runtimeError = nil;
            NSMutableArray *values = [NSMutableArray array];
            for (NSString *operand in operands) {
                id value = valueOf(operand, variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                [values addObject:value];
            }
            if (opcode == VKUIMesh3D) {
                NSString *path = [values[0] isKindOfClass:NSString.class] ? values[0] : nil;
                NSString *color = [values[5] isKindOfClass:NSString.class] ? values[5] : nil;
                NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$" options:0 error:nil];
                if (!path.length || !color || [hex numberOfMatchesInString:color options:0 range:NSMakeRange(0, color.length)] != 1) { if (error) *error = @"ui_mesh3d needs a model path and #RRGGBB color."; return nil; }
                for (NSUInteger component = 1; component <= 4; component++) {
                    if (![values[component] isKindOfClass:NSNumber.class] || fabs([values[component] doubleValue]) > 10000 || (component == 4 && [values[component] doubleValue] <= 0)) { if (error) *error = @"ui_mesh3d needs numeric coordinates and a positive scale up to 10000."; return nil; }
                }
                previousUI = opcode;
            } else if (opcode == VKUIGravity3D) {
                if (sawGravity3D || values.count != 3) { if (error) *error = @"A 3D scene can only have one gravity vector."; return nil; }
                for (id component in values) if (![component isKindOfClass:NSNumber.class] || fabs([component doubleValue]) > 10000) { if (error) *error = @"3D gravity values must be numbers from -10000 to 10000."; return nil; }
                sawGravity3D = YES;
            } else if (opcode == VKUIPhysics3D) {
                NSString *identifier = [values[0] isKindOfClass:NSString.class] ? values[0] : nil;
                VKOpcode type = identifier ? [uiIDTypes[identifier] unsignedCharValue] : 0;
                if (!identifier.length || !opcodeIs3DPrimitive(type) || ![values[1] isKindOfClass:NSNumber.class] || [values[1] doubleValue] < 0 || [values[1] doubleValue] > 10000 || ![values[2] isKindOfClass:NSNumber.class] || [values[2] doubleValue] < 0 || [values[2] doubleValue] > 1) {
                    if (error) *error = @"ui_physics3d needs an object id, mass from 0 to 10000, and restitution from 0 to 1.";
                    return nil;
                }
            } else if (opcode == VKUIVoxel3D || opcode == VKUIVoxelControls3D) {
                NSUInteger numericCount = opcode == VKUIVoxel3D ? 3 : 1;
                BOOL valid = YES;
                for (NSUInteger component = 0; component < numericCount && valid; component++) {
                    id value = values[component];
                    valid = [value isKindOfClass:NSNumber.class] && fabs([value doubleValue]) <= 10000;
                    if (opcode == VKUIVoxel3D && valid) valid = floor([value doubleValue]) == [value doubleValue];
                }
                if (opcode == VKUIVoxelControls3D && valid) valid = [values[0] doubleValue] > 0 && [values[0] doubleValue] <= 10;
                NSString *color = [values.lastObject isKindOfClass:NSString.class] ? values.lastObject : nil;
                NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$" options:0 error:nil];
                valid = valid && color && [hex numberOfMatchesInString:color options:0 range:NSMakeRange(0, color.length)] == 1;
                if (!valid) { if (error) *error = opcode == VKUIVoxel3D ? @"ui_voxel3d needs integer coordinates and a #RRGGBB color." : @"ui_voxel_controls3d needs a step from 0 to 10 and a #RRGGBB color."; return nil; }
            } else if (opcode == VKUIRemove3D) {
                NSString *identifier = [values[0] isKindOfClass:NSString.class] ? values[0] : nil;
                if (!identifier.length || !opcodeIs3DPrimitive([uiIDTypes[identifier] unsignedCharValue])) { if (error) *error = @"ui_remove3d needs an existing 3D object id."; return nil; }
            } else if (opcode == VKUIKeyMove3D) {
                NSString *identifier = [values[0] isKindOfClass:NSString.class] ? values[0] : nil;
                NSString *key = [values[1] isKindOfClass:NSString.class] ? values[1] : nil;
                BOOL valid = identifier.length && opcodeIs3DPrimitive([uiIDTypes[identifier] unsignedCharValue]) && key.length && key.length <= 16;
                for (NSUInteger component = 2; component < 5 && valid; component++) valid = [values[component] isKindOfClass:NSNumber.class] && fabs([values[component] doubleValue]) <= 10000;
                if (!valid) { if (error) *error = @"ui_keymove3d needs a 3D object id, key, and three numeric movement values."; return nil; }
                values[1] = key.lowercaseString;
            } else if (opcode == VKUIVelocity3D) {
                NSString *identifier = [values[0] isKindOfClass:NSString.class] ? values[0] : nil;
                VKOpcode type = identifier ? [uiIDTypes[identifier] unsignedCharValue] : 0;
                if (!identifier.length || !opcodeIs3DPrimitive(type) || ![values[1] isKindOfClass:NSNumber.class] || ![values[2] isKindOfClass:NSNumber.class] || ![values[3] isKindOfClass:NSNumber.class] || fabs([values[1] doubleValue]) > 10000 || fabs([values[2] doubleValue]) > 10000 || fabs([values[3] doubleValue]) > 10000) {
                    if (error) *error = @"ui_velocity3d needs a 3D object id and three velocity components from -10000 to 10000.";
                    return nil;
                }
            } else {
                if (error) *error = @"3D callback actions must be inside ui_frame3d.";
                return nil;
            }
            [ui addObject:@[@(opcode), values]];
            continue;
        }
        if (opcodeIs2DGameInstruction(opcode)) {
            if (!ui.count) { if (error) *error = @"Create a window before adding a 2D game scene."; return nil; }
            NSString *runtimeError = nil;
            NSMutableArray *values = [NSMutableArray array];
            for (NSString *operand in operands) {
                id value = valueOf(operand, variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                [values addObject:value];
            }
            if (opcode == VKUIScene2D) {
                if (sawScene2D) { if (error) *error = @"A window can only have one 2D game scene."; return nil; }
                for (id value in values) if (![value isKindOfClass:NSNumber.class] || [value doubleValue] < 0 || [value doubleValue] > 10000) {
                    if (error) *error = @"2D viewport positions and sizes must be numbers from 0 to 10000.";
                    return nil;
                }
                if ([values[2] doubleValue] < 1 || [values[3] doubleValue] < 1) { if (error) *error = @"2D viewport dimensions must be positive."; return nil; }
                sawScene2D = YES;
            } else if (opcode == VKUIRect2D || opcode == VKUICircle2D) {
                if (!sawScene2D) { if (error) *error = @"Add ui_scene2d before 2D game objects."; return nil; }
                NSString *identifier = [values[0] isKindOfClass:NSString.class] ? values[0] : nil;
                if (!identifier.length || [scene2DIDs containsObject:identifier]) { if (error) *error = @"2D object ids must be unique nonempty text."; return nil; }
                NSUInteger numericCount = opcode == VKUIRect2D ? 4 : 3;
                for (NSUInteger index = 1; index <= numericCount; index++) if (![values[index] isKindOfClass:NSNumber.class] || [values[index] doubleValue] < 0 || [values[index] doubleValue] > 10000) {
                    if (error) *error = @"2D object coordinates and sizes must be numbers from 0 to 10000.";
                    return nil;
                }
                if ([values[3] doubleValue] < 1 || (opcode == VKUIRect2D && [values[4] doubleValue] < 1)) { if (error) *error = @"2D object dimensions must be positive."; return nil; }
                NSString *color = [values.lastObject isKindOfClass:NSString.class] ? values.lastObject : nil;
                NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$" options:0 error:nil];
                if (!color || [hex numberOfMatchesInString:color options:0 range:NSMakeRange(0, color.length)] != 1) { if (error) *error = @"2D object color must use #RRGGBB."; return nil; }
                [scene2DIDs addObject:identifier];
            } else if (opcode == VKUIGravity2D) {
                if (!sawScene2D || sawGravity2D || ![values[0] isKindOfClass:NSNumber.class] || ![values[1] isKindOfClass:NSNumber.class] || fabs([values[0] doubleValue]) > 10000 || fabs([values[1] doubleValue]) > 10000) {
                    if (error) *error = @"ui_gravity2d needs one scene and numeric gravity values from -10000 to 10000.";
                    return nil;
                }
                sawGravity2D = YES;
            } else if (opcode == VKUIPhysics2D) {
                NSString *identifier = [values[0] isKindOfClass:NSString.class] ? values[0] : nil;
                NSNumber *mass = values[1], *restitution = values[2];
                if (!sawScene2D || !identifier.length || ![scene2DIDs containsObject:identifier] ||
                    ![mass isKindOfClass:NSNumber.class] || mass.doubleValue < 0 || mass.doubleValue > 10000 ||
                    ![restitution isKindOfClass:NSNumber.class] || restitution.doubleValue < 0 || restitution.doubleValue > 1) {
                    if (error) *error = @"ui_physics2d needs an object id, mass from 0 to 10000, and restitution from 0 to 1.";
                    return nil;
                }
            } else if (opcode == VKUIVelocity2D || opcode == VKUIKeyMove2D) {
                NSString *identifier = [values[0] isKindOfClass:NSString.class] ? values[0] : nil;
                if (!sawScene2D || !identifier.length || ![scene2DIDs containsObject:identifier]) { if (error) *error = @"2D motion instructions need an existing object id."; return nil; }
                NSUInteger numericStart = opcode == VKUIVelocity2D ? 1 : 2;
                if (opcode == VKUIKeyMove2D && (![values[1] isKindOfClass:NSString.class] || ![values[1] length] || [values[1] length] > 16)) { if (error) *error = @"2D movement keys must be text of 1 to 16 characters."; return nil; }
                for (NSUInteger index = numericStart; index < values.count; index++) if (![values[index] isKindOfClass:NSNumber.class] || fabs([values[index] doubleValue]) > 10000) { if (error) *error = @"2D movement values must be numbers from -10000 to 10000."; return nil; }
                if (opcode == VKUIKeyMove2D) values[1] = [values[1] lowercaseString];
            } else {
                if (error) *error = @"2D callback actions must be inside ui_frame2d.";
                return nil;
            }
            [ui addObject:@[@(opcode), values]];
            if (opcode == VKUIScene2D || opcode == VKUIRect2D || opcode == VKUICircle2D) previousUI = opcode;
            continue;
        }
        NSString *runtimeError = nil;
        if (opcode >= VKUIShortcut && opcode <= VKUIAutoTurn) {
            if (!ui.count) { if (error) *error = @"Create a window before adding an action."; return nil; }
            NSMutableArray *values = [NSMutableArray array];
            for (NSString *operand in operands) {
                id value = valueOf(operand, variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                [values addObject:value];
            }
            if (opcode == VKUIShortcut || opcode == VKUIKeynote) {
                if (![values[0] isKindOfClass:NSString.class] || ![values[0] length] || [values[0] length] > 40) { if (error) *error = @"The shortcut key must be text of 1 to 40 characters."; return nil; }
            }
            if (opcode == VKUIShortcut && ![values[1] isKindOfClass:NSString.class]) { if (error) *error = @"The shortcut message must be text."; return nil; }
            if (opcode == VKUISound && (![values[0] isKindOfClass:NSString.class] || ![values[0] length])) { if (error) *error = @"The sound path must be nonempty text."; return nil; }
            if (opcode == VKUIKeyboard) {
                NSString *instrument = [values[0] isKindOfClass:NSString.class] ? [values[0] lowercaseString] : @"";
                NSNumber *base = values[1];
                if (![@[@"piano", @"guitar"] containsObject:instrument] || ![base isKindOfClass:NSNumber.class] || base.doubleValue < 0 || base.doubleValue > 111 || floor(base.doubleValue) != base.doubleValue) {
                    if (error) *error = @"Use piano or guitar and a base MIDI note from 0 to 111.";
                    return nil;
                }
                values[0] = instrument;
            }
            if (opcode == VKUIAutoTurn) {
                if (previousUI != VKUILabel && previousUI != VKUIButton && previousUI != VKUIInput) { if (error) *error = @"auto_turn must follow a UI control."; return nil; }
                NSNumber *seconds = values[0];
                if (![seconds isKindOfClass:NSNumber.class] || seconds.doubleValue < 0.1 || seconds.doubleValue > 3600) { if (error) *error = @"auto_turn duration must be from 0.1 to 3600 seconds."; return nil; }
            }
            if (opcode == VKUINote || opcode == VKUIKeynote) {
                NSUInteger start = opcode == VKUIKeynote ? 1 : 0;
                NSString *instrument = [values[start] isKindOfClass:NSString.class] ? [values[start] lowercaseString] : @"";
                NSNumber *note = values[start + 1], *duration = values[start + 2];
                if (![@[@"piano", @"guitar"] containsObject:instrument] || ![note isKindOfClass:NSNumber.class] ||
                        note.doubleValue < 0 || note.doubleValue > 127 || floor(note.doubleValue) != note.doubleValue ||
                        ![duration isKindOfClass:NSNumber.class] || duration.doubleValue < 0.05 || duration.doubleValue > 10) {
                    if (error) *error = @"Use piano or guitar, MIDI note 0 to 127, and duration 0.05 to 10 seconds.";
                    return nil;
                }
                values[start] = instrument;
            }
            [ui addObject:@[@(opcode), values]];
            previousUI = opcode;
            continue;
        }
        if (opcode == VKUIColor) {
            if (!ui.count) { if (error) *error = @"Create a window before setting a UI color."; return nil; }
            id value = valueOf(operands[0], variables, &runtimeError);
            if (runtimeError) { if (error) *error = runtimeError; return nil; }
            NSString *color = [value isKindOfClass:[NSString class]] ? value : nil;
            NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$" options:0 error:nil];
            if (!color || [hex numberOfMatchesInString:color options:0 range:NSMakeRange(0, color.length)] != 1) {
                if (error) *error = @"ui_color expects a #RRGGBB color.";
                return nil;
            }
            uiColor = color;
            continue;
        }
        if (opcode >= VKWindow && opcode <= VKUIInput) {
            if ((opcode == VKWindow && ui.count != 0) || (opcode != VKWindow && ui.count == 0)) { if (error) *error = @"A UI must start with exactly one window instruction."; return nil; }
            NSMutableArray *values = [NSMutableArray array];
            for (NSString *operand in operands) {
                id value = valueOf(operand, variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                [values addObject:value];
            }
            NSUInteger numericEnd = opcode == VKUIButton ? values.count - 1 : values.count;
            for (NSUInteger argument = 1; argument < numericEnd; argument++) {
                if (![values[argument] isKindOfClass:[NSNumber class]] || [values[argument] doubleValue] < 0 || [values[argument] doubleValue] > 10000) { if (error) *error = @"UI positions and sizes must be numbers from 0 to 10000."; return nil; }
            }
            NSUInteger sizeStart = opcode == VKWindow ? 1 : 3;
            if ([values[sizeStart] doubleValue] < 1 || [values[sizeStart + 1] doubleValue] < 1) { if (error) *error = @"UI widths and heights must be positive."; return nil; }
            if (opcode != VKWindow) [values addObject:uiColor];
            [ui addObject:@[@(opcode), values]];
            previousUI = opcode;
            continue;
        }
        if (opcode == VKOut) {
            id value = valueOf(operands[0], variables, &runtimeError);
            if (runtimeError) { if (error) *error = runtimeError; return nil; }
            [output appendFormat:@"%@\n", value];
            if (output.length > 100000) { if (error) *error = @"Output limit exceeded."; return nil; }
            continue;
        }
        if (opcode == VKTerminalKeywords || opcode == VKTerminalEcho || opcode == VKTerminalRun) {
            NSString *terminalOutput = nil;
            if (opcode == VKTerminalKeywords) terminalOutput = @"terminal_run help|date|pwd; terminal_echo value; terminal_keywords";
            else {
                id value = valueOf(operands[0], variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                if (opcode == VKTerminalEcho) terminalOutput = [value description];
                else if (![value isKindOfClass:NSString.class]) { if (error) *error = @"terminal_run requires a text keyword. Use help, date, or pwd."; return nil; }
                else {
                    NSString *keyword = [value lowercaseString];
                    if ([keyword isEqualToString:@"help"]) terminalOutput = @"Available terminal_run keywords: date, help, pwd. Use terminal_echo to print text.";
                    else if ([keyword isEqualToString:@"date"]) {
                        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
                        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
                        formatter.dateFormat = @"yyyy-MM-dd";
                        terminalOutput = [formatter stringFromDate:[NSDate date]];
                    } else if ([keyword isEqualToString:@"pwd"]) terminalOutput = NSFileManager.defaultManager.currentDirectoryPath;
                    else { if (error) *error = @"Unsupported terminal keyword. Use help, date, or pwd."; return nil; }
                }
            }
            [output appendFormat:@"%@\n", terminalOutput ?: @""];
            if (output.length > 100000) { if (error) *error = @"Output limit exceeded."; return nil; }
            continue;
        }
        if (opcode == VKCite) {
            NSMutableArray *values = [NSMutableArray arrayWithCapacity:4];
            for (NSString *operand in operands) {
                id value = valueOf(operand, variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                [values addObject:value];
            }
                BOOL yearIsText = [values[2] isKindOfClass:NSString.class];
                BOOL yearIsNumber = [values[2] isKindOfClass:NSNumber.class];
                if (![values[0] isKindOfClass:NSString.class] || ![values[0] length] ||
                    ![values[1] isKindOfClass:NSString.class] || ![values[1] length] ||
                    (!yearIsText && !yearIsNumber) || ![[values[2] description] length] ||
                    ![values[3] isKindOfClass:NSString.class] || ![values[3] length]) {
                if (error) *error = @"cite expects nonempty author, title, year, and URL fields.";
                return nil;
            }
            [output appendFormat:@"%@. (%@). %@. %@\n", values[0], values[2], values[1], values[3]];
            if (output.length > 100000) { if (error) *error = @"Output limit exceeded."; return nil; }
            continue;
        }
        if (opcode == VKCodecList) {
            [output appendFormat:@"%s\n", vkc_format_list()];
            if (output.length > 100000) { if (error) *error = @"Output limit exceeded."; return nil; }
            continue;
        }
        if (opcode == VKAIClear) {
            vk_ai_clear(&aiState->context);
            continue;
        }
        if (opcode == VKAIConfigure || opcode == VKTrain) {
            id first = valueOf(operands[0], variables, &runtimeError);
            id second = valueOf(operands[1], variables, &runtimeError);
            if (runtimeError) { if (error) *error = runtimeError; return nil; }
            if (![first isKindOfClass:NSString.class] || ![second isKindOfClass:NSString.class]) {
                if (error) *error = @"AI command operands must be text.";
                return nil;
            }
            char message[1024] = {0};
            int ok = opcode == VKAIConfigure
                ? vk_ai_configure(&aiState->context, [first UTF8String], [second UTF8String], message, sizeof(message))
                : vk_ai_train(&aiState->context, [first UTF8String], [second UTF8String], message, sizeof(message));
            if (!ok) { if (error) *error = [NSString stringWithUTF8String:message]; return nil; }
            continue;
        }
        NSString *name = operands[0];
        NSCharacterSet *invalidName = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"] invertedSet];
        if (!name.length || [name rangeOfCharacterFromSet:invalidName].location != NSNotFound || [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[name characterAtIndex:0]]) { if (error) *error = @"Invalid variable name."; return nil; }
        id original = variables[name];
        id value = operands.count > 1 ? valueOf(operands[1], variables, &runtimeError) : nil;
        if (runtimeError) { if (error) *error = runtimeError; return nil; }
        if (opcode == VKText) { variables[name] = [value description]; continue; }
        if (opcode == VKSet) { variables[name] = value; continue; }
        if (opcode == VKAIAsk) {
            if (![value isKindOfClass:NSString.class]) { if (error) *error = @"ai_ask requires a text question."; return nil; }
            char message[1024] = {0};
            char *answer = vk_ai_ask(&aiState->context, [value UTF8String], message, sizeof(message));
            if (!answer) { if (error) *error = [NSString stringWithUTF8String:message]; return nil; }
            NSString *text = [NSString stringWithUTF8String:answer];
            free(answer);
            if (!text) { if (error) *error = @"AI returned invalid UTF-8 text."; return nil; }
            variables[name] = text;
            continue;
        }
        if (!original) { if (error) *error = [NSString stringWithFormat:@"Unknown variable $%@.", name]; return nil; }
        if (opcode == VKIsNumber) { variables[name] = @([original isKindOfClass:[NSNumber class]]); continue; }
        if (opcode == VKIsText) { variables[name] = @([original isKindOfClass:[NSString class]]); continue; }
        if (opcode == VKEmpty) { variables[name] = @([[original description] length] == 0); continue; }
        if (opcode == VKConcat) { variables[name] = [[original description] stringByAppendingString:[value description]]; continue; }
        if (opcode == VKEncode || opcode == VKDecode) {
            NSData *input = [[original description] dataUsingEncoding:NSUTF8StringEncoding];
            vkc_buf transformed = {0};
            char message[1024] = {0};
            if (!vkc_transform(opcode == VKEncode, [[value description] UTF8String], input.bytes, input.length, 1, &transformed, message, sizeof(message))) {
                if (error) *error = [NSString stringWithUTF8String:message];
                return nil;
            }
            NSString *result = [[NSString alloc] initWithBytes:transformed.p length:transformed.n encoding:NSUTF8StringEncoding];
            free(transformed.p);
            if (!result) { if (error) *error = @"The result is not valid UTF-8 text."; return nil; }
            variables[name] = result;
            continue;
        }
        if (opcode == VKUpper) { variables[name] = [[original description] uppercaseString]; continue; }
        if (opcode == VKLower) { variables[name] = [[original description] lowercaseString]; continue; }
        if (opcode == VKLength) { variables[name] = @([[original description] length]); continue; }
        if (opcode == VKTrim) { variables[name] = [[original description] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; continue; }
        if (opcode == VKContains) { variables[name] = @([[original description] containsString:[value description]]); continue; }
        if (opcode == VKStartsWith) { variables[name] = @([[original description] hasPrefix:[value description]]); continue; }
        if (opcode == VKEndsWith) { variables[name] = @([[original description] hasSuffix:[value description]]); continue; }
        if (opcode == VKReplace) {
            id replacement = valueOf(operands[2], variables, &runtimeError);
            if (runtimeError) { if (error) *error = runtimeError; return nil; }
            if (![[value description] length]) { if (error) *error = @"replace requires a non-empty search string."; return nil; }
            variables[name] = [[original description] stringByReplacingOccurrencesOfString:[value description] withString:[replacement description]];
            continue;
        }
        if (opcode == VKEqual || opcode == VKNotEqual) { variables[name] = @((opcode == VKEqual) == [original isEqual:value]); continue; }
        if (![original isKindOfClass:[NSNumber class]] || (value && ![value isKindOfClass:[NSNumber class]])) { if (error) *error = @"Numeric operation requires numbers."; return nil; }
        double left = [original doubleValue], right = [value doubleValue], result = 0;
        switch (opcode) {
            case VKAdd: result = left + right; break;
            case VKSubtract: result = left - right; break;
            case VKMultiply: result = left * right; break;
            case VKDivide: if (right == 0) { if (error) *error = @"Division by zero."; return nil; } result = left / right; break;
            case VKModulo: if (right == 0) { if (error) *error = @"Division by zero."; return nil; } result = fmod(left, right); break;
            case VKPower: result = pow(left, right); break;
            case VKLess: result = left < right; break;
            case VKLessEqual: result = left <= right; break;
            case VKGreater: result = left > right; break;
            case VKGreaterEqual: result = left >= right; break;
            case VKNot: result = !left; break;
            case VKAnd: result = left && right; break;
            case VKOr: result = left || right; break;
            case VKNegate: result = -left; break;
            case VKAbs: result = fabs(left); break;
            case VKRound: result = round(left); break;
            case VKFloor: result = floor(left); break;
            case VKCeil: result = ceil(left); break;
            case VKSqrt: result = sqrt(left); break;
            case VKMin: result = fmin(left, right); break;
            case VKMax: result = fmax(left, right); break;
            case VKSin: result = sin(left); break;
            case VKCos: result = cos(left); break;
            case VKTan: result = tan(left); break;
            case VKAsin: result = asin(left); break;
            case VKAcos: result = acos(left); break;
            case VKAtan: result = atan(left); break;
            case VKLog: result = log(left); break;
            case VKLog10: result = log10(left); break;
            case VKExp: result = exp(left); break;
            case VKSign: result = (left > 0) - (left < 0); break;
            case VKTruncate: result = trunc(left); break;
            default: if (error) *error = @"Invalid instruction."; return nil;
        }
        if (!isfinite(result)) { if (error) *error = @"The result is not a finite number."; return nil; }
        variables[name] = @(result);
    }
    return output;
}

+ (NSArray *)runFrameCallback:(NSArray *)callback variables:(NSMutableDictionary *)variables error:(NSString **)error {
    NSMutableDictionary<NSString *, NSNumber *> *labels = [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < callback.count; index++) {
        VKOpcode opcode = [callback[index][0] unsignedCharValue];
        if (opcode == VKLabel) {
            NSString *name = callback[index][1][0];
            if (labels[name]) { if (error) *error = [NSString stringWithFormat:@"Duplicate callback label %@.", name]; return nil; }
            labels[name] = @(index);
        }
    }
    NSMutableArray *actions = [NSMutableArray array];
    for (NSUInteger index = 0, steps = 0; index < callback.count; index++) {
        if (++steps > 1000) { if (error) *error = @"Frame callback instruction limit exceeded."; return nil; }
        VKOpcode opcode = [callback[index][0] unsignedCharValue];
        NSArray *operands = callback[index][1];
        if (opcode == VKLabel) continue;
        if (opcode == VKJump || opcode == VKIf || opcode == VKUnless) {
            NSString *runtimeError = nil;
            id condition = opcode == VKJump ? @YES : valueOf(operands[0], variables, &runtimeError);
            if (runtimeError) { if (error) *error = runtimeError; return nil; }
            BOOL truth = [condition isKindOfClass:NSNumber.class] ? [condition doubleValue] != 0 : [[condition description] length] != 0;
            BOOL take = opcode == VKJump || (opcode == VKIf ? truth : !truth);
            if (take) {
                NSString *target = operands[opcode == VKJump ? 0 : 1];
                NSNumber *destination = labels[target];
                if (!destination) { if (error) *error = [NSString stringWithFormat:@"Unknown callback label %@.", target]; return nil; }
                index = destination.unsignedIntegerValue;
            }
            continue;
        }
        if (opcode == VKUIMove2D || opcode == VKUIForce2D || opcode == VKUISetVelocity2D ||
            opcode == VKUIMove3D || opcode == VKUIForce3D || opcode == VKUISetVelocity3D || opcode == VKUIRemove3D) {
            BOOL action3D = opcode == VKUIMove3D || opcode == VKUIForce3D || opcode == VKUISetVelocity3D || opcode == VKUIRemove3D;
            NSUInteger operandCount = opcode == VKUIRemove3D ? 1 : action3D ? 4 : 3;
            NSMutableArray *values = [NSMutableArray arrayWithCapacity:operandCount];
            NSString *runtimeError = nil;
            for (NSString *operand in operands) {
                id value = valueOf(operand, variables, &runtimeError);
                if (runtimeError) { if (error) *error = runtimeError; return nil; }
                [values addObject:value];
            }
            BOOL numeric = values.count == operandCount;
            for (NSUInteger valueIndex = 1; numeric && valueIndex < operandCount; valueIndex++) numeric = [values[valueIndex] isKindOfClass:NSNumber.class];
            if (![values[0] isKindOfClass:NSString.class] || ![values[0] length] || !numeric) {
                if (error) *error = action3D ? @"3D callback actions need an object id and three numeric values." : @"2D callback actions need an object id and two numeric values.";
                return nil;
            }
            [actions addObject:@[@(opcode), values]];
            continue;
        }
        NSString *name = operands[0];
        id original = variables[name];
        NSString *runtimeError = nil;
        id value = operands.count > 1 ? valueOf(operands[1], variables, &runtimeError) : nil;
        if (runtimeError) { if (error) *error = runtimeError; return nil; }
        if (opcode == VKText) { variables[name] = [value description]; continue; }
        if (opcode == VKSet) { variables[name] = value; continue; }
        if (!original) { if (error) *error = [NSString stringWithFormat:@"Unknown variable $%@.", name]; return nil; }
        if (opcode == VKEqual || opcode == VKNotEqual) { variables[name] = @((opcode == VKEqual) == [original isEqual:value]); continue; }
        if (![original isKindOfClass:NSNumber.class] || (value && ![value isKindOfClass:NSNumber.class])) {
            if (error) *error = @"Numeric callback operations require numbers.";
            return nil;
        }
        double left = [original doubleValue], right = [value doubleValue], result = 0;
        switch (opcode) {
            case VKAdd: result = left + right; break;
            case VKSubtract: result = left - right; break;
            case VKMultiply: result = left * right; break;
            case VKDivide: if (!right) { if (error) *error = @"Division by zero in frame callback."; return nil; } result = left / right; break;
            case VKModulo: if (!right) { if (error) *error = @"Division by zero in frame callback."; return nil; } result = fmod(left, right); break;
            case VKPower: result = pow(left, right); break;
            case VKMin: result = fmin(left, right); break;
            case VKMax: result = fmax(left, right); break;
            case VKLess: result = left < right; break;
            case VKLessEqual: result = left <= right; break;
            case VKGreater: result = left > right; break;
            case VKGreaterEqual: result = left >= right; break;
            case VKNot: result = !left; break;
            case VKAnd: result = left && right; break;
            case VKOr: result = left || right; break;
            case VKNegate: result = -left; break;
            case VKAbs: result = fabs(left); break;
            case VKRound: result = round(left); break;
            case VKFloor: result = floor(left); break;
            case VKCeil: result = ceil(left); break;
            case VKSqrt: result = sqrt(left); break;
            case VKSin: result = sin(left); break;
            case VKCos: result = cos(left); break;
            case VKTan: result = tan(left); break;
            case VKAsin: result = asin(left); break;
            case VKAcos: result = acos(left); break;
            case VKAtan: result = atan(left); break;
            case VKLog: result = log(left); break;
            case VKLog10: result = log10(left); break;
            case VKExp: result = exp(left); break;
            case VKSign: result = (left > 0) - (left < 0); break;
            case VKTruncate: result = trunc(left); break;
            default: if (error) *error = @"Unsupported frame callback instruction."; return nil;
        }
        if (!isfinite(result)) { if (error) *error = @"Frame callback produced a non-finite result."; return nil; }
        variables[name] = @(result);
    }
    return actions;
}
@end