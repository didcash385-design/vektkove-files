#include "vkai.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    VKAIContext context;
    char error[256] = {0};
    vk_ai_init(&context);
    if (!vk_ai_configure(&context, "ollama", "example", error, sizeof(error))) return 1;
    if (vk_ai_configure(&context, "invalid", "example", error, sizeof(error))) return 2;
    if (!vk_ai_train(&context, "text", "The sky is blue.", error, sizeof(error))) return 3;
    if (!context.knowledge || !strstr(context.knowledge, "The sky is blue.")) return 4;
    if (vk_ai_add_text(&context, "text", "", error, sizeof(error))) return 5;
    if (vk_ai_train(&context, "invalid", "data", error, sizeof(error))) return 15;
    char *oversized = malloc(VKAI_KNOWLEDGE_LIMIT + 2);
    if (!oversized) return 17;
    memset(oversized, 'x', VKAI_KNOWLEDGE_LIMIT + 1);
    oversized[VKAI_KNOWLEDGE_LIMIT + 1] = '\0';
    if (vk_ai_train(&context, "text", oversized, error, sizeof(error))) { free(oversized); return 18; }
    free(oversized);
    if (!context.knowledge || !strstr(context.knowledge, "The sky is blue.")) return 19;
    vk_ai_clear(&context);
    if (context.knowledge || context.knowledge_length) return 6;
    const char *live_topic = getenv("VEKTKOVE_AI_LIVE_TOPIC");
    if (live_topic && !vk_ai_add_topic(&context, live_topic, error, sizeof(error))) { fprintf(stderr, "%s\n", error); return 16; }
    vk_ai_clear(&context);
    const char *page = getenv("VEKTKOVE_AI_TEST_PAGE");
    if (page) {
        const char *file = getenv("VEKTKOVE_AI_TEST_FILE");
        if (!file || !vk_ai_add_url(&context, page, error, sizeof(error))) { fprintf(stderr, "%s\n", error); return 7; }
        if (!vk_ai_add_topic(&context, "solar power", error, sizeof(error))) { fprintf(stderr, "%s\n", error); return 8; }
        if (!vk_ai_add_file(&context, file, error, sizeof(error))) { fprintf(stderr, "%s\n", error); return 9; }
        if (!vk_ai_add_text(&context, "text", "Quoted \"reference\".\nAnother line.", error, sizeof(error))) return 10;
        if (vk_ai_add_url(&context, "http://example.com/data", error, sizeof(error))) return 11;
        char *answer = vk_ai_ask(&context, "What is \"solar\" power?", error, sizeof(error));
        if (!answer || strcmp(answer, "Ollama answer")) { fprintf(stderr, "%s\n", error); free(answer); return 12; }
        free(answer);
        if (!vk_ai_configure(&context, "openai", "example", error, sizeof(error))) return 13;
        answer = vk_ai_ask(&context, "What is solar power?", error, sizeof(error));
        if (!answer || strcmp(answer, "OpenAI answer")) { fprintf(stderr, "%s\n", error); free(answer); return 14; }
        free(answer);
    }
    vk_ai_destroy(&context);
    puts("AI knowledge tests passed");
    return 0;
}