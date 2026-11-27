/* Portable Vektkove compiler and bytecode runner (no UI instructions).
 * Compiles .vk source to VK01 bytecode identical to the macOS engine and runs it.
 * Usage: vkport run file.vk|file.vkb | compile file.vk out.vkb | keywords-count
 */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sodium.h>
#include "vkcodec.h"
#include "vkai.h"
#define VK_VERSION "1.4.2"
#ifdef _WIN32
#define strcasecmp _stricmp
#else
#include <strings.h>
#endif

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <direct.h>
#define getcwd _getcwd
typedef SOCKET VkSocket;
#define VK_INVALID_SOCKET INVALID_SOCKET
#else
#include <netdb.h>
#include <pthread.h>
#include <signal.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <termios.h>
#include <unistd.h>
typedef int VkSocket;
#define VK_INVALID_SOCKET (-1)
#endif

enum {
    OP_TEXT = 1, OP_SET, OP_ADD, OP_SUB, OP_MUL, OP_DIV, OP_MOD, OP_POW, OP_CONCAT, OP_UPPER, OP_LOWER,
    OP_LENGTH, OP_EQ, OP_NE, OP_LT, OP_LE, OP_GT, OP_GE, OP_NOT, OP_AND, OP_OR, OP_NEG, OP_ABS, OP_ROUND,
    OP_FLOOR, OP_CEIL, OP_SQRT, OP_OUT, OP_HALT, OP_LABEL, OP_JUMP, OP_IF, OP_UNLESS,
    OP_WINDOW, OP_UILABEL, OP_UIBUTTON, OP_UIINPUT,
    OP_MIN, OP_MAX, OP_SIN, OP_COS, OP_TAN, OP_ASIN, OP_ACOS, OP_ATAN, OP_LOG, OP_LOG10, OP_EXP, OP_SIGN,
    OP_TRUNC, OP_ISNUM, OP_ISTEXT, OP_EMPTY, OP_TRIM, OP_CONTAINS, OP_STARTS, OP_ENDS, OP_REPLACE, OP_UICOLOR,
    OP_UISHORTCUT, OP_UINOTE, OP_UIKEYNOTE, OP_UISOUND, OP_UIKEYBOARD, OP_UIAUTOTURN,
    OP_IMPORT, OP_UIID, OP_UIBIND, OP_UISCENE3D, OP_UICAMERA3D, OP_UILIGHT3D,
    OP_UIBOX3D, OP_UISPHERE3D, OP_UICYLINDER3D, OP_UICONE3D, OP_UITORUS3D, OP_UIPLANE3D, OP_UISPIN3D,
    OP_TERMINALRUN, OP_TERMINALECHO, OP_TERMINALKEYWORDS, OP_CITE,
    OP_UISCENE2D, OP_UIRECT2D, OP_UICIRCLE2D, OP_UIVELOCITY2D, OP_UIKEYMOVE2D,
    OP_SERVERSCRIPT, OP_LOCALSCRIPT, OP_NETLISTEN, OP_NETCONNECT, OP_NETSEND, OP_NETRECEIVE, OP_NETCLOSE,
    OP_NETLISTENMULTI, OP_NETSENDTO, OP_NETRECEIVEFROM, OP_NETBROADCAST,
    OP_UIPHYSICS2D, OP_UIGRAVITY2D, OP_UIFRAME2D, OP_UIENDFRAME2D, OP_UIMOVE2D, OP_UIFORCE2D, OP_UISETVELOCITY2D, OP_UIFRAMEDATA,
    OP_UIPHYSICS3D, OP_UIGRAVITY3D, OP_UIFRAME3D, OP_UIENDFRAME3D, OP_UIMOVE3D, OP_UIFORCE3D, OP_UISETVELOCITY3D, OP_UIVELOCITY3D,
    OP_UIMESH3D,
    OP_ENCODE, OP_DECODE, OP_CODECLIST,
    OP_AICONFIGURE, OP_TRAIN, OP_AICLEAR, OP_AIASK,
    OP_UIKEYMOVE3D, OP_UIVOXEL3D, OP_UIVOXELCONTROLS3D, OP_UIREMOVE3D
};

typedef struct { const char *aliases; int opcode; int arity; } Definition;

static const Definition definitions[] = {
    {"text string_text declare_text", OP_TEXT, 2}, {"set assign store", OP_SET, 2},
    {"add", OP_ADD, 2}, {"subtract sub minus", OP_SUB, 2}, {"multiply mul times", OP_MUL, 2},
    {"divide div quotient", OP_DIV, 2}, {"modulo mod remainder", OP_MOD, 2}, {"power pow exponent", OP_POW, 2},
    {"concat append join", OP_CONCAT, 2}, {"upper uppercase capitalize", OP_UPPER, 1},
    {"lower lowercase decapitalize", OP_LOWER, 1}, {"length len size", OP_LENGTH, 1},
    {"equal equals eq", OP_EQ, 2}, {"not_equal differs neq", OP_NE, 2}, {"less below lt", OP_LT, 2},
    {"less_equal at_most lte", OP_LE, 2}, {"greater above gt", OP_GT, 2},
    {"greater_equal at_least gte", OP_GE, 2}, {"not invert negate_boolean", OP_NOT, 1},
    {"and both logical_and", OP_AND, 2}, {"or either logical_or", OP_OR, 2},
    {"negate negative negate_number", OP_NEG, 1}, {"abs absolute magnitude", OP_ABS, 1},
    {"round nearest round_number", OP_ROUND, 1}, {"floor round_down downward", OP_FLOOR, 1},
    {"ceil round_up ceiling", OP_CEIL, 1}, {"sqrt square_root root", OP_SQRT, 1},
    {"out print output", OP_OUT, 1}, {"halt stop end", OP_HALT, 0}, {"label mark anchor", OP_LABEL, 1},
    {"jump goto branch", OP_JUMP, 1}, {"if when branch_if", OP_IF, 2},
    {"unless when_not branch_unless", OP_UNLESS, 2},
    {"window ui_window make_window", OP_WINDOW, 3}, {"ui_label ui_text make_label", OP_UILABEL, 5},
    {"ui_button ui_action make_button", OP_UIBUTTON, 6}, {"ui_input ui_field make_input", OP_UIINPUT, 5},
    {"min minimum smaller", OP_MIN, 2}, {"max maximum larger", OP_MAX, 2},
    {"sin sine sine_radians", OP_SIN, 1}, {"cos cosine cosine_radians", OP_COS, 1},
    {"tan tangent tangent_radians", OP_TAN, 1}, {"asin arcsine inverse_sine", OP_ASIN, 1},
    {"acos arccosine inverse_cosine", OP_ACOS, 1}, {"atan arctangent inverse_tangent", OP_ATAN, 1},
    {"log natural_log ln", OP_LOG, 1}, {"log10 common_log decimal_log", OP_LOG10, 1},
    {"exp exponential e_power", OP_EXP, 1}, {"sign signum number_sign", OP_SIGN, 1},
    {"truncate trunc integer_part", OP_TRUNC, 1}, {"is_number numeric is_numeric", OP_ISNUM, 1},
    {"is_text textual is_string", OP_ISTEXT, 1}, {"empty is_empty text_empty", OP_EMPTY, 1},
    {"trim strip trim_whitespace", OP_TRIM, 1}, {"contains includes text_contains", OP_CONTAINS, 2},
    {"starts_with begins_with has_prefix", OP_STARTS, 2}, {"ends_with finishes_with has_suffix", OP_ENDS, 2},
    {"replace replace_all text_replace", OP_REPLACE, 3}, {"ui_color ui_colour set_ui_color", OP_UICOLOR, 1},
    {"ui_shortcut shortcut ui_key", OP_UISHORTCUT, 2}, {"ui_note play_note note", OP_UINOTE, 3},
    {"ui_keynote key_note instrument_key", OP_UIKEYNOTE, 4}, {"ui_sound play_sound sound_file", OP_UISOUND, 1},
    {"ui_keyboard instrument_keyboard keyboard", OP_UIKEYBOARD, 2}, {"ui_auto_turn auto_turn ui_rotate", OP_UIAUTOTURN, 1},
    {"import", OP_IMPORT, 1}, {"ui_id", OP_UIID, 1}, {"ui_bind", OP_UIBIND, 2},
    {"ui_scene3d scene3d make_scene3d", OP_UISCENE3D, 4}, {"ui_camera3d camera3d scene_camera", OP_UICAMERA3D, 3},
    {"ui_light3d light3d scene_light", OP_UILIGHT3D, 4}, {"ui_box3d box3d cube3d ui_cube", OP_UIBOX3D, 7},
    {"ui_sphere3d sphere3d ui_sphere", OP_UISPHERE3D, 5}, {"ui_cylinder3d cylinder3d ui_cylinder", OP_UICYLINDER3D, 6},
    {"ui_cone3d cone3d ui_cone", OP_UICONE3D, 7}, {"ui_torus3d torus3d ui_torus", OP_UITORUS3D, 6},
    {"ui_plane3d plane3d ui_plane", OP_UIPLANE3D, 6}, {"ui_spin3d spin3d spin_object", OP_UISPIN3D, 2},
    {"terminal_run run_terminal terminal_command", OP_TERMINALRUN, 1},
    {"terminal_echo echo_terminal", OP_TERMINALECHO, 1},
    {"terminal_keywords terminal_help", OP_TERMINALKEYWORDS, 0},
    {"cite citation reference source_cite", OP_CITE, 4},
    {"ui_scene2d scene2d game2d", OP_UISCENE2D, 4},
    {"ui_rect2d rect2d game_rect", OP_UIRECT2D, 6},
    {"ui_circle2d circle2d game_circle", OP_UICIRCLE2D, 5},
    {"ui_velocity2d velocity2d game_velocity", OP_UIVELOCITY2D, 3},
    {"ui_keymove2d keymove2d game_keymove", OP_UIKEYMOVE2D, 4},
    {"server_script serverscript", OP_SERVERSCRIPT, 0}, {"local_script localscript", OP_LOCALSCRIPT, 0},
    {"net_listen network_listen", OP_NETLISTEN, 2}, {"net_connect connect_ip network_connect", OP_NETCONNECT, 2},
    {"net_send network_send", OP_NETSEND, 1}, {"net_receive network_receive", OP_NETRECEIVE, 1}, {"net_close network_close", OP_NETCLOSE, 0},
    {"net_listen_multi network_listen_multi", OP_NETLISTENMULTI, 3}, {"net_send_to network_send_to", OP_NETSENDTO, 2},
    {"net_receive_from network_receive_from", OP_NETRECEIVEFROM, 2}, {"net_broadcast network_broadcast", OP_NETBROADCAST, 1},
    {"ui_physics2d physics2d game_physics", OP_UIPHYSICS2D, 3}, {"ui_gravity2d gravity2d game_gravity", OP_UIGRAVITY2D, 2},
    {"ui_frame2d frame2d game_update", OP_UIFRAME2D, 0}, {"ui_end_frame2d end_frame2d game_end_update", OP_UIENDFRAME2D, 0},
    {"ui_move2d move2d game_move", OP_UIMOVE2D, 3}, {"ui_force2d force2d game_force", OP_UIFORCE2D, 3},
    {"ui_set_velocity2d set_velocity2d game_set_velocity", OP_UISETVELOCITY2D, 3},
    {"ui_physics3d physics3d game_physics3d", OP_UIPHYSICS3D, 3}, {"ui_gravity3d gravity3d game_gravity3d", OP_UIGRAVITY3D, 3},
    {"ui_frame3d frame3d game_update3d", OP_UIFRAME3D, 0}, {"ui_end_frame3d end_frame3d game_end_update3d", OP_UIENDFRAME3D, 0},
    {"ui_move3d move3d game_move3d", OP_UIMOVE3D, 4}, {"ui_force3d force3d game_force3d", OP_UIFORCE3D, 4},
    {"ui_set_velocity3d set_velocity3d game_set_velocity3d", OP_UISETVELOCITY3D, 4},
    {"ui_velocity3d velocity3d game_velocity3d", OP_UIVELOCITY3D, 4}, {"ui_mesh3d", OP_UIMESH3D, 6},
    {"encode encode_text text_encode", OP_ENCODE, 2}, {"decode decode_text text_decode", OP_DECODE, 2},
    {"codec_list list_codecs codecs", OP_CODECLIST, 0},
    {"ai_config ai_configure ai_setup", OP_AICONFIGURE, 2}, {"train ai_train ai_learn ai_remember", OP_TRAIN, 2},
    {"ai_clear clear_knowledge ai_forget", OP_AICLEAR, 0}, {"ai_ask ask_ai ai_query", OP_AIASK, 2},
    {"ui_keymove3d keymove3d game_keymove3d", OP_UIKEYMOVE3D, 5},
    {"ui_voxel3d", OP_UIVOXEL3D, 4}, {"ui_voxel_controls3d", OP_UIVOXELCONTROLS3D, 2},
    {"ui_remove3d", OP_UIREMOVE3D, 1}
};
#define DEFINITION_COUNT (sizeof(definitions) / sizeof(definitions[0]))

typedef struct { int opcode; int arity; const char *literal; char literal_buffer[8]; } Command;

static int lookup(const char *word, Command *command) {
    static const char *prefixes[] = {"", "vk_", "do_", "op_"};
    for (size_t index = 0; index < DEFINITION_COUNT; index++) {
        const char *cursor = definitions[index].aliases;
        while (*cursor) {
            const char *end = strchr(cursor, ' ');
            size_t length = end ? (size_t)(end - cursor) : strlen(cursor);
            size_t prefix_count = (definitions[index].opcode == OP_ADD || definitions[index].opcode == OP_IMPORT) ? 1 : 4;
            for (size_t prefix = 0; prefix < prefix_count; prefix++) {
                size_t plen = strlen(prefixes[prefix]);
                if (strlen(word) == plen + length && !strncmp(word, prefixes[prefix], plen) && !strncmp(word + plen, cursor, length)) {
                    command->opcode = definitions[index].opcode;
                    command->arity = definitions[index].arity;
                    command->literal = NULL;
                    return 1;
                }
            }
            cursor += length + (end ? 1 : 0);
        }
    }
    return 0;
}

/* ---------- growable buffers ---------- */
typedef struct { unsigned char *data; size_t size, capacity; } Buffer;
static int buffer_append(Buffer *buffer, const void *bytes, size_t length) {
    if (buffer->size + length > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 256;
        while (capacity < buffer->size + length) capacity *= 2;
        unsigned char *grown = realloc(buffer->data, capacity);
        if (!grown) return 0;
        buffer->data = grown; buffer->capacity = capacity;
    }
    if (length) memcpy(buffer->data + buffer->size, bytes, length);
    buffer->size += length;
    return 1;
}
static int append_operand(Buffer *buffer, const char *text, size_t length) {
    unsigned char header[4] = {(unsigned char)(length >> 24), (unsigned char)(length >> 16), (unsigned char)(length >> 8), (unsigned char)length};
    return buffer_append(buffer, header, 4) && buffer_append(buffer, text, length);
}

/* ---------- compiler ---------- */
static int tokenize(const char *line, size_t length, char ***tokens, size_t *token_count, const char **problem) {
    char **list = NULL; size_t count = 0, position = 0;
    *problem = NULL;
    while (position < length) {
        char character = line[position];
        if (character == ' ' || character == '\t' || character == '\v' || character == '\f') { position++; continue; }
        if (character == '#') break;
        size_t start = position;
        if (character == '"') {
            position++;
            int escaped = 0, closed = 0;
            while (position < length) {
                character = line[position++];
                if (!escaped && character == '"') { closed = 1; break; }
                escaped = (!escaped && character == '\\');
            }
            if (!closed) { *problem = "Unterminated string."; goto fail; }
        } else {
            while (position < length && line[position] != ' ' && line[position] != '\t' && line[position] != '\v' && line[position] != '\f' && line[position] != '#') position++;
        }
        char **grown = realloc(list, (count + 1) * sizeof(char *));
        if (!grown) { *problem = "Out of memory."; goto fail; }
        list = grown;
        list[count] = malloc(position - start + 1);
        if (!list[count]) { *problem = "Out of memory."; goto fail; }
        memcpy(list[count], line + start, position - start);
        list[count][position - start] = '\0';
        count++;
    }
    *tokens = list; *token_count = count;
    return 1;
fail:
    for (size_t index = 0; index < count; index++) free(list[index]);
    free(list);
    return 0;
}

static void free_tokens(char **tokens, size_t count) {
    for (size_t index = 0; index < count; index++) free(tokens[index]);
    free(tokens);
}

static int compile_source(const char *source, size_t length, Buffer *out, char *message, size_t message_size) {
    out->size = 0;
    buffer_append(out, "VK01", 4);
    size_t line_start = 0, line_number = 1;
    int imported_ui = 0, saw_ui = 0, declared_role = 0, saw_instruction = 0;
    for (size_t index = 0; index <= length; index++) {
        if (index < length && source[index] != '\n' && source[index] != '\r') continue;
        size_t line_length = index - line_start;
        char **tokens = NULL; size_t count = 0; const char *problem = NULL;
        if (!tokenize(source + line_start, line_length, &tokens, &count, &problem)) {
            snprintf(message, message_size, "Line %zu: %s", line_number, problem);
            return 0;
        }
        if (count) {
            char lowered[256]; size_t word_length = strlen(tokens[0]);
            Command command;
            if (word_length >= sizeof(lowered)) lowered[0] = '\0';
            else { for (size_t k = 0; k <= word_length; k++) lowered[k] = (char)tolower((unsigned char)tokens[0][k]); }
            if (!lookup(lowered, &command) || count != (size_t)command.arity + 1) {
                snprintf(message, message_size, "Line %zu: Unknown command or wrong number of operands.", line_number);
                free_tokens(tokens, count);
                return 0;
            }
            if (command.opcode == OP_SERVERSCRIPT || command.opcode == OP_LOCALSCRIPT) {
                if (declared_role || saw_instruction) { snprintf(message, message_size, "Line %zu: Declare one script role as the first instruction.", line_number); free_tokens(tokens, count); return 0; }
                declared_role = 1;
            } else saw_instruction = 1;
            if (command.opcode == OP_IMPORT) {
                if (strcmp(tokens[1], "ui")) snprintf(message, message_size, "Line %zu: Only import ui is supported.", line_number);
                else if (imported_ui) snprintf(message, message_size, "Line %zu: UI is already imported.", line_number);
                else if (saw_ui) snprintf(message, message_size, "Line %zu: import ui must come before UI instructions.", line_number);
                else imported_ui = 1;
                if (message[0]) { free_tokens(tokens, count); return 0; }
            } else if ((command.opcode >= OP_WINDOW && command.opcode <= OP_UIINPUT) ||
                       (command.opcode >= OP_UICOLOR && command.opcode <= OP_UIAUTOTURN) ||
                       command.opcode == OP_UIID || command.opcode == OP_UIBIND ||
                       (command.opcode >= OP_UISCENE3D && command.opcode <= OP_UISPIN3D) ||
                       (command.opcode >= OP_UISCENE2D && command.opcode <= OP_UIKEYMOVE2D) ||
                       (command.opcode >= OP_UIPHYSICS2D && command.opcode <= OP_UIMESH3D) || (command.opcode >= OP_UIKEYMOVE3D && command.opcode <= OP_UIREMOVE3D)) {
                saw_ui = 1;
                if (!imported_ui) {
                    snprintf(message, message_size, "Line %zu: Add import ui before using UI instructions.", line_number);
                    free_tokens(tokens, count);
                    return 0;
                }
            }
            unsigned char header[2] = {(unsigned char)command.opcode, (unsigned char)(count - 1 + (command.literal ? 1 : 0))};
            buffer_append(out, header, 2);
            for (size_t operand = 1; operand < count; operand++) append_operand(out, tokens[operand], strlen(tokens[operand]));
            if (command.literal) append_operand(out, command.literal, strlen(command.literal));
        }
        free_tokens(tokens, count);
        if (index < length && source[index] == '\r' && index + 1 < length && source[index + 1] == '\n') index++;
        line_start = index + 1;
        line_number++;
    }
    return 1;
}

/* ---------- runtime ---------- */
typedef struct { int is_number; double number; char *text; } Value;
typedef struct { char *name; Value value; } Variable;
typedef struct { int opcode; size_t count; char **operands; } Instruction;
typedef struct { Variable *items; size_t count; } Variables;

static void value_clear(Value *value) { free(value->text); value->text = NULL; value->is_number = 0; }
static char *copy_text(const char *text, size_t length) {
    char *copy = malloc(length + 1);
    if (copy) { memcpy(copy, text, length); copy[length] = '\0'; }
    return copy;
}

static char *format_number(double number) {
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%.16g", number);
    return copy_text(buffer, strlen(buffer));
}
static char *value_text(const Value *value) { return value->is_number ? format_number(value->number) : copy_text(value->text ? value->text : "", value->text ? strlen(value->text) : 0); }

static int is_number_token(const char *token, double *number) {
    /* Mirrors NSScanner scanDouble: decimal only, optional sign, no hex/inf/nan. */
    const char *cursor = token;
    if (*cursor == '+' || *cursor == '-') cursor++;
    if (!isdigit((unsigned char)*cursor) && !(*cursor == '.' && isdigit((unsigned char)cursor[1]))) return 0;
    while (isdigit((unsigned char)*cursor)) cursor++;
    if (*cursor == '.') { cursor++; while (isdigit((unsigned char)*cursor)) cursor++; }
    if (*cursor == 'e' || *cursor == 'E') {
        const char *exponent = cursor + 1;
        if (*exponent == '+' || *exponent == '-') exponent++;
        if (isdigit((unsigned char)*exponent)) { while (isdigit((unsigned char)*exponent)) exponent++; cursor = exponent; }
    }
    if (*cursor != '\0') return 0;
    errno = 0;
    char *end = NULL;
    double parsed = strtod(token, &end);
    if (end == token || !isfinite(parsed)) return 0;
    *number = parsed;
    return 1;
}

/* Decode a JSON string literal; returns malloc'd UTF-8 or NULL. */
static int hex_digit(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
static int read_hex4(const char *text, unsigned *result) {
    unsigned value = 0;
    for (int index = 0; index < 4; index++) { int digit = hex_digit(text[index]); if (digit < 0) return 0; value = value * 16 + (unsigned)digit; }
    *result = value; return 1;
}
static char *decode_string(const char *token) {
    size_t length = strlen(token);
    if (length < 2 || token[length - 1] != '"') return NULL;
    char *out = malloc(length * 2 + 1);
    if (!out) return NULL;
    size_t destination = 0;
    for (size_t index = 1; index < length - 1; index++) {
        unsigned char c = (unsigned char)token[index];
        if (c < 0x20) { free(out); return NULL; }
        if (c != '\\') { out[destination++] = (char)c; continue; }
        if (++index >= length - 1) { free(out); return NULL; }
        char e = token[index];
        if (e == 'n') out[destination++] = '\n'; else if (e == 't') out[destination++] = '\t'; else if (e == 'r') out[destination++] = '\r';
        else if (e == 'b') out[destination++] = '\b'; else if (e == 'f') out[destination++] = '\f';
        else if (e == '"' || e == '\\' || e == '/') out[destination++] = e;
        else if (e == 'u') {
            unsigned code;
            if (index + 4 >= length || !read_hex4(token + index + 1, &code)) { free(out); return NULL; }
            index += 4;
            if (code >= 0xD800 && code <= 0xDBFF) {
                unsigned low;
                if (index + 6 >= length || token[index + 1] != '\\' || token[index + 2] != 'u' || !read_hex4(token + index + 3, &low) || low < 0xDC00 || low > 0xDFFF) { free(out); return NULL; }
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                index += 6;
            } else if (code >= 0xDC00 && code <= 0xDFFF) { free(out); return NULL; }
            if (code < 0x80) out[destination++] = (char)code;
            else if (code < 0x800) { out[destination++] = (char)(0xC0 | (code >> 6)); out[destination++] = (char)(0x80 | (code & 0x3F)); }
            else if (code < 0x10000) { out[destination++] = (char)(0xE0 | (code >> 12)); out[destination++] = (char)(0x80 | ((code >> 6) & 0x3F)); out[destination++] = (char)(0x80 | (code & 0x3F)); }
            else { out[destination++] = (char)(0xF0 | (code >> 18)); out[destination++] = (char)(0x80 | ((code >> 12) & 0x3F)); out[destination++] = (char)(0x80 | ((code >> 6) & 0x3F)); out[destination++] = (char)(0x80 | (code & 0x3F)); }
        } else { free(out); return NULL; }
    }
    out[destination] = '\0';
    return out;
}

static Variable *find_variable(Variables *variables, const char *name) {
    for (size_t index = 0; index < variables->count; index++) if (!strcmp(variables->items[index].name, name)) return &variables->items[index];
    return NULL;
}

static int resolve(const char *token, Variables *variables, Value *value, char *message, size_t size) {
    memset(value, 0, sizeof(*value));
    if (token[0] == '$') {
        Variable *found = find_variable(variables, token + 1);
        if (!found) { snprintf(message, size, "Unknown variable %s.", token); return 0; }
        value->is_number = found->value.is_number; value->number = found->value.number;
        if (found->value.text) { value->text = copy_text(found->value.text, strlen(found->value.text)); if (!value->text) return 0; }
        return 1;
    }
    if (token[0] == '"') {
        value->text = decode_string(token);
        if (!value->text) { snprintf(message, size, "Invalid quoted string."); return 0; }
        return 1;
    }
    double number;
    if (is_number_token(token, &number)) { value->is_number = 1; value->number = number; return 1; }
    value->text = copy_text(token, strlen(token));
    return value->text != NULL;
}

static int valid_name(const char *name) {
    if (!*name || isdigit((unsigned char)name[0])) return 0;
    for (const char *c = name; *c; c++) if (!isalnum((unsigned char)*c) && *c != '_') return 0;
    return 1;
}

/* ---- Unicode helpers: UTF-16 length, simple upper/lower (ASCII + Latin-1/ß special-case) ---- */
static size_t utf16_length(const char *text) {
    size_t count = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        if ((*p & 0xC0) == 0x80) continue;
        count += (*p >= 0xF0) ? 2 : 1;
    }
    return count;
}
static int valid_utf8(const unsigned char *text, size_t length) {
    for (size_t i = 0; i < length;) {
        unsigned char c = text[i];
        size_t need = c < 0x80 ? 0 : (c >= 0xC2 && c <= 0xDF) ? 1 : (c >= 0xE0 && c <= 0xEF) ? 2 : (c >= 0xF0 && c <= 0xF4) ? 3 : (size_t)-1;
        if (need == (size_t)-1 || i + need >= length + (need ? 0 : 1)) { if (need) return 0; }
        if (need && i + need >= length + 0 && i + need > length - 1) return 0;
        unsigned code = need == 0 ? c : need == 1 ? (c & 0x1Fu) : need == 2 ? (c & 0x0Fu) : (c & 0x07u);
        for (size_t k = 1; k <= need; k++) { if ((text[i + k] & 0xC0) != 0x80) return 0; code = (code << 6) | (text[i + k] & 0x3Fu); }
        if ((need == 2 && (code < 0x800 || (code >= 0xD800 && code <= 0xDFFF))) || (need == 3 && (code < 0x10000 || code > 0x10FFFF))) return 0;
        i += need + 1;
    }
    return 1;
}

static char *case_convert(const char *text, int upper) {
    size_t length = strlen(text);
    char *out = malloc(length * 2 + 1);
    if (!out) return NULL;
    size_t d = 0;
    for (size_t i = 0; i < length;) {
        unsigned char c = (unsigned char)text[i];
        if (c < 0x80) { out[d++] = (char)(upper ? toupper(c) : tolower(c)); i++; continue; }
        if (upper && c == 0xC3 && i + 1 < length && (unsigned char)text[i + 1] == 0x9F) { out[d++] = 'S'; out[d++] = 'S'; i += 2; continue; }
        if (c == 0xC3 && i + 1 < length) {
            unsigned char n = (unsigned char)text[i + 1];
            if (upper && n >= 0xA0 && n <= 0xBE && n != 0xB7) { out[d++] = (char)c; out[d++] = (char)(n - 0x20); i += 2; continue; }
            if (!upper && n >= 0x80 && n <= 0x9E && n != 0x97) { out[d++] = (char)c; out[d++] = (char)(n + 0x20); i += 2; continue; }
        }
        out[d++] = (char)c; i++;
    }
    out[d] = '\0';
    return out;
}

static int truthy(const Value *value) { return value->is_number ? value->number != 0 : (value->text && *value->text); }

static int assign(Variables *variables, const char *name, Value *value) {
    Variable *target = find_variable(variables, name);
    if (!target) {
        Variable *grown = realloc(variables->items, (variables->count + 1) * sizeof(Variable));
        if (!grown) return 0;
        variables->items = grown;
        target = &variables->items[variables->count++];
        target->name = copy_text(name, strlen(name));
        memset(&target->value, 0, sizeof(Value));
        if (!target->name) { variables->count--; return 0; }
    }
    value_clear(&target->value);
    target->value = *value;
    value->text = NULL; value->is_number = 0;
    return 1;
}

static void release_instructions(Instruction *instructions, size_t count) {
    for (size_t i = 0; i < count; i++) { for (size_t k = 0; k < instructions[i].count; k++) free(instructions[i].operands[k]); free(instructions[i].operands); }
    free(instructions);
}

static int arity_of(int opcode) {
    for (size_t i = 0; i < DEFINITION_COUNT; i++) if (definitions[i].opcode == opcode) return definitions[i].arity;
    return -1;
}

static int decode(const unsigned char *data, size_t length, Instruction **result, size_t *count_out, char *message, size_t size) {
    if (length < 4 || memcmp(data, "VK01", 4)) { snprintf(message, size, "Invalid Vektkove bytecode."); return 0; }
    Instruction *list = NULL; size_t count = 0, position = 4;
    while (position < length) {
        if (position + 2 > length) { snprintf(message, size, "Truncated instruction."); goto fail; }
        int opcode = data[position++]; size_t operands = data[position++];
        Instruction *grown = realloc(list, (count + 1) * sizeof(Instruction));
        if (!grown) goto fail;
        list = grown;
        list[count].opcode = opcode; list[count].count = operands;
        list[count].operands = calloc(operands ? operands : 1, sizeof(char *));
        count++;
        if (!list[count - 1].operands) goto fail;
        for (size_t k = 0; k < operands; k++) {
            if (position + 4 > length) { snprintf(message, size, "Truncated operand."); goto fail; }
            size_t operand_length = ((size_t)data[position] << 24) | ((size_t)data[position + 1] << 16) | ((size_t)data[position + 2] << 8) | data[position + 3];
            position += 4;
            if (operand_length > length - position) { snprintf(message, size, "Truncated operand."); goto fail; }
            if (!valid_utf8(data + position, operand_length)) { snprintf(message, size, "Invalid operand encoding."); goto fail; }
            list[count - 1].operands[k] = copy_text((const char *)data + position, operand_length);
            if (!list[count - 1].operands[k]) goto fail;
            position += operand_length;
        }
        int expected = arity_of(opcode);
        if (expected < 0 || (size_t)expected != operands) { snprintf(message, size, "Invalid instruction."); goto fail; }
    }
    *result = list; *count_out = count;
    return 1;
fail:
    if (!message[0]) snprintf(message, size, "Out of memory.");
    release_instructions(list, count);
    return 0;
}

#define VK_GAME_MAX_MESSAGE 16384u
#ifdef _WIN32
static int vk_game_winsock_active;
static int vk_game_startup(void) {
    if (vk_game_winsock_active) return 1;
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return 0;
    vk_game_winsock_active = 1;
    return 1;
}
#else
static int vk_game_startup(void) { return 1; }
#endif

static void vk_game_socket_close(VkSocket socket) {
    if (socket == VK_INVALID_SOCKET) return;
#ifdef _WIN32
    shutdown(socket, SD_BOTH);
    closesocket(socket);
#else
    shutdown(socket, SHUT_RDWR);
    close(socket);
#endif
}

static int vk_game_send_all(VkSocket socket, const void *buffer, size_t length) {
    const unsigned char *bytes = buffer;
    while (length) {
#ifdef _WIN32
        int sent = send(socket, (const char *)bytes, (int)length, 0);
#else
        ssize_t sent = send(socket, bytes, length, 0);
#endif
        if (sent <= 0) return 0;
        bytes += sent;
        length -= (size_t)sent;
    }
    return 1;
}

static int vk_game_recv_all(VkSocket socket, void *buffer, size_t length) {
    unsigned char *bytes = buffer;
    while (length) {
#ifdef _WIN32
        int received = recv(socket, (char *)bytes, (int)length, 0);
#else
        ssize_t received = recv(socket, bytes, length, 0);
#endif
        if (received <= 0) return 0;
        bytes += received;
        length -= (size_t)received;
    }
    return 1;
}

static void vk_game_configure_socket(VkSocket socket) {
#ifdef _WIN32
    DWORD timeout = 60000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, (const char *)&timeout, sizeof(timeout));
#else
#ifdef SO_NOSIGPIPE
    int no_signal = 1;
    setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &no_signal, sizeof(no_signal));
#endif
    struct timeval timeout = {60, 0};
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
#endif
}

static VkSocket vk_game_open_tcp(const char *host, unsigned short port, int listen_for_peer) {
    if (!vk_game_startup()) return VK_INVALID_SOCKET;
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = listen_for_peer ? AI_PASSIVE : 0;
    char port_text[8]; snprintf(port_text, sizeof(port_text), "%u", (unsigned)port);
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, port_text, &hints, &addresses) != 0) return VK_INVALID_SOCKET;
    VkSocket connected = VK_INVALID_SOCKET;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        VkSocket candidate = (VkSocket)socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (candidate == VK_INVALID_SOCKET) continue;
        vk_game_configure_socket(candidate);
        if (listen_for_peer) {
            int reuse = 1;
            setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));
            if (bind(candidate, address->ai_addr, (int)address->ai_addrlen) == 0 && listen(candidate, 1) == 0) {
                VkSocket peer = (VkSocket)accept(candidate, NULL, NULL);
                vk_game_socket_close(candidate);
                if (peer != VK_INVALID_SOCKET) { vk_game_configure_socket(peer); connected = peer; }
                break;
            }
        } else if (connect(candidate, address->ai_addr, (int)address->ai_addrlen) == 0) {
            connected = candidate;
            break;
        }
        vk_game_socket_close(candidate);
    }
    freeaddrinfo(addresses);
    return connected;
}

static VkSocket vk_game_open_listener(const char *host, unsigned short port) {
    if (!vk_game_startup()) return VK_INVALID_SOCKET;
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char port_text[8]; snprintf(port_text, sizeof(port_text), "%u", (unsigned)port);
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, port_text, &hints, &addresses) != 0) return VK_INVALID_SOCKET;
    VkSocket listener = VK_INVALID_SOCKET;
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        VkSocket candidate = (VkSocket)socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (candidate == VK_INVALID_SOCKET) continue;
        vk_game_configure_socket(candidate);
        int reuse = 1;
        setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));
        if (bind(candidate, address->ai_addr, (int)address->ai_addrlen) == 0 && listen(candidate, 16) == 0) { listener = candidate; break; }
        vk_game_socket_close(candidate);
    }
    freeaddrinfo(addresses);
    return listener;
}

static VkSocket vk_game_accept(VkSocket listener) {
    VkSocket client = (VkSocket)accept(listener, NULL, NULL);
    if (client != VK_INVALID_SOCKET) vk_game_configure_socket(client);
    return client;
}

static int vk_game_send_message(VkSocket socket, const char *text, size_t length) {
    if (length > VK_GAME_MAX_MESSAGE) return 0;
    uint32_t size = (uint32_t)length;
    unsigned char header[4] = {(unsigned char)(size >> 24), (unsigned char)(size >> 16), (unsigned char)(size >> 8), (unsigned char)size};
    return vk_game_send_all(socket, header, sizeof(header)) && vk_game_send_all(socket, text, length);
}

static char *vk_game_receive_message(VkSocket socket) {
    unsigned char header[4];
    if (!vk_game_recv_all(socket, header, sizeof(header))) return NULL;
    size_t length = ((size_t)header[0] << 24) | ((size_t)header[1] << 16) | ((size_t)header[2] << 8) | header[3];
    if (length > VK_GAME_MAX_MESSAGE) return NULL;
    char *text = malloc(length + 1);
    if (!text) return NULL;
    if (length && !vk_game_recv_all(socket, text, length)) { free(text); return NULL; }
    text[length] = '\0';
    if (memchr(text, '\0', length) || !valid_utf8((const unsigned char *)text, length)) { free(text); return NULL; }
    return text;
}

static int grow_ui_ids(char ***ids, int **types, size_t *capacity, size_t count) {
    if (count < *capacity) return 1;
    if (*capacity > SIZE_MAX / 2 / sizeof(**ids)) return 0;
    size_t next = *capacity ? *capacity * 2 : 32;
    char **grown_ids = realloc(*ids, next * sizeof(**ids));
    if (!grown_ids) return 0;
    *ids = grown_ids;
    int *grown_types = realloc(*types, next * sizeof(**types));
    if (!grown_types) return 0;
    *types = grown_types;
    *capacity = next;
    return 1;
}

static int run_bytecode(const unsigned char *data, size_t length, Buffer *output, char *message, size_t size, size_t *ui_total) {
    Instruction *code = NULL; size_t count = 0, ui_count = 0; int last_ui_op = 0;
    char **ui_ids = NULL; int *ui_id_types = NULL; size_t ui_id_count = 0, ui_id_capacity = 0; int imported_ui = 0;
    int has_scene3d = 0, has_camera3d = 0, has_scene2d = 0, has_frame2d = 0, has_frame3d = 0, has_gravity2d = 0, has_gravity3d = 0;
    int script_role = 0;
    VkSocket network_socket = VK_INVALID_SOCKET;
    VkSocket network_clients[16]; size_t network_client_count = 0;
    for (size_t client = 0; client < 16; client++) network_clients[client] = VK_INVALID_SOCKET;
    message[0] = '\0';
    if (!decode(data, length, &code, &count, message, size)) return 0;
    /* collect labels; duplicates are errors */
    for (size_t i = 0; i < count; i++) if (code[i].opcode == OP_LABEL)
        for (size_t j = i + 1; j < count; j++) if (code[j].opcode == OP_LABEL && !strcmp(code[i].operands[0], code[j].operands[0])) { snprintf(message, size, "Duplicate label."); release_instructions(code, count); return 0; }
    Variables variables = {NULL, 0};
    VKAIContext ai_context;
    vk_ai_init(&ai_context);
    int ok = 0; size_t steps = 0;
    for (size_t index = 0; index < count; index++) {
        if (++steps > 100000) { snprintf(message, size, "Execution limit exceeded."); goto done; }
        Instruction *ins = &code[index];
        int op = ins->opcode;
        if (op == OP_IMPORT) {
            if (ins->count != 1 || strcmp(ins->operands[0], "ui") || imported_ui || ui_count) { snprintf(message, size, "Place one 'import ui' before all UI instructions."); goto done; }
            imported_ui = 1;
            continue;
        }
        int is_ui = (op >= OP_WINDOW && op <= OP_UIINPUT) || (op >= OP_UICOLOR && op <= OP_UIAUTOTURN) || op == OP_UIID || op == OP_UIBIND || (op >= OP_UISCENE3D && op <= OP_UISPIN3D) || (op >= OP_UISCENE2D && op <= OP_UIKEYMOVE2D) || (op >= OP_UIPHYSICS2D && op <= OP_UIMESH3D) || (op >= OP_UIKEYMOVE3D && op <= OP_UIREMOVE3D);
        if (is_ui && !imported_ui) { snprintf(message, size, "Add 'import ui' before using UI instructions."); goto done; }
        if (op == OP_SERVERSCRIPT || op == OP_LOCALSCRIPT) {
            if (script_role || index != 0) { snprintf(message, size, "Declare one script role as the first instruction."); goto done; }
            script_role = op;
            continue;
        }
        if (script_role == OP_SERVERSCRIPT && is_ui) { snprintf(message, size, "Server scripts cannot create UI."); goto done; }
        if (op >= OP_NETLISTEN && op <= OP_NETBROADCAST) {
            if (!script_role) { snprintf(message, size, "Declare server_script or local_script before networking."); goto done; }
            if (op == OP_NETLISTEN && script_role != OP_SERVERSCRIPT) { snprintf(message, size, "net_listen requires server_script."); goto done; }
            if (op == OP_NETCONNECT && script_role != OP_LOCALSCRIPT) { snprintf(message, size, "net_connect requires local_script."); goto done; }
            if (op == OP_NETLISTENMULTI && script_role != OP_SERVERSCRIPT) { snprintf(message, size, "net_listen_multi requires server_script."); goto done; }
            if ((op == OP_NETSENDTO || op == OP_NETRECEIVEFROM || op == OP_NETBROADCAST) && script_role != OP_SERVERSCRIPT) { snprintf(message, size, "Multi-client networking requires server_script."); goto done; }
            if (op == OP_NETLISTENMULTI) {
                Value host = {0}, port = {0}, client_count = {0};
                int good = resolve(ins->operands[0], &variables, &host, message, size) && resolve(ins->operands[1], &variables, &port, message, size) && resolve(ins->operands[2], &variables, &client_count, message, size);
                if (!good || host.is_number || !host.text || !host.text[0] || strlen(host.text) > 255 || !port.is_number || port.number < 1 || port.number > 65535 || floor(port.number) != port.number || !client_count.is_number || client_count.number < 2 || client_count.number > 16 || floor(client_count.number) != client_count.number) {
                    value_clear(&host); value_clear(&port); value_clear(&client_count);
                    snprintf(message, size, "net_listen_multi needs an address, port 1 to 65535, and client count 2 to 16."); goto done;
                }
                VkSocket listener = vk_game_open_listener(host.text, (unsigned short)port.number);
                if (listener == VK_INVALID_SOCKET) { snprintf(message, size, "Could not listen on %s:%.0f.", host.text, port.number); value_clear(&host); value_clear(&port); value_clear(&client_count); goto done; }
                VkSocket accepted[16]; size_t accepted_count = (size_t)client_count.number;
                for (size_t client = 0; client < accepted_count; client++) {
                    accepted[client] = vk_game_accept(listener);
                    if (accepted[client] == VK_INVALID_SOCKET) {
                        for (size_t previous = 0; previous < client; previous++) vk_game_socket_close(accepted[previous]);
                        vk_game_socket_close(listener); value_clear(&host); value_clear(&port); value_clear(&client_count);
                        snprintf(message, size, "Could not accept every requested TCP client."); goto done;
                    }
                }
                vk_game_socket_close(listener);
                vk_game_socket_close(network_socket); network_socket = VK_INVALID_SOCKET;
                for (size_t client = 0; client < network_client_count; client++) vk_game_socket_close(network_clients[client]);
                network_client_count = accepted_count;
                for (size_t client = 0; client < accepted_count; client++) network_clients[client] = accepted[client];
                value_clear(&host); value_clear(&port); value_clear(&client_count);
                continue;
            }
            if (op == OP_NETLISTEN || op == OP_NETCONNECT) {
                Value host = {0}, port = {0};
                int good = resolve(ins->operands[0], &variables, &host, message, size) && resolve(ins->operands[1], &variables, &port, message, size);
                if (!good || host.is_number || !host.text || !host.text[0] || strlen(host.text) > 255 || port.is_number == 0 || port.number < 1 || port.number > 65535 || floor(port.number) != port.number) {
                    value_clear(&host); value_clear(&port);
                    snprintf(message, size, "Network address must be nonempty text and port must be an integer from 1 to 65535.");
                    goto done;
                }
                VkSocket opened = vk_game_open_tcp(host.text, (unsigned short)port.number, op == OP_NETLISTEN);
                if (opened == VK_INVALID_SOCKET) {
                    snprintf(message, size, "Could not %s %s:%.0f.", op == OP_NETLISTEN ? "accept a peer on" : "connect to", host.text, port.number);
                    value_clear(&host); value_clear(&port); goto done;
                }
                vk_game_socket_close(network_socket);
                for (size_t client = 0; client < network_client_count; client++) vk_game_socket_close(network_clients[client]);
                network_client_count = 0;
                network_socket = opened;
                value_clear(&host); value_clear(&port);
                continue;
            }
            if (op == OP_NETSEND) {
                if (network_socket == VK_INVALID_SOCKET) { snprintf(message, size, "net_send requires an open connection."); goto done; }
                Value value = {0};
                if (!resolve(ins->operands[0], &variables, &value, message, size)) goto done;
                char *text = value_text(&value);
                value_clear(&value);
                int sent = text && vk_game_send_message(network_socket, text, strlen(text));
                free(text);
                if (!sent) { snprintf(message, size, "Could not send message; messages are limited to 16 KiB."); goto done; }
                continue;
            }
            if (op == OP_NETRECEIVE) {
                if (network_socket == VK_INVALID_SOCKET) { snprintf(message, size, "net_receive requires an open connection."); goto done; }
                if (!valid_name(ins->operands[0])) { snprintf(message, size, "Invalid variable name for net_receive."); goto done; }
                char *text = vk_game_receive_message(network_socket);
                if (!text) { snprintf(message, size, "Could not receive a valid UTF-8 message within 16 KiB."); goto done; }
                Value received = {0, 0, text};
                if (!assign(&variables, ins->operands[0], &received)) { value_clear(&received); goto done; }
                continue;
            }
            if (op == OP_NETSENDTO) {
                Value client = {0}, value = {0};
                int good = resolve(ins->operands[0], &variables, &client, message, size) && resolve(ins->operands[1], &variables, &value, message, size);
                if (!good || !client.is_number || floor(client.number) != client.number || client.number < 1 || client.number > (double)network_client_count) {
                    value_clear(&client); value_clear(&value); snprintf(message, size, "net_send_to client id must identify an accepted client."); goto done;
                }
                size_t client_index = (size_t)client.number - 1;
                char *text = value_text(&value); value_clear(&value); value_clear(&client);
                if (!text || !vk_game_send_message(network_clients[client_index], text, strlen(text))) { free(text); snprintf(message, size, "Could not send message; messages are limited to 16 KiB."); goto done; }
                free(text);
                continue;
            }
            if (op == OP_NETRECEIVEFROM) {
                if (!network_client_count || !valid_name(ins->operands[0]) || !valid_name(ins->operands[1])) { snprintf(message, size, "net_receive_from needs an open multi-client server and two valid variable names."); goto done; }
                fd_set readable; FD_ZERO(&readable);
#ifndef _WIN32
                VkSocket maximum = 0;
#endif
                for (size_t client = 0; client < network_client_count; client++) {
                    FD_SET(network_clients[client], &readable);
#ifndef _WIN32
                    if (network_clients[client] > maximum) maximum = network_clients[client];
#endif
                }
                struct timeval timeout = {60, 0};
#ifdef _WIN32
                int ready = select(0, &readable, NULL, NULL, &timeout);
#else
                int ready = select(maximum + 1, &readable, NULL, NULL, &timeout);
#endif
                if (ready <= 0) { snprintf(message, size, "Timed out waiting for a client message."); goto done; }
                size_t client = 0;
                while (client < network_client_count && !FD_ISSET(network_clients[client], &readable)) client++;
                if (client == network_client_count) { snprintf(message, size, "Could not identify the client message source."); goto done; }
                char *text = vk_game_receive_message(network_clients[client]);
                if (!text) { snprintf(message, size, "Could not receive a valid UTF-8 message within 16 KiB."); goto done; }
                Value sender = {1, (double)client + 1, NULL}, received = {0, 0, text};
                if (!assign(&variables, ins->operands[0], &sender) || !assign(&variables, ins->operands[1], &received)) { value_clear(&received); goto done; }
                continue;
            }
            if (op == OP_NETBROADCAST) {
                if (!network_client_count) { snprintf(message, size, "net_broadcast requires accepted clients."); goto done; }
                Value broadcast_value = {0};
                if (!resolve(ins->operands[0], &variables, &broadcast_value, message, size)) goto done;
                char *text = value_text(&broadcast_value); value_clear(&broadcast_value);
                int sent = text != NULL;
                for (size_t client = 0; sent && client < network_client_count; client++) sent = vk_game_send_message(network_clients[client], text, strlen(text));
                free(text);
                if (!sent) { snprintf(message, size, "Could not broadcast message; messages are limited to 16 KiB."); goto done; }
                continue;
            }
            vk_game_socket_close(network_socket);
            network_socket = VK_INVALID_SOCKET;
            for (size_t client = 0; client < network_client_count; client++) vk_game_socket_close(network_clients[client]);
            network_client_count = 0;
            continue;
        }
        if (op == OP_HALT) break;
        if (op == OP_LABEL) continue;
        Value value = {0}, replacement = {0};
        if (op == OP_JUMP || op == OP_IF || op == OP_UNLESS) {
            int take = 1;
            if (op != OP_JUMP) { if (!resolve(ins->operands[0], &variables, &value, message, size)) goto done; take = (op == OP_IF) == (truthy(&value) != 0); value_clear(&value); }
            const char *target = ins->operands[op == OP_JUMP ? 0 : 1];
            size_t destination = (size_t)-1;
            for (size_t j = 0; j < count; j++) if (code[j].opcode == OP_LABEL && !strcmp(code[j].operands[0], target)) { destination = j; break; }
            if (destination == (size_t)-1) { snprintf(message, size, "Unknown label %s.", target); goto done; }
            if (take) index = destination;
            continue;
        }
        if (op == OP_UIID || op == OP_UIBIND) {
            if (ui_count == 0) { snprintf(message, size, "Create a window before using UI ids or bindings."); goto done; }
            if (op == OP_UIID) {
                if (!((last_ui_op >= OP_UILABEL && last_ui_op <= OP_UIINPUT) || (last_ui_op >= OP_UIBOX3D && last_ui_op <= OP_UIPLANE3D) || last_ui_op == OP_UIMESH3D)) { snprintf(message, size, "ui_id needs a unique nonempty id after a control or 3D object."); goto done; }
                Value identifier = {0};
                if (!resolve(ins->operands[0], &variables, &identifier, message, size)) goto done;
                if (identifier.is_number || !identifier.text || !identifier.text[0]) { value_clear(&identifier); snprintf(message, size, "ui_id needs a unique nonempty id after a control or 3D object."); goto done; }
                for (size_t id = 0; id < ui_id_count; id++) if (!strcmp(ui_ids[id], identifier.text)) { value_clear(&identifier); snprintf(message, size, "ui_id needs a unique nonempty id after a control or 3D object."); goto done; }
                if (!grow_ui_ids(&ui_ids, &ui_id_types, &ui_id_capacity, ui_id_count)) { value_clear(&identifier); goto done; }
                ui_ids[ui_id_count] = identifier.text;
                ui_id_types[ui_id_count++] = last_ui_op;
                identifier.text = NULL;
                last_ui_op = OP_UIID;
            } else {
                Value identifier = {0};
                if (!resolve(ins->operands[0], &variables, &identifier, message, size)) goto done;
                size_t id = 0;
                while (id < ui_id_count && (identifier.is_number || strcmp(ui_ids[id], identifier.text ? identifier.text : ""))) id++;
                value_clear(&identifier);
                if (id == ui_id_count || (ui_id_types[id] != OP_UILABEL && ui_id_types[id] != OP_UIINPUT) || !find_variable(&variables, ins->operands[1])) { snprintf(message, size, "ui_bind needs an existing label or input id and defined variable name."); goto done; }
                last_ui_op = OP_UIBIND;
            }
            continue;
        }
        if (op >= OP_UISCENE3D && op <= OP_UISPIN3D) {
            if (ui_count == 0) { snprintf(message, size, "Create a window before adding a 3D scene."); goto done; }
            if (op == OP_UISCENE3D) {
                if (has_scene3d) { snprintf(message, size, "A window can only have one 3D viewport."); goto done; }
                Value parts[4] = {{0}};
                int good = 1;
                for (size_t k = 0; k < ins->count && good; k++) good = resolve(ins->operands[k], &variables, &parts[k], message, size);
                for (size_t k = 0; k < 4 && good; k++) if (!parts[k].is_number || parts[k].number < 0 || parts[k].number > 10000) { snprintf(message, size, "3D viewport positions and sizes must be numbers from 0 to 10000."); good = 0; }
                if (good && (parts[2].number < 1 || parts[3].number < 1)) { snprintf(message, size, "3D viewport dimensions must be positive."); good = 0; }
                for (size_t k = 0; k < 4; k++) value_clear(&parts[k]);
                if (!good) goto done;
                has_scene3d = 1;
            } else {
                if (!has_scene3d) { snprintf(message, size, "Add ui_scene3d before 3D scene instructions."); goto done; }
                if (op == OP_UISPIN3D) {
                    Value identifier = {0}, duration = {0};
                    int good = resolve(ins->operands[0], &variables, &identifier, message, size) && resolve(ins->operands[1], &variables, &duration, message, size);
                    size_t id = 0;
                    while (good && id < ui_id_count && (identifier.is_number || strcmp(ui_ids[id], identifier.text ? identifier.text : ""))) id++;
                    if (!good || id == ui_id_count || !((ui_id_types[id] >= OP_UIBOX3D && ui_id_types[id] <= OP_UIPLANE3D) || ui_id_types[id] == OP_UIMESH3D) || !duration.is_number || duration.number < 0.1 || duration.number > 3600) {
                        snprintf(message, size, "ui_spin3d needs a 3D object id and duration from 0.1 to 3600 seconds.");
                        value_clear(&identifier); value_clear(&duration); goto done;
                    }
                    value_clear(&identifier); value_clear(&duration);
                } else {
                    Value parts[7] = {{0}};
                    int good = 1;
                    for (size_t k = 0; k < ins->count && good; k++) good = resolve(ins->operands[k], &variables, &parts[k], message, size);
                    size_t numeric_count = (op == OP_UICAMERA3D || op == OP_UILIGHT3D) ? ins->count : ins->count - 1;
                    for (size_t k = 0; k < numeric_count && good; k++) if (!parts[k].is_number || parts[k].number < -10000 || parts[k].number > 10000) { snprintf(message, size, "3D coordinates and dimensions must be numbers from -10000 to 10000."); good = 0; }
                    if (good && op == OP_UICAMERA3D && has_camera3d) { snprintf(message, size, "A 3D scene can only have one camera."); good = 0; }
                    if (good && op == OP_UICAMERA3D && parts[0].number == 0 && parts[1].number == 0 && parts[2].number == 0) { snprintf(message, size, "3D camera cannot be placed at the origin."); good = 0; }
                    if (good && op == OP_UILIGHT3D && parts[3].number < 0) { snprintf(message, size, "3D light intensity must be nonnegative."); good = 0; }
                    if (good && op == OP_UIBOX3D && (parts[3].number <= 0 || parts[4].number <= 0 || parts[5].number <= 0)) { snprintf(message, size, "3D box dimensions must be positive."); good = 0; }
                    if (good && op == OP_UISPHERE3D && parts[3].number <= 0) { snprintf(message, size, "3D sphere radius must be positive."); good = 0; }
                    if (good && op == OP_UICYLINDER3D && (parts[3].number <= 0 || parts[4].number <= 0)) { snprintf(message, size, "3D cylinder dimensions must be positive."); good = 0; }
                    if (good && op == OP_UICONE3D && (parts[3].number < 0 || parts[4].number <= 0 || parts[5].number <= 0 || (parts[3].number == 0 && parts[4].number == 0))) { snprintf(message, size, "3D cone dimensions are invalid."); good = 0; }
                    if (good && op == OP_UITORUS3D && (parts[3].number <= 0 || parts[4].number <= 0)) { snprintf(message, size, "3D torus radii must be positive."); good = 0; }
                    if (good && op == OP_UIPLANE3D && (parts[3].number <= 0 || parts[4].number <= 0)) { snprintf(message, size, "3D plane dimensions must be positive."); good = 0; }
                    if (good && op >= OP_UIBOX3D && op <= OP_UIPLANE3D) {
                        const char *color = parts[ins->count - 1].text;
                        int valid = !parts[ins->count - 1].is_number && color && strlen(color) == 7 && color[0] == '#';
                        for (size_t digit = 1; valid && digit < 7; digit++) if (!isxdigit((unsigned char)color[digit])) valid = 0;
                        if (!valid) { snprintf(message, size, "3D primitive color must use #RRGGBB."); good = 0; }
                    }
                    for (size_t k = 0; k < ins->count; k++) value_clear(&parts[k]);
                    if (!good) goto done;
                    if (op == OP_UICAMERA3D) has_camera3d = 1;
                }
            }
            ui_count++;
            last_ui_op = op;
            continue;
        }
        if (op >= OP_UISCENE2D && op <= OP_UIKEYMOVE2D) {
            if (ui_count == 0) { snprintf(message, size, "Create a window before adding a 2D game scene."); goto done; }
            if (op == OP_UISCENE2D) {
                if (has_scene2d) { snprintf(message, size, "A window can only have one 2D game scene."); goto done; }
                Value parts[4] = {{0}};
                int good = 1;
                for (size_t k = 0; k < 4 && good; k++) good = resolve(ins->operands[k], &variables, &parts[k], message, size);
                for (size_t k = 0; k < 4 && good; k++) if (!parts[k].is_number || parts[k].number < 0 || parts[k].number > 10000) { snprintf(message, size, "2D viewport positions and sizes must be numbers from 0 to 10000."); good = 0; }
                if (good && (parts[2].number < 1 || parts[3].number < 1)) { snprintf(message, size, "2D viewport dimensions must be positive."); good = 0; }
                for (size_t k = 0; k < 4; k++) value_clear(&parts[k]);
                if (!good) goto done;
                has_scene2d = 1;
            } else {
                if (!has_scene2d) { snprintf(message, size, "Add ui_scene2d before 2D game objects."); goto done; }
                Value parts[6] = {{0}};
                int good = 1;
                for (size_t k = 0; k < ins->count && good; k++) good = resolve(ins->operands[k], &variables, &parts[k], message, size);
                if (op == OP_UIRECT2D || op == OP_UICIRCLE2D) {
                    Value *identifier = &parts[0];
                    if (good && (identifier->is_number || !identifier->text || !identifier->text[0])) { snprintf(message, size, "2D object ids must be unique nonempty text."); good = 0; }
                    for (size_t k = 0; good && k < ui_id_count; k++) if (!strcmp(ui_ids[k], identifier->text)) { snprintf(message, size, "2D object ids must be unique nonempty text."); good = 0; }
                    size_t numeric_count = op == OP_UIRECT2D ? 4 : 3;
                    for (size_t k = 1; k <= numeric_count && good; k++) if (!parts[k].is_number || parts[k].number < 0 || parts[k].number > 10000) { snprintf(message, size, "2D object coordinates and sizes must be numbers from 0 to 10000."); good = 0; }
                    if (good && (parts[3].number < 1 || (op == OP_UIRECT2D && parts[4].number < 1))) { snprintf(message, size, "2D object dimensions must be positive."); good = 0; }
                    const char *color = parts[ins->count - 1].text;
                    int valid_color = good && !parts[ins->count - 1].is_number && color && strlen(color) == 7 && color[0] == '#';
                    for (size_t digit = 1; valid_color && digit < 7; digit++) if (!isxdigit((unsigned char)color[digit])) valid_color = 0;
                    if (good && !valid_color) { snprintf(message, size, "2D object color must use #RRGGBB."); good = 0; }
                    if (good && !grow_ui_ids(&ui_ids, &ui_id_types, &ui_id_capacity, ui_id_count)) good = 0;
                    if (good) {
                        ui_ids[ui_id_count] = identifier->text;
                        ui_id_types[ui_id_count++] = op;
                        identifier->text = NULL;
                    }
                } else {
                    Value *identifier = &parts[0];
                    size_t id = 0;
                    while (good && id < ui_id_count && (identifier->is_number || strcmp(ui_ids[id], identifier->text ? identifier->text : ""))) id++;
                    if (!good || id == ui_id_count || (ui_id_types[id] != OP_UIRECT2D && ui_id_types[id] != OP_UICIRCLE2D)) { snprintf(message, size, "2D motion instructions need an existing object id."); good = 0; }
                    if (good && op == OP_UIKEYMOVE2D && (parts[1].is_number || !parts[1].text || !parts[1].text[0] || strlen(parts[1].text) > 16)) { snprintf(message, size, "2D movement keys must be text of 1 to 16 characters."); good = 0; }
                    size_t start = op == OP_UIVELOCITY2D ? 1 : 2;
                    for (size_t k = start; k < ins->count && good; k++) if (!parts[k].is_number || parts[k].number < -10000 || parts[k].number > 10000) { snprintf(message, size, "2D movement values must be numbers from -10000 to 10000."); good = 0; }
                    if (good && op == OP_UIKEYMOVE2D) for (char *key = parts[1].text; *key; key++) *key = (char)tolower((unsigned char)*key);
                }
                for (size_t k = 0; k < ins->count; k++) value_clear(&parts[k]);
                if (!good) goto done;
            }
            ui_count++;
            last_ui_op = op;
            continue;
        }
        if (op == OP_UIFRAME2D || op == OP_UIFRAME3D) {
            int frame3d = op == OP_UIFRAME3D;
            if ((frame3d ? !has_scene3d || has_frame3d : !has_scene2d || has_frame2d)) {
                snprintf(message, size, frame3d ? "ui_frame3d needs a 3D scene and may be used once." : "ui_frame2d needs a 2D scene and may be used once."); goto done;
            }
            size_t end = index + 1;
            int end_opcode = frame3d ? OP_UIENDFRAME3D : OP_UIENDFRAME2D;
            while (end < count && code[end].opcode != end_opcode) end++;
            if (end == count) { snprintf(message, size, frame3d ? "ui_frame3d is missing ui_end_frame3d." : "ui_frame2d is missing ui_end_frame2d."); goto done; }
            for (size_t callback = index + 1; callback < end; callback++) {
                int callback_op = code[callback].opcode;
                int allowed = callback_op == OP_TEXT || callback_op == OP_SET || callback_op == OP_ADD || callback_op == OP_SUB ||
                    callback_op == OP_MUL || callback_op == OP_DIV || callback_op == OP_MOD || callback_op == OP_POW ||
                    callback_op == OP_MIN || callback_op == OP_MAX || callback_op == OP_EQ || callback_op == OP_NE ||
                    callback_op == OP_LT || callback_op == OP_LE || callback_op == OP_GT || callback_op == OP_GE ||
                    callback_op == OP_NOT || callback_op == OP_AND || callback_op == OP_OR || callback_op == OP_NEG ||
                    callback_op == OP_ABS || callback_op == OP_ROUND || callback_op == OP_FLOOR || callback_op == OP_CEIL ||
                    callback_op == OP_SQRT || callback_op == OP_SIN || callback_op == OP_COS || callback_op == OP_TAN ||
                    callback_op == OP_ASIN || callback_op == OP_ACOS || callback_op == OP_ATAN || callback_op == OP_LOG ||
                    callback_op == OP_LOG10 || callback_op == OP_EXP || callback_op == OP_SIGN || callback_op == OP_TRUNC ||
                    callback_op == OP_LABEL || callback_op == OP_JUMP || callback_op == OP_IF || callback_op == OP_UNLESS ||
                    callback_op == OP_UIMOVE2D || callback_op == OP_UIFORCE2D || callback_op == OP_UISETVELOCITY2D ||
                    callback_op == OP_UIMOVE3D || callback_op == OP_UIFORCE3D || callback_op == OP_UISETVELOCITY3D || callback_op == OP_UIREMOVE3D;
                if (!allowed) { snprintf(message, size, "Frame callbacks allow variable, branch, and 2D action instructions only."); goto done; }
                if (callback_op == OP_UIMOVE2D || callback_op == OP_UIFORCE2D || callback_op == OP_UISETVELOCITY2D ||
                    callback_op == OP_UIMOVE3D || callback_op == OP_UIFORCE3D || callback_op == OP_UISETVELOCITY3D || callback_op == OP_UIREMOVE3D) {
                    int action3d = callback_op == OP_UIMOVE3D || callback_op == OP_UIFORCE3D || callback_op == OP_UISETVELOCITY3D || callback_op == OP_UIREMOVE3D;
                    if (action3d != frame3d) { snprintf(message, size, "Frame callback actions must match the scene dimension."); goto done; }
                    Value parts[4] = {{0}};
                    int good = 1;
                    size_t operand_count = callback_op == OP_UIREMOVE3D ? 1 : action3d ? 4 : 3;
                    for (size_t operand = 0; operand < operand_count && good; operand++) if (code[callback].operands[operand][0] != '$') good = resolve(code[callback].operands[operand], &variables, &parts[operand], message, size);
                    size_t object_id = 0;
                    while (good && object_id < ui_id_count && (parts[0].is_number || strcmp(ui_ids[object_id], parts[0].text ? parts[0].text : ""))) object_id++;
                    int valid_type = code[callback].operands[0][0] == '$' || (object_id < ui_id_count && (action3d ? ((ui_id_types[object_id] >= OP_UIBOX3D && ui_id_types[object_id] <= OP_UIPLANE3D) || ui_id_types[object_id] == OP_UIMESH3D) : (ui_id_types[object_id] == OP_UIRECT2D || ui_id_types[object_id] == OP_UICIRCLE2D)));
                    if (!good || !valid_type) {
                        snprintf(message, size, action3d ? "3D callback action needs an existing 3D object id and numeric values." : "Frame callback action needs an existing 2D object id and numeric values.");
                        good = 0;
                    }
                    for (size_t operand = 1; operand < operand_count && good; operand++) if (code[callback].operands[operand][0] != '$' && !parts[operand].is_number) {
                        snprintf(message, size, action3d ? "3D callback action needs an existing 3D object id and numeric values." : "Frame callback action needs an existing 2D object id and numeric values.");
                        good = 0;
                    }
                    for (size_t operand = 0; operand < operand_count; operand++) value_clear(&parts[operand]);
                    if (!good) goto done;
                }
            }
            if (frame3d) has_frame3d = 1;
            else has_frame2d = 1;
            index = end;
            continue;
        }
        if (op == OP_UIENDFRAME2D) { snprintf(message, size, "ui_end_frame2d must close ui_frame2d."); goto done; }
        if (op == OP_UIENDFRAME3D) { snprintf(message, size, "ui_end_frame3d must close ui_frame3d."); goto done; }
        if (op >= OP_UIPHYSICS2D && op <= OP_UISETVELOCITY2D) {
            if (!has_scene2d) { snprintf(message, size, "Add ui_scene2d before 2D physics instructions."); goto done; }
            Value parts[3] = {{0}};
            int good = 1;
            for (size_t k = 0; k < ins->count && good; k++) good = resolve(ins->operands[k], &variables, &parts[k], message, size);
            if (op == OP_UIGRAVITY2D) {
                if (has_gravity2d || !good || !parts[0].is_number || !parts[1].is_number || fabs(parts[0].number) > 10000 || fabs(parts[1].number) > 10000) { snprintf(message, size, "ui_gravity2d needs one scene and numeric gravity values from -10000 to 10000."); good = 0; }
                has_gravity2d = good;
            } else if (op == OP_UIPHYSICS2D) {
                size_t id = 0;
                while (good && id < ui_id_count && (parts[0].is_number || strcmp(ui_ids[id], parts[0].text ? parts[0].text : ""))) id++;
                if (!good || id == ui_id_count || (ui_id_types[id] != OP_UIRECT2D && ui_id_types[id] != OP_UICIRCLE2D) || !parts[1].is_number || parts[1].number < 0 || parts[1].number > 10000 || !parts[2].is_number || parts[2].number < 0 || parts[2].number > 1) {
                    snprintf(message, size, "ui_physics2d needs an object id, mass from 0 to 10000, and restitution from 0 to 1."); good = 0;
                }
            } else { snprintf(message, size, "2D callback actions must be inside ui_frame2d."); good = 0; }
            for (size_t k = 0; k < ins->count; k++) value_clear(&parts[k]);
            if (!good) goto done;
            ui_count++;
            last_ui_op = op;
            continue;
        }
        if (op == OP_UIMESH3D) {
            if (!has_scene3d) { snprintf(message, size, "Add ui_scene3d before 3D physics instructions."); goto done; }
            Value parts[6] = {{0}};
            int good = 1;
            for (size_t part = 0; part < 6 && good; part++) good = resolve(ins->operands[part], &variables, &parts[part], message, size);
            const char *color = parts[5].text;
            int valid_color = good && !parts[5].is_number && color && strlen(color) == 7 && color[0] == '#';
            for (size_t digit = 1; valid_color && digit < 7; digit++) if (!isxdigit((unsigned char)color[digit])) valid_color = 0;
            if (good && (parts[0].is_number || !parts[0].text || !parts[0].text[0] || !valid_color)) { snprintf(message, size, "ui_mesh3d needs a model path and #RRGGBB color."); good = 0; }
            for (size_t part = 1; part <= 4 && good; part++) if (!parts[part].is_number || fabs(parts[part].number) > 10000 || (part == 4 && parts[part].number <= 0)) { snprintf(message, size, "ui_mesh3d needs numeric coordinates and a positive scale up to 10000."); good = 0; }
            for (size_t part = 0; part < 6; part++) value_clear(&parts[part]);
            if (!good) goto done;
            ui_count++;
            last_ui_op = op;
            continue;
        }
        if ((op >= OP_UIPHYSICS3D && op <= OP_UIVELOCITY3D) || (op >= OP_UIKEYMOVE3D && op <= OP_UIREMOVE3D)) {
            if (!has_scene3d) { snprintf(message, size, "Add ui_scene3d before 3D physics instructions."); goto done; }
            Value parts[5] = {{0}};
            int good = 1;
            for (size_t k = 0; k < ins->count && good; k++) good = resolve(ins->operands[k], &variables, &parts[k], message, size);
            if (op == OP_UIGRAVITY3D) {
                if (has_gravity3d || !good || !parts[0].is_number || !parts[1].is_number || !parts[2].is_number || fabs(parts[0].number) > 10000 || fabs(parts[1].number) > 10000 || fabs(parts[2].number) > 10000) {
                    snprintf(message, size, "ui_gravity3d needs one scene and numeric gravity values from -10000 to 10000."); good = 0;
                }
                has_gravity3d = good;
            } else if (op == OP_UIVOXEL3D || op == OP_UIVOXELCONTROLS3D) {
                size_t numeric_count = op == OP_UIVOXEL3D ? 3 : 1;
                int valid = good;
                for (size_t component = 0; component < numeric_count && valid; component++) {
                    valid = parts[component].is_number && fabs(parts[component].number) <= 10000;
                    if (op == OP_UIVOXEL3D && valid) valid = floor(parts[component].number) == parts[component].number;
                }
                if (op == OP_UIVOXELCONTROLS3D && valid) valid = parts[0].number > 0 && parts[0].number <= 10;
                const char *color = parts[ins->count - 1].text;
                valid = valid && !parts[ins->count - 1].is_number && color && strlen(color) == 7 && color[0] == '#';
                for (size_t digit = 1; valid && digit < 7; digit++) if (!isxdigit((unsigned char)color[digit])) valid = 0;
                if (!valid) { snprintf(message, size, op == OP_UIVOXEL3D ? "ui_voxel3d needs integer coordinates and a #RRGGBB color." : "ui_voxel_controls3d needs a step from 0 to 10 and a #RRGGBB color."); good = 0; }
            } else if (op == OP_UIREMOVE3D) {
                size_t id = 0;
                while (good && id < ui_id_count && (parts[0].is_number || strcmp(ui_ids[id], parts[0].text ? parts[0].text : ""))) id++;
                if (!good || id == ui_id_count || !((ui_id_types[id] >= OP_UIBOX3D && ui_id_types[id] <= OP_UIPLANE3D) || ui_id_types[id] == OP_UIMESH3D)) { snprintf(message, size, "ui_remove3d needs an existing 3D object id."); good = 0; }
            } else if (op == OP_UIKEYMOVE3D) {
                size_t id = 0;
                while (good && id < ui_id_count && (parts[0].is_number || strcmp(ui_ids[id], parts[0].text ? parts[0].text : ""))) id++;
                int valid = good && id < ui_id_count && ((ui_id_types[id] >= OP_UIBOX3D && ui_id_types[id] <= OP_UIPLANE3D) || ui_id_types[id] == OP_UIMESH3D) && !parts[1].is_number && parts[1].text && parts[1].text[0] && strlen(parts[1].text) <= 16;
                for (size_t component = 2; component < 5 && valid; component++) valid = parts[component].is_number && fabs(parts[component].number) <= 10000;
                if (!valid) { snprintf(message, size, "ui_keymove3d needs a 3D object id, key, and three numeric movement values."); good = 0; }
            } else if (op == OP_UIPHYSICS3D || op == OP_UIVELOCITY3D) {
                size_t id = 0;
                while (good && id < ui_id_count && (parts[0].is_number || strcmp(ui_ids[id], parts[0].text ? parts[0].text : ""))) id++;
                int valid_object = good && id < ui_id_count && ((ui_id_types[id] >= OP_UIBOX3D && ui_id_types[id] <= OP_UIPLANE3D) || ui_id_types[id] == OP_UIMESH3D);
                if (op == OP_UIVELOCITY3D) {
                    if (!valid_object || !parts[1].is_number || !parts[2].is_number || !parts[3].is_number || fabs(parts[1].number) > 10000 || fabs(parts[2].number) > 10000 || fabs(parts[3].number) > 10000) { snprintf(message, size, "ui_velocity3d needs a 3D object id and three numeric velocity components."); good = 0; }
                } else if (!valid_object || !parts[1].is_number || parts[1].number < 0 || parts[1].number > 10000 || !parts[2].is_number || parts[2].number < 0 || parts[2].number > 1) {
                    snprintf(message, size, "ui_physics3d needs an object id, mass from 0 to 10000, and restitution from 0 to 1."); good = 0;
                }
            } else { snprintf(message, size, "3D callback actions must be inside ui_frame3d."); good = 0; }
            for (size_t k = 0; k < ins->count; k++) value_clear(&parts[k]);
            if (!good) goto done;
            ui_count++;
            last_ui_op = op;
            continue;
        }
        if (op == OP_UICOLOR) {
            if (ui_count == 0) { snprintf(message, size, "Create a window before setting a UI color."); goto done; }
            if (!resolve(ins->operands[0], &variables, &value, message, size)) goto done;
            int valid = !value.is_number && value.text && strlen(value.text) == 7 && value.text[0] == '#';
            for (size_t digit = 1; valid && digit < 7; digit++) if (!isxdigit((unsigned char)value.text[digit])) valid = 0;
            value_clear(&value);
            if (!valid) { snprintf(message, size, "ui_color expects a #RRGGBB color."); goto done; }
            continue;
        }
        if (op >= OP_UISHORTCUT && op <= OP_UIAUTOTURN) {
            if (ui_count == 0) { snprintf(message, size, "Create a window before adding an action."); goto done; }
            Value parts[4];
            memset(parts, 0, sizeof(parts));
            int good = 1;
            for (size_t k = 0; k < ins->count && good; k++) good = resolve(ins->operands[k], &variables, &parts[k], message, size);
            if (good && (op == OP_UISHORTCUT || op == OP_UIKEYNOTE)) {
                size_t n = parts[0].is_number || !parts[0].text ? 0 : strlen(parts[0].text);
                if (n < 1 || n > 40) { snprintf(message, size, "The shortcut key must be text of 1 to 40 characters."); good = 0; }
            }
            if (good && op == OP_UISHORTCUT && parts[1].is_number) { snprintf(message, size, "The shortcut message must be text."); good = 0; }
            if (good && op == OP_UISOUND && (parts[0].is_number || !parts[0].text || !parts[0].text[0])) { snprintf(message, size, "The sound path must be nonempty text."); good = 0; }
            if (good && op == OP_UIKEYBOARD) {
                int named = !parts[0].is_number && parts[0].text && (!strcasecmp(parts[0].text, "piano") || !strcasecmp(parts[0].text, "guitar"));
                if (!named || !parts[1].is_number || parts[1].number < 0 || parts[1].number > 111 || floor(parts[1].number) != parts[1].number) { snprintf(message, size, "Use piano or guitar and a base MIDI note from 0 to 111."); good = 0; }
            }
            if (good && op == OP_UIAUTOTURN) {
                if (last_ui_op < OP_UILABEL || last_ui_op > OP_UIINPUT) { snprintf(message, size, "auto_turn must follow a UI control."); good = 0; }
                else if (!parts[0].is_number || parts[0].number < 0.1 || parts[0].number > 3600) { snprintf(message, size, "auto_turn duration must be from 0.1 to 3600 seconds."); good = 0; }
            }
            if (good && (op == OP_UINOTE || op == OP_UIKEYNOTE)) {
                size_t s = op == OP_UIKEYNOTE ? 1 : 0;
                int named = !parts[s].is_number && parts[s].text && (!strcasecmp(parts[s].text, "piano") || !strcasecmp(parts[s].text, "guitar"));
                if (!named || !parts[s + 1].is_number || parts[s + 1].number < 0 || parts[s + 1].number > 127 || floor(parts[s + 1].number) != parts[s + 1].number ||
                        !parts[s + 2].is_number || parts[s + 2].number < 0.05 || parts[s + 2].number > 10) { snprintf(message, size, "Use piano or guitar, MIDI note 0 to 127, and duration 0.05 to 10 seconds."); good = 0; }
            }
            for (size_t k = 0; k < ins->count; k++) value_clear(&parts[k]);
            if (!good) goto done;
            ui_count++; last_ui_op = op;
            continue;
        }
        if (op >= OP_WINDOW && op <= OP_UIINPUT) {
            /* Validate exactly like the macOS engine, but there is no window system here. */
            if ((op == OP_WINDOW && ui_count != 0) || (op != OP_WINDOW && ui_count == 0)) { snprintf(message, size, "A UI must start with exactly one window instruction."); goto done; }
            size_t numeric_end = op == OP_UIBUTTON ? ins->count - 1 : ins->count;
            Value parts[6];
            memset(parts, 0, sizeof(parts));
            int good = 1;
            for (size_t k = 0; k < ins->count && good; k++) good = resolve(ins->operands[k], &variables, &parts[k], message, size);
            for (size_t k = 1; k < numeric_end && good; k++) {
                if (!parts[k].is_number || parts[k].number < 0 || parts[k].number > 10000) { snprintf(message, size, "UI positions and sizes must be numbers from 0 to 10000."); good = 0; }
            }
            size_t size_start = op == OP_WINDOW ? 1 : 3;
            if (good && (parts[size_start].number < 1 || parts[size_start + 1].number < 1)) { snprintf(message, size, "UI widths and heights must be positive."); good = 0; }
            for (size_t k = 0; k < ins->count; k++) value_clear(&parts[k]);
            if (!good) goto done;
            ui_count++; last_ui_op = op;
            continue;
        }
        if (op == OP_OUT) {
            if (!resolve(ins->operands[0], &variables, &value, message, size)) goto done;
            char *line = value_text(&value); value_clear(&value);
            if (!line) goto done;
            int appended = buffer_append(output, line, strlen(line)) && buffer_append(output, "\n", 1);
            free(line);
            if (!appended) goto done;
            if (output->size > 100000) { snprintf(message, size, "Output limit exceeded."); goto done; }
            continue;
        }
        if (op == OP_TERMINALKEYWORDS || op == OP_TERMINALECHO || op == OP_TERMINALRUN) {
            char *line = NULL;
            if (op == OP_TERMINALKEYWORDS) {
                const char *listing = "terminal_run help|date|pwd; terminal_echo value; terminal_keywords";
                line = copy_text(listing, strlen(listing));
            }
            else if (op == OP_TERMINALECHO) {
                if (!resolve(ins->operands[0], &variables, &value, message, size)) goto done;
                line = value_text(&value);
                value_clear(&value);
            } else {
                if (!resolve(ins->operands[0], &variables, &value, message, size)) goto done;
                if (value.is_number || !value.text) { value_clear(&value); snprintf(message, size, "terminal_run requires a text keyword. Use help, date, or pwd."); goto done; }
                if (!strcasecmp(value.text, "help")) {
                    const char *help = "Available terminal_run keywords: date, help, pwd. Use terminal_echo to print text.";
                    line = copy_text(help, strlen(help));
                }
                else if (!strcasecmp(value.text, "date")) {
                    time_t now = time(NULL);
                    struct tm utc;
#ifdef _WIN32
                    if (gmtime_s(&utc, &now) != 0) { value_clear(&value); snprintf(message, size, "Could not read the current date."); goto done; }
#else
                    if (!gmtime_r(&now, &utc)) { value_clear(&value); snprintf(message, size, "Could not read the current date."); goto done; }
#endif
                    char date[16];
                    if (!strftime(date, sizeof(date), "%Y-%m-%d", &utc)) { value_clear(&value); snprintf(message, size, "Could not format the current date."); goto done; }
                    line = copy_text(date, strlen(date));
                } else if (!strcasecmp(value.text, "pwd")) {
                    char path[4096];
                    if (!getcwd(path, sizeof(path))) { value_clear(&value); snprintf(message, size, "Could not read working directory."); goto done; }
                    line = copy_text(path, strlen(path));
                } else { value_clear(&value); snprintf(message, size, "Unsupported terminal keyword. Use help, date, or pwd."); goto done; }
                value_clear(&value);
            }
            int appended = line && buffer_append(output, line, strlen(line)) && buffer_append(output, "\n", 1);
            free(line);
            if (!appended) goto done;
            if (output->size > 100000) { snprintf(message, size, "Output limit exceeded."); goto done; }
            continue;
        }
        if (op == OP_CITE) {
            Value fields[4] = {{0}};
            int good = 1;
            for (size_t field = 0; field < 4 && good; field++) good = resolve(ins->operands[field], &variables, &fields[field], message, size);
            if (good && (fields[0].is_number || !fields[0].text || !fields[0].text[0] ||
                         fields[1].is_number || !fields[1].text || !fields[1].text[0] ||
                         (!fields[2].is_number && (!fields[2].text || !fields[2].text[0])) ||
                         fields[3].is_number || !fields[3].text || !fields[3].text[0])) {
                snprintf(message, size, "cite expects nonempty author, title, year, and URL fields.");
                good = 0;
            }
            char *author = good ? value_text(&fields[0]) : NULL;
            char *title = good ? value_text(&fields[1]) : NULL;
            char *year = good ? value_text(&fields[2]) : NULL;
            char *url = good ? value_text(&fields[3]) : NULL;
            if (good && (!author || !title || !year || !url)) good = 0;
            char *line = NULL;
            if (good) {
                size_t length = strlen(author) + strlen(year) + strlen(title) + strlen(url) + 10;
                line = malloc(length);
                if (line) snprintf(line, length, "%s. (%s). %s. %s", author, year, title, url);
            }
            free(author); free(title); free(year); free(url);
            for (size_t field = 0; field < 4; field++) value_clear(&fields[field]);
            if (!good) goto done;
            int appended = line && buffer_append(output, line, strlen(line)) && buffer_append(output, "\n", 1);
            free(line);
            if (!appended) goto done;
            if (output->size > 100000) { snprintf(message, size, "Output limit exceeded."); goto done; }
            continue;
        }
        if (op == OP_CODECLIST) {
            const char *listing = vkc_format_list();
            if (!buffer_append(output, listing, strlen(listing)) || !buffer_append(output, "\n", 1)) goto done;
            if (output->size > 100000) { snprintf(message, size, "Output limit exceeded."); goto done; }
            continue;
        }
        if (op == OP_AICLEAR) { vk_ai_clear(&ai_context); continue; }
        if (op == OP_AICONFIGURE || op == OP_TRAIN) {
            Value first = {0}, second = {0};
            int good = resolve(ins->operands[0], &variables, &first, message, size) &&
                       resolve(ins->operands[1], &variables, &second, message, size);
            if (good && (first.is_number || second.is_number || !first.text || !second.text)) {
                snprintf(message, size, "AI command operands must be text.");
                good = 0;
            }
            if (good && op == OP_TRAIN && !strcmp(first.text, "synthetic")) {
                VKAIContext generated; vk_ai_init(&generated);
                for (unsigned index = 0; index < 3 && good; index++) {
                    char source[256]; Buffer training = {0};
                    good = vk_ai_synthetic_source(second.text, index, source, sizeof(source), message, size);
                    if (good) good = compile_source(source, strlen(source), &training, message, size);
                    char *tree = good ? vk_ai_code_tree(training.data, training.size, source, message, size) : NULL;
                    if (good) good = tree && vk_ai_add_text(&generated, "synthetic", tree, message, size);
                    free(tree); free(training.data);
                }
                if (good) good = vk_ai_add_text(&ai_context, "synthetic", generated.knowledge, message, size);
                vk_ai_destroy(&generated);
            } else if (good && op == OP_TRAIN && (!strcmp(first.text, "code") || (!strcmp(first.text, "file") && strlen(second.text) >= 3 && !strcmp(second.text + strlen(second.text) - 3, ".vk")))) {
                char *file_source = !strcmp(first.text, "file") ? vk_ai_read_file(second.text, message, size) : NULL;
                if (!strcmp(first.text, "file") && !file_source) good = 0;
                const char *source = file_source ? file_source : second.text;
                Buffer training = {0};
                if (good && !compile_source(source, strlen(source), &training, message, size)) { snprintf(message, size, "Training code failed syntax checking."); good = 0; }
                char *tree = good ? vk_ai_code_tree(training.data, training.size, source, message, size) : NULL;
                if (good) good = tree && vk_ai_add_text(&ai_context, "code", tree, message, size);
                free(tree); free(training.data); free(file_source);
            } else if (good) good = op == OP_AICONFIGURE
                ? vk_ai_configure(&ai_context, first.text, second.text, message, size)
                : vk_ai_train(&ai_context, first.text, second.text, message, size);
            value_clear(&first); value_clear(&second);
            if (!good) goto done;
            continue;
        }
        const char *name = ins->operands[0];
        if (!valid_name(name)) { snprintf(message, size, "Invalid variable name."); goto done; }
        Variable *original = find_variable(&variables, name);
        if (ins->count > 1 && !resolve(ins->operands[1], &variables, &value, message, size)) goto done;
        if (op == OP_TEXT) { char *t = value_text(&value); value_clear(&value); if (!t) goto done; Value stored = {0, 0, t}; if (!assign(&variables, name, &stored)) goto done; continue; }
        if (op == OP_SET) { if (!assign(&variables, name, &value)) { value_clear(&value); goto done; } continue; }
        if (op == OP_AIASK) {
            if (value.is_number || !value.text) { value_clear(&value); snprintf(message, size, "ai_ask requires a text question."); goto done; }
            char *answer = vk_ai_ask(&ai_context, value.text, message, size);
            value_clear(&value);
            if (!answer) goto done;
            Value stored = {0, 0, answer};
            if (!assign(&variables, name, &stored)) { value_clear(&stored); goto done; }
            continue;
        }
        if (!original) { snprintf(message, size, "Unknown variable $%s.", name); value_clear(&value); goto done; }
        Value result = {0};
        int handled = 1;
        char *original_text = value_text(&original->value), *operand_text = ins->count > 1 ? value_text(&value) : NULL;
        if (!original_text || (ins->count > 1 && !operand_text)) { free(original_text); free(operand_text); value_clear(&value); goto done; }
        if (op == OP_ISNUM) { result.is_number = 1; result.number = original->value.is_number; }
        else if (op == OP_ISTEXT) { result.is_number = 1; result.number = !original->value.is_number; }
        else if (op == OP_EMPTY) { result.is_number = 1; result.number = original_text[0] == '\0'; }
        else if (op == OP_CONCAT) { size_t a = strlen(original_text), b = strlen(operand_text); result.text = malloc(a + b + 1); if (result.text) { memcpy(result.text, original_text, a); memcpy(result.text + a, operand_text, b + 1); } }
        else if (op == OP_UPPER || op == OP_LOWER) result.text = case_convert(original_text, op == OP_UPPER);
        else if (op == OP_LENGTH) { result.is_number = 1; result.number = (double)utf16_length(original_text); }
        else if (op == OP_TRIM) {
            const char *s = original_text; const char *e = s + strlen(s);
            while (s < e && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r' || *s == '\v' || *s == '\f')) s++;
            while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\n' || e[-1] == '\r' || e[-1] == '\v' || e[-1] == '\f')) e--;
            result.text = copy_text(s, (size_t)(e - s));
        }
        else if (op == OP_CONTAINS) { result.is_number = 1; result.number = operand_text[0] && strstr(original_text, operand_text) != NULL; }
        else if (op == OP_ENCODE || op == OP_DECODE) {
            vkc_buf transformed = {0};
            if (!vkc_transform(op == OP_ENCODE, operand_text, (const uint8_t *)original_text, strlen(original_text), 1, &transformed, message, size)) { free(original_text); free(operand_text); value_clear(&value); goto done; }
            result.text = malloc(transformed.n + 1);
            if (result.text) { memcpy(result.text, transformed.p, transformed.n); result.text[transformed.n] = '\0'; }
            free(transformed.p);
        }
        else if (op == OP_STARTS) { size_t n = strlen(operand_text); result.is_number = 1; result.number = n && !strncmp(original_text, operand_text, n); }
        else if (op == OP_ENDS) { size_t n = strlen(operand_text), m = strlen(original_text); result.is_number = 1; result.number = n && n <= m && !strcmp(original_text + m - n, operand_text); }
        else if (op == OP_REPLACE) {
            if (!resolve(ins->operands[2], &variables, &replacement, message, size)) { free(original_text); free(operand_text); value_clear(&value); goto done; }
            char *with = value_text(&replacement); value_clear(&replacement);
            if (!operand_text[0]) { snprintf(message, size, "replace requires a non-empty search string."); free(with); free(original_text); free(operand_text); value_clear(&value); goto done; }
            size_t find = strlen(operand_text), with_length = strlen(with), matches = 0;
            for (const char *p = original_text; (p = strstr(p, operand_text)); p += find) matches++;
            result.text = malloc(strlen(original_text) + matches * (with_length > find ? with_length - find : 0) + 1);
            if (result.text) {
                char *out = result.text; const char *p = original_text, *hit;
                while ((hit = strstr(p, operand_text))) { memcpy(out, p, (size_t)(hit - p)); out += hit - p; memcpy(out, with, with_length); out += with_length; p = hit + find; }
                strcpy(out, p);
            }
            free(with);
        }
        else if (op == OP_EQ || op == OP_NE) {
            int same = original->value.is_number == value.is_number && (value.is_number ? original->value.number == value.number : !strcmp(original_text, operand_text));
            result.is_number = 1; result.number = (op == OP_EQ) == same;
        }
        else handled = 0;
        free(original_text); free(operand_text);
        if (handled) {
            value_clear(&value);
            if (!result.is_number && !result.text) goto done;
            if (!assign(&variables, name, &result)) { value_clear(&result); goto done; }
            continue;
        }
        if (!original->value.is_number || (ins->count > 1 && !value.is_number)) { snprintf(message, size, "Numeric operation requires numbers."); value_clear(&value); goto done; }
        double left = original->value.number, right = value.number, answer = 0;
        value_clear(&value);
        switch (op) {
            case OP_ADD: answer = left + right; break; case OP_SUB: answer = left - right; break;
            case OP_MUL: answer = left * right; break;
            case OP_DIV: if (right == 0) { snprintf(message, size, "Division by zero."); goto done; } answer = left / right; break;
            case OP_MOD: if (right == 0) { snprintf(message, size, "Division by zero."); goto done; } answer = fmod(left, right); break;
            case OP_POW: answer = pow(left, right); break;
            case OP_LT: answer = left < right; break; case OP_LE: answer = left <= right; break;
            case OP_GT: answer = left > right; break; case OP_GE: answer = left >= right; break;
            case OP_NOT: answer = !left; break; case OP_AND: answer = left && right; break; case OP_OR: answer = left || right; break;
            case OP_NEG: answer = -left; break; case OP_ABS: answer = fabs(left); break; case OP_ROUND: answer = round(left); break;
            case OP_FLOOR: answer = floor(left); break; case OP_CEIL: answer = ceil(left); break; case OP_SQRT: answer = sqrt(left); break;
            case OP_MIN: answer = fmin(left, right); break; case OP_MAX: answer = fmax(left, right); break;
            case OP_SIN: answer = sin(left); break; case OP_COS: answer = cos(left); break; case OP_TAN: answer = tan(left); break;
            case OP_ASIN: answer = asin(left); break; case OP_ACOS: answer = acos(left); break; case OP_ATAN: answer = atan(left); break;
            case OP_LOG: answer = log(left); break; case OP_LOG10: answer = log10(left); break; case OP_EXP: answer = exp(left); break;
            case OP_SIGN: answer = (left > 0) - (left < 0); break; case OP_TRUNC: answer = trunc(left); break;
            default: snprintf(message, size, "Invalid instruction."); goto done;
        }
        if (!isfinite(answer)) { snprintf(message, size, "The result is not a finite number."); goto done; }
        Value stored = {1, answer, NULL};
        if (!assign(&variables, name, &stored)) goto done;
    }
    ok = 1;
done:
    *ui_total = ui_count;
    vk_ai_destroy(&ai_context);
    vk_game_socket_close(network_socket);
    for (size_t client = 0; client < network_client_count; client++) vk_game_socket_close(network_clients[client]);
#ifdef _WIN32
    if (vk_game_winsock_active) { WSACleanup(); vk_game_winsock_active = 0; }
#endif
    if (!ok && !message[0]) snprintf(message, size, "Out of memory.");
    for (size_t id = 0; id < ui_id_count; id++) free(ui_ids[id]);
    free(ui_ids);
    free(ui_id_types);
    for (size_t i = 0; i < variables.count; i++) { free(variables.items[i].name); value_clear(&variables.items[i].value); }
    free(variables.items);
    release_instructions(code, count);
    return ok;
}

static int read_file(const char *path, Buffer *buffer) {
    FILE *file = fopen(path, "rb");
    if (!file) { perror(path); return 0; }
    unsigned char chunk[4096]; size_t got;
    while ((got = fread(chunk, 1, sizeof(chunk), file)) > 0) {
        if (buffer->size + got > 64u * 1024u * 1024u || !buffer_append(buffer, chunk, got)) { fclose(file); fprintf(stderr, "File too large.\n"); return 0; }
    }
    fclose(file);
    return 1;
}

/* VKLINK/2 carries authenticated, encrypted UTF-8 text; messages are never evaluated as code. */
#define VK_CHAT_MAX_MESSAGE 16384u
typedef struct { VkSocket socket; crypto_secretstream_xchacha20poly1305_state stream; } VkChatReceiver;

static void vk_socket_close(VkSocket socket) {
#ifdef _WIN32
    closesocket(socket);
#else
    close(socket);
#endif
}
static void vk_socket_shutdown(VkSocket socket) {
#ifdef _WIN32
    shutdown(socket, SD_BOTH);
#else
    shutdown(socket, SHUT_RDWR);
#endif
}
static int vk_send_all(VkSocket socket, const void *buffer, size_t length) {
    const char *bytes = buffer;
    while (length) {
#ifdef _WIN32
        int sent = send(socket, bytes, (int)(length > INT_MAX ? INT_MAX : length), 0);
#else
        ssize_t sent = send(socket, bytes, length, 0);
#endif
        if (sent <= 0) return 0;
        bytes += sent;
        length -= (size_t)sent;
    }
    return 1;
}
static int vk_recv_all(VkSocket socket, void *buffer, size_t length) {
    char *bytes = buffer;
    size_t received = 0;
    while (received < length) {
#ifdef _WIN32
        int count = recv(socket, bytes + received, (int)(length - received), 0);
#else
        ssize_t count = recv(socket, bytes + received, length - received, 0);
#endif
        if (count == 0) return received ? -1 : 0;
        if (count < 0) return -1;
        received += (size_t)count;
    }
    return 1;
}
static int vk_send_cipher_frame(VkSocket socket, const unsigned char *cipher, size_t length) {
    if (length > UINT32_MAX) return 0;
    uint32_t size = (uint32_t)length;
    unsigned char header[4] = {(unsigned char)(size >> 24), (unsigned char)(size >> 16), (unsigned char)(size >> 8), (unsigned char)size};
    return vk_send_all(socket, header, sizeof(header)) && vk_send_all(socket, cipher, length);
}
static int vk_send_encrypted(VkSocket socket, crypto_secretstream_xchacha20poly1305_state *stream, const char *text, size_t length, unsigned char tag) {
    if (length > VK_CHAT_MAX_MESSAGE) return 0;
    unsigned char cipher[VK_CHAT_MAX_MESSAGE + crypto_secretstream_xchacha20poly1305_ABYTES];
    unsigned long long cipher_length = 0;
    if (crypto_secretstream_xchacha20poly1305_push(stream, cipher, &cipher_length,
            (const unsigned char *)text, length, NULL, 0, tag) != 0) return 0;
    return vk_send_cipher_frame(socket, cipher, (size_t)cipher_length);
}
static int vk_receive_encrypted(VkSocket socket, crypto_secretstream_xchacha20poly1305_state *stream,
        unsigned char *message, size_t *message_length, unsigned char *tag) {
    unsigned char header[4];
    if (vk_recv_all(socket, header, sizeof(header)) != 1) return 0;
    uint32_t cipher_length = ((uint32_t)header[0] << 24) | ((uint32_t)header[1] << 16) | ((uint32_t)header[2] << 8) | header[3];
    if (cipher_length < crypto_secretstream_xchacha20poly1305_ABYTES ||
            cipher_length > VK_CHAT_MAX_MESSAGE + crypto_secretstream_xchacha20poly1305_ABYTES) return 0;
    unsigned char cipher[VK_CHAT_MAX_MESSAGE + crypto_secretstream_xchacha20poly1305_ABYTES];
    unsigned long long plain_length = 0;
    if (vk_recv_all(socket, cipher, cipher_length) != 1 ||
            crypto_secretstream_xchacha20poly1305_pull(stream, message, &plain_length, tag,
                cipher, cipher_length, NULL, 0) != 0 || plain_length > VK_CHAT_MAX_MESSAGE) return 0;
    *message_length = (size_t)plain_length;
    return 1;
}
static void vk_chat_receive_loop(VkChatReceiver *receiver) {
    for (;;) {
        unsigned char message[VK_CHAT_MAX_MESSAGE + 1], tag = 0;
        size_t length = 0;
        if (!vk_receive_encrypted(receiver->socket, &receiver->stream, message, &length, &tag)) {
            fprintf(stderr, "Encrypted peer message failed authentication or the connection closed.\n");
            break;
        }
        message[length] = '\0';
        if (tag == crypto_secretstream_xchacha20poly1305_TAG_FINAL) break;
        if (!valid_utf8(message, length)) { fprintf(stderr, "Peer sent invalid UTF-8.\n"); break; }
        printf("Peer: %s\n", message);
        fflush(stdout);
    }
}
#ifdef _WIN32
static DWORD WINAPI vk_chat_receiver_thread(LPVOID context) {
    VkChatReceiver *receiver = context;
    vk_chat_receive_loop(receiver);
    return 0;
}
#else
static void *vk_chat_receiver_thread(void *context) {
    VkChatReceiver *receiver = context;
    vk_chat_receive_loop(receiver);
    return NULL;
}
#endif

static int vk_read_passphrase(char passphrase[1024]) {
    const char *environment = getenv("VEKTKOVE_CHAT_PASSPHRASE");
    if (environment) {
        size_t length = strlen(environment);
        if (length < 12 || length >= 1024) { fprintf(stderr, "Chat passphrase must be 12 to 1023 bytes.\n"); return 0; }
        memcpy(passphrase, environment, length + 1);
        return 1;
    }
    fprintf(stderr, "VKLINK passphrase (12+ characters): ");
    fflush(stderr);
#ifdef _WIN32
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    DWORD original_mode = 0;
    int hidden = GetConsoleMode(input, &original_mode) != 0;
    if (hidden && !SetConsoleMode(input, original_mode & ~ENABLE_ECHO_INPUT)) { fprintf(stderr, "Could not disable passphrase echo.\n"); return 0; }
    char *result = fgets(passphrase, 1024, stdin);
    if (hidden) { SetConsoleMode(input, original_mode); fputc('\n', stderr); }
#else
    struct termios original_mode, hidden_mode;
    int hidden = isatty(STDIN_FILENO) && tcgetattr(STDIN_FILENO, &original_mode) == 0;
    if (hidden) {
        hidden_mode = original_mode; hidden_mode.c_lflag &= (tcflag_t)~ECHO;
        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden_mode) != 0) { fprintf(stderr, "Could not disable passphrase echo.\n"); return 0; }
    }
    char *result = fgets(passphrase, 1024, stdin);
    if (hidden) { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original_mode); fputc('\n', stderr); }
#endif
    if (!result) { fprintf(stderr, "Could not read passphrase.\n"); return 0; }
    if (strlen(passphrase) == 1023 && passphrase[1022] != '\n') {
        sodium_memzero(passphrase, 1024);
        fprintf(stderr, "Chat passphrase must be at most 1022 bytes.\n");
        return 0;
    }
    passphrase[strcspn(passphrase, "\r\n")] = '\0';
    size_t length = strlen(passphrase);
    if (length < 12) { sodium_memzero(passphrase, 1024); fprintf(stderr, "Chat passphrase must be at least 12 bytes.\n"); return 0; }
    return 1;
}

static int vk_chat_session(VkSocket socket, int server, const char *passphrase) {
    static const char hello[] = "VKLINK/2\n";
    static const char ready[] = "VKLINK/2 OK\n";
    unsigned char salt[crypto_pwhash_SALTBYTES], master[crypto_secretstream_xchacha20poly1305_KEYBYTES];
    unsigned char send_key[crypto_secretstream_xchacha20poly1305_KEYBYTES], receive_key[crypto_secretstream_xchacha20poly1305_KEYBYTES];
    crypto_secretstream_xchacha20poly1305_state sender, receiver;
    VkChatReceiver receiver_context;
    memset(&sender, 0, sizeof(sender)); memset(&receiver, 0, sizeof(receiver)); memset(&receiver_context, 0, sizeof(receiver_context));
    static const char c2s[] = "VKLINK/2 client to server";
    static const char s2c[] = "VKLINK/2 server to client";
    int connected = 0;
    if (server) {
        char peer_hello[sizeof(hello) - 1];
        randombytes_buf(salt, sizeof(salt));
        if (vk_recv_all(socket, peer_hello, sizeof(peer_hello)) != 1 || memcmp(peer_hello, hello, sizeof(peer_hello)) ||
                !vk_send_all(socket, ready, sizeof(ready) - 1) || !vk_send_all(socket, salt, sizeof(salt))) {
            fprintf(stderr, "Peer does not speak VKLINK/2.\n");
            goto finish;
        }
    } else {
        char response[sizeof(ready) - 1];
        if (!vk_send_all(socket, hello, sizeof(hello) - 1) || vk_recv_all(socket, response, sizeof(response)) != 1 ||
                memcmp(response, ready, sizeof(response)) || vk_recv_all(socket, salt, sizeof(salt)) != 1) {
            fprintf(stderr, "Peer does not speak VKLINK/2.\n");
            goto finish;
        }
    }
    if (crypto_pwhash(master, sizeof(master), passphrase, strlen(passphrase), salt,
                crypto_pwhash_OPSLIMIT_INTERACTIVE, crypto_pwhash_MEMLIMIT_INTERACTIVE,
                crypto_pwhash_ALG_ARGON2ID13) != 0) {
        fprintf(stderr, "Could not derive the VKLINK encryption key.\n");
        goto finish;
    }
    const char *send_label = server ? s2c : c2s;
    const char *receive_label = server ? c2s : s2c;
    if (crypto_generichash(send_key, sizeof(send_key), (const unsigned char *)send_label, strlen(send_label), master, sizeof(master)) != 0 ||
            crypto_generichash(receive_key, sizeof(receive_key), (const unsigned char *)receive_label, strlen(receive_label), master, sizeof(master)) != 0) {
        fprintf(stderr, "Could not derive VKLINK session keys.\n");
        sodium_memzero(master, sizeof(master));
        goto finish;
    }
    sodium_memzero(master, sizeof(master));
    unsigned char send_header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
    unsigned char receive_header[crypto_secretstream_xchacha20poly1305_HEADERBYTES];
    if (crypto_secretstream_xchacha20poly1305_init_push(&sender, send_header, send_key) != 0 ||
            !vk_send_all(socket, send_header, sizeof(send_header)) ||
            vk_recv_all(socket, receive_header, sizeof(receive_header)) != 1 ||
            crypto_secretstream_xchacha20poly1305_init_pull(&receiver, receive_header, receive_key) != 0) {
        fprintf(stderr, "VKLINK encryption setup failed.\n");
        sodium_memzero(send_key, sizeof(send_key)); sodium_memzero(receive_key, sizeof(receive_key));
        goto finish;
    }
    sodium_memzero(send_key, sizeof(send_key)); sodium_memzero(receive_key, sizeof(receive_key));
    static const char auth[] = "VKLINK/2 authenticated";
    if (!vk_send_encrypted(socket, &sender, auth, sizeof(auth) - 1, crypto_secretstream_xchacha20poly1305_TAG_MESSAGE)) {
        fprintf(stderr, "VKLINK authentication failed.\n");
        goto finish;
    }
    unsigned char auth_message[VK_CHAT_MAX_MESSAGE + 1], auth_tag = 0;
    size_t auth_length = 0;
    if (!vk_receive_encrypted(socket, &receiver, auth_message, &auth_length, &auth_tag) ||
            auth_length != sizeof(auth) - 1 || memcmp(auth_message, auth, auth_length) ||
            auth_tag != crypto_secretstream_xchacha20poly1305_TAG_MESSAGE) {
        fprintf(stderr, "Passphrase mismatch or VKLINK authentication failed.\n");
        goto finish;
    }
    connected = 1;
    fprintf(stderr, "Connected using encrypted VKLINK/2 (UTF-8 text only). Enter a message; Ctrl-D/Ctrl-Z ends the chat.\n");
    receiver_context.socket = socket;
    memcpy(&receiver_context.stream, &receiver, sizeof(receiver));
#ifdef _WIN32
    HANDLE thread = CreateThread(NULL, 0, vk_chat_receiver_thread, &receiver_context, 0, NULL);
    if (!thread) { fprintf(stderr, "Could not start chat receiver.\n"); goto finish; }
#else
    pthread_t thread;
    if (pthread_create(&thread, NULL, vk_chat_receiver_thread, &receiver_context) != 0) { fprintf(stderr, "Could not start chat receiver.\n"); goto finish; }
#endif
    char *line = malloc(VK_CHAT_MAX_MESSAGE + 3);
    if (!line) {
        vk_socket_shutdown(socket);
#ifdef _WIN32
        WaitForSingleObject(thread, INFINITE); CloseHandle(thread);
#else
        pthread_join(thread, NULL);
#endif
        goto finish;
    }
    while (fgets(line, VK_CHAT_MAX_MESSAGE + 3, stdin)) {
        size_t length = strlen(line);
        int terminated = length && line[length - 1] == '\n';
        if (terminated) line[--length] = '\0';
        if (length && line[length - 1] == '\r') line[--length] = '\0';
        if (!terminated && !feof(stdin)) {
            int character;
            while ((character = getchar()) != '\n' && character != EOF) {}
            fprintf(stderr, "Message exceeds the %u-byte limit and was discarded.\n", VK_CHAT_MAX_MESSAGE);
            continue;
        }
        if (!valid_utf8((const unsigned char *)line, length)) { fprintf(stderr, "Message is not valid UTF-8.\n"); continue; }
        if (!vk_send_encrypted(socket, &sender, line, length, crypto_secretstream_xchacha20poly1305_TAG_MESSAGE)) break;
        if (length) { printf("You: %s\n", line); fflush(stdout); }
    }
    vk_send_encrypted(socket, &sender, "", 0, crypto_secretstream_xchacha20poly1305_TAG_FINAL);
    free(line);
    vk_socket_shutdown(socket);
#ifdef _WIN32
    WaitForSingleObject(thread, INFINITE); CloseHandle(thread);
#else
    pthread_join(thread, NULL);
#endif
finish:
    vk_socket_close(socket);
    sodium_memzero(master, sizeof(master));
    sodium_memzero(send_key, sizeof(send_key));
    sodium_memzero(receive_key, sizeof(receive_key));
    sodium_memzero(&sender, sizeof(sender));
    sodium_memzero(&receiver, sizeof(receiver));
    sodium_memzero(&receiver_context, sizeof(receiver_context));
    return connected ? 0 : 1;
}

static int vk_chat(int argc, char **argv) {
    if (argc != 5 || (strcmp(argv[2], "listen") && strcmp(argv[2], "connect"))) {
        fprintf(stderr, "Usage: vk chat listen <bind-address> <port> | vk chat connect <host> <port>\n");
        return 1;
    }
    char *end = NULL;
    unsigned long port = strtoul(argv[4], &end, 10);
    if (!end || *end || port == 0 || port > 65535) { fprintf(stderr, "Port must be from 1 to 65535.\n"); return 1; }
    if (sodium_init() < 0) { fprintf(stderr, "libsodium initialization failed.\n"); return 1; }
    char passphrase[1024] = {0};
    if (!vk_read_passphrase(passphrase)) return 1;
#ifdef _WIN32
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) { fprintf(stderr, "Winsock startup failed.\n"); return 1; }
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
#else
    signal(SIGPIPE, SIG_IGN);
#endif
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char port_text[8]; snprintf(port_text, sizeof(port_text), "%lu", port);
    struct addrinfo *addresses = NULL;
    int error = getaddrinfo(argv[3], port_text, &hints, &addresses);
    if (error != 0) {
#ifdef _WIN32
        fprintf(stderr, "Could not resolve address (error %d).\n", error);
        WSACleanup();
#else
        fprintf(stderr, "Could not resolve address: %s\n", gai_strerror(error));
#endif
        sodium_memzero(passphrase, sizeof(passphrase));
        return 1;
    }
    VkSocket peer_socket = VK_INVALID_SOCKET;
    int listening = !strcmp(argv[2], "listen");
    for (struct addrinfo *address = addresses; address; address = address->ai_next) {
        peer_socket = (VkSocket)socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (peer_socket == VK_INVALID_SOCKET) continue;
        if (listening) {
            int reuse = 1;
            setsockopt(peer_socket, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));
            if (bind(peer_socket, address->ai_addr, (int)address->ai_addrlen) == 0 && listen(peer_socket, 1) == 0) break;
        } else if (connect(peer_socket, address->ai_addr, (int)address->ai_addrlen) == 0) break;
        vk_socket_close(peer_socket); peer_socket = VK_INVALID_SOCKET;
    }
    freeaddrinfo(addresses);
    if (peer_socket == VK_INVALID_SOCKET) {
        fprintf(stderr, "Could not %s %s:%s.\n", listening ? "listen on" : "connect to", argv[3], port_text);
#ifdef _WIN32
        WSACleanup();
#endif
    sodium_memzero(passphrase, sizeof(passphrase));
        return 1;
    }
    if (listening) {
    fprintf(stderr, "Waiting for one encrypted VKLINK/2 peer on %s:%s.\n", argv[3], port_text);
        VkSocket peer = (VkSocket)accept(peer_socket, NULL, NULL);
        vk_socket_close(peer_socket);
        if (peer == VK_INVALID_SOCKET) {
            fprintf(stderr, "Accept failed.\n");
#ifdef _WIN32
            WSACleanup();
#endif
            sodium_memzero(passphrase, sizeof(passphrase));
            return 1;
        }
        peer_socket = peer;
    }
    int result = vk_chat_session(peer_socket, listening, passphrase);
    sodium_memzero(passphrase, sizeof(passphrase));
#ifdef _WIN32
    WSACleanup();
#endif
    return result;
}

int main(int argc, char **argv) {
    if (argc == 2 && (!strcmp(argv[1], "--version") || !strcmp(argv[1], "-V"))) {
        puts("Vektkove " VK_VERSION);
        return 0;
    }
    if (argc == 2 && (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h"))) {
        puts("Vektkove " VK_VERSION "\nUsage: vk run file.vk|file.vkb\n       vk compile file.vk out.vkb\n       vk check file.vk\n       vk ast file.vk\n       vk score file.vk\n       vk encode FORMAT [input|-] [output|-]\n       vk decode FORMAT [input|-] [output|-]\n       vk formats\n       vk keyword-count\n       vk chat listen|connect address port\n       vk --version\n\nFORMAT is a codec or a chain such as zstd+base64. UI instructions are validated but require the macOS app to display.");
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "formats")) { puts(vkc_format_list()); return 0; }
    if (argc >= 3 && argc <= 5 && (!strcmp(argv[1], "encode") || !strcmp(argv[1], "decode")))
        return vkc_cli(!strcmp(argv[1], "encode"), argv[2], argc > 3 ? argv[3] : NULL, argc > 4 ? argv[4] : NULL);
    if (argc > 1 && !strcmp(argv[1], "chat")) return vk_chat(argc, argv);
    if (argc == 2 && !strcmp(argv[1], "keyword-count")) {
        size_t base = 0;
        for (size_t i = 0; i < DEFINITION_COUNT; i++) {
            size_t aliases = 0;
            for (const char *p = definitions[i].aliases; *p; p++) if (p == definitions[i].aliases || p[-1] == ' ') aliases++;
            base += aliases * ((definitions[i].opcode == OP_ADD || definitions[i].opcode == OP_IMPORT) ? 1 : 4);
        }
        printf("%zu\n", base);
        return 0;
    }
    if ((argc != 3 || (strcmp(argv[1], "run") && strcmp(argv[1], "check") && strcmp(argv[1], "ast") && strcmp(argv[1], "score"))) && (argc != 4 || strcmp(argv[1], "compile"))) { fprintf(stderr, "Usage: vkport run file.vk|file.vkb | vkport compile file.vk out.vkb | vkport check file.vk | vkport ast file.vk | vkport score file.vk | vkport keyword-count\n"); return 1; }
    Buffer input = {0}; char message[512] = "";
    if (!read_file(argv[2], &input)) return 1;
    Buffer bytecode = {0};
    const char *dot = strrchr(argv[2], '.');
    if (dot && !strcmp(dot, ".vkb") && !strcmp(argv[1], "run")) { bytecode = input; input.data = NULL; }
    else {
        if (!valid_utf8(input.data ? input.data : (const unsigned char *)"", input.size)) { fprintf(stderr, "Source must be UTF-8 text.\n"); return 1; }
        if (!compile_source((const char *)input.data, input.size, &bytecode, message, sizeof(message))) {
            if (!strcmp(argv[1], "score")) { free(input.data); free(bytecode.data); puts("0"); return 0; }
            fprintf(stderr, "%s\n", message); free(input.data); free(bytecode.data); return 1;
        }
    }
    if (!strcmp(argv[1], "score")) { free(input.data); free(bytecode.data); puts("1"); return 0; }
    if (!strcmp(argv[1], "ast")) {
        char *source = copy_text((const char *)(input.data ? input.data : (const unsigned char *)""), input.size);
        char *tree = source ? vk_ai_code_tree(bytecode.data, bytecode.size, source, message, sizeof(message)) : NULL;
        free(source); free(input.data); free(bytecode.data);
        if (!tree) { fprintf(stderr, "%s\n", message[0] ? message : "Out of memory."); return 1; }
        puts(tree); free(tree); return 0;
    }
    free(input.data);
    if (!strcmp(argv[1], "check")) { free(bytecode.data); puts("Syntax OK"); return 0; }
    if (!strcmp(argv[1], "compile")) {
        FILE *file = fopen(argv[3], "wb");
        int ok = file && fwrite(bytecode.data, 1, bytecode.size, file) == bytecode.size && fclose(file) == 0;
        if (!ok) perror(argv[3]);
        free(bytecode.data);
        return ok ? 0 : 1;
    }
    Buffer output = {0}; size_t ui_total = 0;
    int ok = run_bytecode(bytecode.data, bytecode.size, &output, message, sizeof(message), &ui_total);
    /* Like the macOS engine, a failed program produces no output, only the error. */
    if (ok && output.size) fwrite(output.data, 1, output.size, stdout);
    if (!ok) fprintf(stderr, "%s\n", message);
    else if (ui_total) fprintf(stderr, "UI instructions require the Vektkove app.\n");
    free(output.data); free(bytecode.data);
    return ok ? 0 : 1;
}
