// This file will be linked only when runtime is flag is set
#include "enclave_runtime_handler.h"
#include "stdint.h"
#include "sgx_arch.h"
#include "pal_linux.h"
#include "pal_linux_defs.h"
#include "pal_tcb.h"
#include "pal_internal.h"

// The pointer cannot be relocated since we don't have a loader for pal, need to store the offset
void (*runtime_syscall_handler_ptr)(void) = 0;

void _PalSyscallHandlerSet(void (*handler)(void)) {
    runtime_syscall_handler_ptr = (void (*)(void))handler;
}

noreturn void _PalSwitchToUser(elf_addr_t entry, void* argp) {
    _eswitch_to_user(entry, argp);
}

bool _PalGetRuntimeEnable(void) {
    return GET_ENCLAVE_TCB(runtime_size) > 0;
}