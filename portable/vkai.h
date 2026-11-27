#ifndef VKAI_H
#define VKAI_H

#include <stddef.h>

#define VKAI_KNOWLEDGE_LIMIT (256u * 1024u)

typedef struct {
    char *knowledge;
    size_t knowledge_length;
    char backend[16];
    char model[128];
} VKAIContext;

void vk_ai_init(VKAIContext *context);
void vk_ai_destroy(VKAIContext *context);
int vk_ai_configure(VKAIContext *context, const char *backend, const char *model, char *error, size_t error_size);
int vk_ai_add_text(VKAIContext *context, const char *source, const char *text, char *error, size_t error_size);
int vk_ai_add_file(VKAIContext *context, const char *path, char *error, size_t error_size);
int vk_ai_add_url(VKAIContext *context, const char *url, char *error, size_t error_size);
int vk_ai_add_topic(VKAIContext *context, const char *topic, char *error, size_t error_size);
int vk_ai_train(VKAIContext *context, const char *mode, const char *value, char *error, size_t error_size);
char *vk_ai_ask(const VKAIContext *context, const char *question, char *error, size_t error_size);
void vk_ai_clear(VKAIContext *context);

#endif