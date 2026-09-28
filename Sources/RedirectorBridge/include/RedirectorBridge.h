#ifndef MR_REDIRECTOR_BRIDGE_H
#define MR_REDIRECTOR_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MREngine MREngine;
// Returned JSON is allocated; caller must mr_string_free. Control calls serialized by caller.
char *mr_inventory_json(void);
void mr_string_free(char *);
MREngine *mr_engine_create(void);
void mr_engine_destroy(MREngine *);
// Start/probe return 0 on success, nonzero on failure; details are written to error.
// Configuration JSON schema is documented in docs/implementation-contract.md.
// start/probe_start return 0 on success, nonzero on failure with error text.
int mr_engine_start(MREngine *, const char *configJSON, char *error, size_t errorSize);
void mr_engine_stop(MREngine *);
void mr_engine_set_channel(MREngine *, uint32_t source, uint32_t channel, float gainDB, float pan, int muted);
void mr_engine_set_master(MREngine *, float forwardDB, float returnDB, int returnMuted);
// Poll on control queue; performs device/heartbeat checks and stops on fault.
char *mr_engine_status_json(MREngine *);
// Capture-only PoC: start tap without opening physical devices or writing output. Config same PC fields.
int mr_engine_probe_start(MREngine *, const char *configJSON, char *error, size_t errorSize);
#ifdef __cplusplus
}
#endif
#endif
