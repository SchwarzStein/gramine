#include "asm-offsets.h"
#include "sgx_arch.h"

.macro FAIL_LOOP
.Lfail_loop\@:
    jmp .Lfail_loop\@
.endm

.macro CHECK_IF_SIGNAL_STACK_IS_USED stack_reg, label_on_stack, label_out_of_stack
    cmpq %gs:SGX_SIG_STACK_LOW, \stack_reg
    jb \label_out_of_stack
    cmpq %gs:SGX_SIG_STACK_HIGH, \stack_reg
    ja \label_out_of_stack
    jmp \label_on_stack
.endm

.extern Lcssa0_ocall_eexit_prepare, Lcssa0_ocall_eexit_done, __restore_xregs, __save_xregs, Leswitch_ssa0

    .global runtime_internal_handler_entry
    .type runtime_internal_handler_entry, @function
runtime_internal_handler_entry:
    cld

    # RAX -- CSSA
    # CSSA = 1 -- exception happend in runtime, state stored in SSA[0]
    # Store rax for restoring context later
    movq %rax, %r9
    cmpq $0, %rax
    jne .Lruntime_exception_internal

    # CSSA = 0 -- exception happend in program, state stored in USSA
.Lprogram_exception_internal:
    # SGX_UGPR is a base pointer to the USSA.GPRSGX region
    # SGX_USSA is a base pointer to the USSA.XSAVE region
    movq %gs:SGX_UGPR, %rdx
    movq %gs:SGX_USSA, %r15

    # This point signal stack should be null, just switch to it directly
    movq %gs:SGX_SIG_STACK_HIGH, %rsp

.Lset_internal_signal_stack:
    movq %rsp, %rsi
    # If internal interrupt is triggered, skip eraise
    # store SOURCE_SSA.GPR pointer in rbx
    # store SSA[0].GPR pointer in r13
    movq %rdx, %rbx
    # memoize SSA[0].GPRSGX.EXITINFO in r14
    movl SGX_GPR_EXITINFO(%rbx), %r14d
    movq %gs:SGX_GPR, %r13

    # only injected exceptions can be triggered during ocall and eswitch
    # skip the checking here

#define STACK_PADDING_SIZE (PAL_FP_XSTATE_MAGIC2_SIZE + 8)
#define STACK_FRAME_SUB \
    (SGX_CPU_CONTEXT_SIZE + STACK_PADDING_SIZE)
    # If there is a pending signal, stores the context to signal stack then eswitch to the handler
    # Stack layout:
    #     8-bytes padding:    (8 mod 16) bytes aligned for x86 ABI
    #     EXINFO:             16 bytes
    #     sgx_cpu_context_t:  144 bytes
    #     XSAVE area:         PAL_XSTATE_ALIGN=64 bytes aligned
    #     padding:            (if necessary)
    #     RED_ZONE:           (unless newly switching to signal stack)
    movl g_xsave_size(%rip), %eax
    addq $STACK_FRAME_SUB, %rax
    subq %rax, %rsi

    # Disallow too many nested exceptions. In normal Gramine flow, this should never happen. Since
    # addresses need to be canonical, this addition does not overflow.
    movq %gs:SGX_SIG_STACK_HIGH, %rax
    addq %gs:SGX_SIG_STACK_LOW, %rax
    shrq $1, %rax
    cmp %rax, %rsi
    jae 1f
    FAIL_LOOP    
1:
    # Align XSAVE area to 64 bytes after sgx_cpu_context_t
    andq $~(PAL_XSTATE_ALIGN - 1), %rsi
    subq $SGX_CPU_CONTEXT_XSTATE_ALIGN_SUB, %rsi
    # Copy SSA[0].GPRSGX to the CPU context on the stack
    movq SGX_GPR_RAX(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RAX(%rsi)
    movq SGX_GPR_RCX(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RCX(%rsi)
    movq SGX_GPR_RDX(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RDX(%rsi)
    movq SGX_GPR_RBX(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RBX(%rsi)
    movq SGX_GPR_RSP(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RSP(%rsi)
    movq SGX_GPR_RBP(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RBP(%rsi)
    movq SGX_GPR_RSI(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RSI(%rsi)
    movq SGX_GPR_RDI(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RDI(%rsi)
    movq SGX_GPR_R8(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_R8(%rsi)
    movq SGX_GPR_R9(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_R9(%rsi)
    movq SGX_GPR_R10(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_R10(%rsi)
    movq SGX_GPR_R11(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_R11(%rsi)
    movq SGX_GPR_R12(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_R12(%rsi)
    movq SGX_GPR_R13(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_R13(%rsi)
    movq SGX_GPR_R14(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_R14(%rsi)
    movq SGX_GPR_R15(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_R15(%rsi)
    movq SGX_GPR_RFLAGS(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RFLAGS(%rsi)
    movq SGX_GPR_RIP(%rbx), %rdi
    movq %rdi, SGX_CPU_CONTEXT_RIP(%rsi)

    # Rewire SSA0 (args to _PalExceptionRTInternalHandler()):
    #    - trusted EXITINFO             (SSA[0].GPRSGX.EXITINFO, 1st arg)
    #    - event_mask                   (internal error, no external event)
    movq %r14, SGX_GPR_RDI(%r13)
    movq $0, SGX_GPR_RSI(%r13)

    # Continue rewiring SSA0 (args to _PalExceptionRTInternalHandler()):
    #    - pointer to sgx_cpu_context_t (3rd arg)
    #    - pointer to PAL_XREGS_STATE   (4th arg)
    movq %rsi, SGX_GPR_RDX(%r13)
    movq %rsi, SGX_GPR_RCX(%r13)
    addq $SGX_CPU_CONTEXT_SIZE, SGX_GPR_RCX(%r13)

    # Continue rewiring SSA0 (args to _PalExceptionRTInternalHandler()):
    #    - pointer to EXINFO            (5th arg)
    subq $SSA_MISC_EXINFO_SIZE, %rsi
    movq %rsi, SGX_GPR_R8(%r13)

    # Continue rewiring SSA0 (args to _PalExceptionRTInternalHandler()):
    #    - from_runtime                 (6th arg)
    movq %r9, SGX_GPR_R9(%r13)

    # Save EXINFO - it's always immediately before GPR in SSA.
    # If EXINFO MISC component is not enabled, it will contain padding with all 0.
    movq %rbx, %rdi
    subq $SSA_MISC_EXINFO_SIZE, %rdi
    # SSA_MISC_EXINFO_SIZE=16, so we can inline this copy.
    movq 0(%rdi), %rax
    movq %rax, 0(%rsi)
    movq 8(%rdi), %rax
    movq %rax, 8(%rsi)

    # Rewire SSA0: SSA[0].GPRSGX.RSP points to SGX PAL signal stack
    #
    # x86-64 SysV ABI requires 16B alignment of stack before call instruction which implies a (8 mod
    # 16)B alignment on function entry (due to implicit push of RIP). Since we already aligned XSAVE
    # area above, this requirement is satisfied.
    subq $8, %rsi
    movq %rsi, SGX_GPR_RSP(%r13)

    # clear SSA.GPRSGX.EXITINFO; we used it to identify HW exception (if any), and a scenario is
    # possible where the same SSA is re-used to handle more signals that arrive right after this
    # exception, so we must clear state
    movq $0, SGX_GPR_EXITINFO(%r13)

    # Rewire SSA0: modify SSA[0].GPRSGX.RFLAGS:
    #   - clear RFLAGS.DF to conform to the SysV ABI,
    #   - clear RFLAGS.AC to prevent the #AC-fault side channel
    andq $(~(RFLAGS_DF | RFLAGS_AC)), SGX_GPR_RFLAGS(%r13)

    # Rewire SSA0: SSA[0].GPRSGX.RIP points to _PalExceptionRTInternalHandler()
    leaq _PalExceptionRTInternalHandler(%rip), %rdi
    movq %rdi, SGX_GPR_RIP(%r13)

    # copy the whole SSA[0].XSAVE region to the CPU context's XSAVE on stack;
    # __restore_xregs / __save_xregs clobber RDX so need to stash it in RBX
    movq %rdx, %rbx

    # rdi should store the address of SOURCE_SSA.XSAVE
    movq %r15, %rdi
    leaq 1f(%rip), %r11
    jmp __restore_xregs
1:
    leaq SGX_CPU_CONTEXT_SIZE + SSA_MISC_EXINFO_SIZE + 8(%rsi), %rdi
    leaq 2f(%rip), %r11
    jmp __save_xregs
2:
    movq %rbx, %rdx
    jmp .Leswitch_ssa0

.Lruntime_exception_internal:
    # SGX_GPR is a base pointer to the USSA.GPRSGX region
    # SGX_SSA is a base pointer to the USSA.XSAVE region
    movq %gs:SGX_GPR, %rdx
    movq %gs:SGX_SSA, %r15

    movq SGX_GPR_RSP(%rdx), %rsi

    CHECK_IF_SIGNAL_STACK_IS_USED %rsi, .Lsignal_stack_used_internal, .Lsignal_stack_free_internal
.Lsignal_stack_free_internal:
    # If no signal context (rsp = gs:SGX_SIG_STACK_HIGH), do not need red zone
    movq %gs:SGX_SIG_STACK_HIGH, %rsp
    jmp .Lset_internal_signal_stack

.Lsignal_stack_used_internal:
    movq SGX_GPR_RSP(%rdx), %rsp
    subq $RED_ZONE_SIZE, %rsp
    jmp .Lset_internal_signal_stack
