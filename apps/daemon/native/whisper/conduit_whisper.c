// A small C face on whisper.cpp for conduitd's local speech recognition.
// The daemon binds these few functions through dart:ffi; whisper's own
// structs, whose layout changes between versions, never cross into Dart.

#include <stdlib.h>
#include <string.h>

#include "whisper.h"

#if defined(_WIN32)
#include <windows.h>
#define CW_EXPORT __declspec(dllexport)
static CRITICAL_SECTION cw_lock;
static int cw_lock_ready = 0;
static void cw_enter(void) {
  if (!cw_lock_ready) {
    InitializeCriticalSection(&cw_lock);
    cw_lock_ready = 1;
  }
  EnterCriticalSection(&cw_lock);
}
static void cw_leave(void) { LeaveCriticalSection(&cw_lock); }
#else
#include <pthread.h>
#define CW_EXPORT __attribute__((visibility("default")))
static pthread_mutex_t cw_lock = PTHREAD_MUTEX_INITIALIZER;
static void cw_enter(void) { pthread_mutex_lock(&cw_lock); }
static void cw_leave(void) { pthread_mutex_unlock(&cw_lock); }
#endif

// The model stays loaded between transcriptions: loading one takes longer
// than transcribing a sentence with it.
static struct whisper_context *cw_context = NULL;
static char *cw_model = NULL;

static void cw_quiet(enum ggml_log_level level, const char *text, void *data) {
  (void)level;
  (void)text;
  (void)data;
}

static int cw_load(const char *model_path) {
  if (cw_context != NULL && cw_model != NULL && strcmp(cw_model, model_path) == 0) {
    return 1;
  }
  if (cw_context != NULL) {
    whisper_free(cw_context);
    cw_context = NULL;
  }
  free(cw_model);
  cw_model = NULL;
  whisper_log_set(cw_quiet, NULL);
  struct whisper_context_params params = whisper_context_default_params();
  params.use_gpu = 0;
  cw_context = whisper_init_from_file_with_params(model_path, params);
  if (cw_context == NULL) return 0;
  cw_model = strdup(model_path);
  return 1;
}

// Transcribes [n_samples] of 16 kHz mono audio in [-1, 1]. [language] is an
// ISO code, or NULL or "" to detect it. Returns the text, to be released
// with cw_free, or NULL when the model could not be loaded or run.
CW_EXPORT char *cw_transcribe(const char *model_path, const float *samples, int n_samples,
                              const char *language, int n_threads) {
  cw_enter();
  char *result = NULL;
  if (cw_load(model_path)) {
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = n_threads > 0 ? n_threads : 4;
    params.print_progress = 0;
    params.print_realtime = 0;
    params.print_special = 0;
    params.print_timestamps = 0;
    params.no_timestamps = 1;
    params.translate = 0;
    if (language != NULL && language[0] != '\0') {
      params.language = language;
      params.detect_language = 0;
    } else {
      params.language = "auto";
    }
    if (whisper_full(cw_context, params, samples, n_samples) == 0) {
      const int segments = whisper_full_n_segments(cw_context);
      size_t length = 1;
      for (int i = 0; i < segments; i++) {
        length += strlen(whisper_full_get_segment_text(cw_context, i));
      }
      result = (char *)malloc(length);
      if (result != NULL) {
        result[0] = '\0';
        for (int i = 0; i < segments; i++) {
          strcat(result, whisper_full_get_segment_text(cw_context, i));
        }
      }
    }
  }
  cw_leave();
  return result;
}

CW_EXPORT void cw_free(char *text) { free(text); }

// Lets go of the loaded model, for when the user deletes it.
CW_EXPORT void cw_unload(void) {
  cw_enter();
  if (cw_context != NULL) whisper_free(cw_context);
  cw_context = NULL;
  free(cw_model);
  cw_model = NULL;
  cw_leave();
}
