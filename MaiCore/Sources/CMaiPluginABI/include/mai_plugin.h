#ifndef MAI_PLUGIN_H
#define MAI_PLUGIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MAI_PLUGIN_ABI_VERSION 1
#define MAI_PLUGIN_ENTRY_SYMBOL_V1 "mai_plugin_entry_v1"

typedef uint64_t mai_plugin_operation_id_v1;
typedef void (*mai_plugin_emit_v1)(void *callback_context, const char *event_json);
typedef void (*mai_plugin_complete_v1)(void *callback_context, const char *response_json);

typedef struct mai_plugin_api_v1 {
  uint32_t abi_version;
  const char *manifest_json;
  void *plugin_context;

  /* The plugin must copy request_json before start returns. Callback strings
   * only need to remain valid for the duration of their callback. complete must
   * be called exactly once, including after cancellation. No callback may use
   * callback_context after complete returns. */
  mai_plugin_operation_id_v1 (*start)(
      void *plugin_context,
      const char *request_json,
      void *callback_context,
      mai_plugin_emit_v1 emit,
      mai_plugin_complete_v1 complete);
  void (*cancel)(void *plugin_context, mai_plugin_operation_id_v1 operation_id);
  void (*destroy)(void *plugin_context);
} mai_plugin_api_v1;

typedef const mai_plugin_api_v1 *(*mai_plugin_entry_v1_fn)(void);

uint32_t mai_plugin_abi_version(void);

#ifdef __cplusplus
}
#endif

#endif
