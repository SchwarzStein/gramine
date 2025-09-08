.extern runtime_default_exception_handler_entry, runtime_syscall_handler_ptr, runtime_internal_handler_entry

    .section .handler, "ax"
    .align 4096

# rax is cssa, do not use rax for the next jump
.macro HANDLER_DEFAULT_ENTRY name
\name:
    jmp runtime_default_exception_handler_entry
    .zero 128 - (. - \name)
.endm

.macro HANDLER_INTERNAL_ENTRY name
\name:
    jmp runtime_internal_handler_entry
    .zero 128 - (. - \name)
.endm

HANDLER_DEFAULT_ENTRY entry_handler_default
HANDLER_INTERNAL_ENTRY entry_handler_de
HANDLER_DEFAULT_ENTRY entry_handler_db
HANDLER_DEFAULT_ENTRY entry_handler_bp
HANDLER_DEFAULT_ENTRY entry_handler_ud
HANDLER_INTERNAL_ENTRY entry_handler_gp
HANDLER_DEFAULT_ENTRY entry_handler_pf
HANDLER_INTERNAL_ENTRY entry_handler_mf
HANDLER_INTERNAL_ENTRY entry_handler_ac
HANDLER_INTERNAL_ENTRY entry_handler_xf
HANDLER_DEFAULT_ENTRY entry_handler_cp

entry_handler_syscall:
    jmp *runtime_syscall_handler_ptr(%rip)
    .zero 128 - (. - entry_handler_syscall)

    .rept 20
1:
    jmp runtime_default_exception_handler_entry
    .zero 128 - (. - 1b)
    .endr

