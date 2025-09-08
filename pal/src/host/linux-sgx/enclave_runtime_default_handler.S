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

.extern Lcssa0_ocall_eexit_prepare, Lcssa0_ocall_eexit_done, __restore_xregs, __save_xregs

    .global runtime_default_exception_handler_entry
    .type runtime_default_exception_handler_entry, @function
runtime_default_exception_handler_entry:
    cld

    # RAX -- CSSA
    # CSSA = 1 -- exception happend in runtime, state stored in SSA[0]
    # Store rax for restoring context later
    movq %rax, %r9
    cmpq $0, %rax
    jne .Lruntime_internal_exception

    # CSSA = 0 -- exception happend in program, state stored in USSA
.Lprogram_exception:
    # SGX_UGPR is a base pointer to the USSA.GPRSGX region
    # SGX_USSA is a base pointer to the USSA.XSAVE region
    movq %gs:SGX_UGPR, %rdx
    movq %gs:SGX_USSA, %r15

    # This point signal stack should be null, just switch to it directly
    movq %gs:SGX_SIG_STACK_HIGH, %rsp

.Leraise_exception:
    # Construct a eraise_info structure on signal stack, need to be 16B aligned.
    # Since sig_stack is page aligned, do not need to align the rsp here.
    # typedef struct {
    #     union {
    #         sgx_arch_exit_info_t exitinfo;
    #         uint32_t exitinfo_value;
    #     };
    #     uint32_t errcd;
    #     uint64_t maddr;
    # } sgx_arch_eraise_info_t;

    # rdi now point to MISC_EXINFO
    movq %rdx, %rdi
    sub $SSA_MISC_EXINFO_SIZE, %rdi

    # Push madr
    pushq 0(%rdi)

    # Push errcd << 32 | exitinfo 
    movq 8(%rdi), %rcx
    shlq $32, %rcx
    movl SGX_GPR_EXITINFO(%rdx), %r14d
    orq %r14, %rcx
    pushq %rcx

    movq %rsp, %rbx
    movq $ERAISE, %rax
    enclu

    # eraise_info is useless now
    subq $16, %rsp
    movq %rsp, %rsi

.Lexception_check_signal:
    # If event_mask_page is not initialized, just switch back, do no handle any OS events
    # This should be an early stage that no valid synchronous event can be handled, for 
    # asynchronous events, it is okay to handle it later.
    cmpq $0, %gs:SGX_READY_FOR_EXCEPTIONS
    je .Lno_pending_signal

    # Return from ERESUME, check signal page to see if any signal has been sent by OS
    movq %gs:SGX_EVENT_MASK, %rax
    movq 0(%rax), %r10
    # Clear the event_mask
    movq $0, 0(%rax)
    cmpq $0, %r10
    je .Lno_pending_signal

    # store SOURCE_SSA.GPR pointer in rbx
    # store SSA[0].GPR pointer in r13
    movq %rdx, %rbx
    movq %gs:SGX_GPR, %r13

.Lcheck_during_ocall:
     # Check if interrupted during an ocall case (except OCALL_EXIT), i.e. SGX_PRE_OCALL_STACK is set
    movq %gs:SGX_PRE_OCALL_STACK, %r12
    cmpq $0, %r12
    jne .Lexception_during_ocall_flows

    # If this is not the case, check if OCALL_EXIT has been called. If this is not the case, setup
    # the exception handler for the non-ocall case.
    cmpq $0, %gs:SGX_OCALL_EXIT_CALLED
    je .Lcheck_during_eswitch

    # We are interrupted during the never-returning OCALL_EXIT. Because the thread is going to exit
    # anyway, we can ignore this exception.
    jmp .Lno_pending_signal

    # Check enclave_entry.S for details
.Lexception_during_ocall_flows:
    movq SGX_GPR_RIP(%rbx), %rax
    leaq .Lcssa0_ocall_eexit_prepare(%rip), %r11
    cmpq %r11, %rax
    jb .Lexception_during_ocall_flows_case_c
    leaq .Lcssa0_ocall_eexit_done(%rip), %r11
    cmpq %r11, %rax
    jae .Lexception_during_ocall_flows_case_c

    movq $-EINTR, SGX_GPR_RDI(%rbx)

.Lexception_during_ocall_flows_case_c:
    bsfq %r10, %rdi
    movq %rdi, SGX_GPR_RSI(%rbx)      # external event for .Lcssa0_ocall_return

    leaq .Lcssa0_ocall_return_after_stack_restore(%rip), %rax
    movq %rax, SGX_GPR_RIP(%rbx)

    movq %r12, SGX_GPR_RSP(%rbx)
    movq $0, %gs:SGX_PRE_OCALL_STACK
    andq $(~(RFLAGS_DF | RFLAGS_AC)), SGX_GPR_RFLAGS(%rbx)

    jmp .Lno_pending_signal

.Lcheck_during_eswitch:
    # The restoring of context with eswitch need to be atomic, later exceptions would corrupt the
    # the target ssa. So just set reexecute the function.

    # eswitch will only called inside runtime, so if rbx != r13, the preivous exception is in user
    # just skip the checking
    cmpq %rbx, %r13
    jne .Lset_signal_stack

    movq SGX_GPR_RIP(%rbx), %rax
    leaq .Leswitch_sgx_context_done(%rip), %r11
    cmpq %r11, %rax
    jae .Lset_signal_stack

    leaq .Leswitch_sgx_context_start(%rip), %r11
    cmpq %r11, %rax
    jb .Lset_signal_stack
.Lreset_gpr_rip:
    movq %r11, SGX_GPR_RIP(%rbx)

#define STACK_PADDING_SIZE (PAL_FP_XSTATE_MAGIC2_SIZE + 8)
#define STACK_FRAME_SUB \
    (SGX_CPU_CONTEXT_SIZE + STACK_PADDING_SIZE)
    # If there is a pending signal, stores the context to signal stack then eswitch to the handler
.Lset_signal_stack:
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

    # Rewire SSA0 (args to _PalExceptionRTHandler()):
    #    - trusted EXITINFO             (SSA[0].GPRSGX.EXITINFO, 1st arg)
    #    - event_mask                   (stored in R10)
    movq %r14, SGX_GPR_RDI(%r13)
    movq %r10, SGX_GPR_RSI(%r13)

    # Continue rewiring SSA0 (args to _PalExceptionRTHandler()):
    #    - pointer to sgx_cpu_context_t (3rd arg)
    #    - pointer to PAL_XREGS_STATE   (4th arg)
    movq %rsi, SGX_GPR_RDX(%r13)
    movq %rsi, SGX_GPR_RCX(%r13)
    addq $SGX_CPU_CONTEXT_SIZE, SGX_GPR_RCX(%r13)

    # Continue rewiring SSA0 (args to _PalExceptionRTHandler()):
    #    - pointer to EXINFO            (5th arg)
    subq $SSA_MISC_EXINFO_SIZE, %rsi
    movq %rsi, SGX_GPR_R8(%r13)

    # Continue rewiring SSA0 (args to _PalExceptionRTHandler()):
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

    # Rewire SSA0: SSA[0].GPRSGX.RIP points to _PalExceptionRTHandler()
    leaq _PalExceptionRTHandler(%rip), %rdi
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

.Lruntime_internal_exception:
    # SGX_GPR is a base pointer to the USSA.GPRSGX region
    # SGX_SSA is a base pointer to the USSA.XSAVE region
    movq %gs:SGX_GPR, %rdx
    movq %gs:SGX_SSA, %r15

    movq SGX_GPR_RSP(%rdx), %rsi

    CHECK_IF_SIGNAL_STACK_IS_USED %rsi, .Lsignal_stack_used, .Lsignal_stack_free
.Lsignal_stack_free:
    # If no signal context (rsp = gs:SGX_SIG_STACK_HIGH), do not need red zone
    movq %gs:SGX_SIG_STACK_HIGH, %rsp
    jmp .Leraise_exception

.Lsignal_stack_used:
    movq SGX_GPR_RSP(%rdx), %rsp
    subq $RED_ZONE_SIZE, %rsp
    jmp .Leraise_exception

.Lno_pending_signal:
    # Call eswitch to the previous context
    # If CSSA = 0, then switch back to ussa
    cmpq $0, %r9
    jne .Leswitch_ssa0
.Leswitch_ussa:
    # Store eswitch flag on rbx
    movq $ESWITCH_FLAG_USER, %rbx
    movq $ESWITCH, %rax
    enclu

.global .Leswitch_ssa0
.Leswitch_ssa0:
    # Store eswitch flag on rbx
    xorq %rbx, %rbx
    movq $ESWITCH, %rax
    enclu

# noreturn void _eswitch_sgx_context(uint64_t null1, uint64_t null2, sgx_cpu_context_t* uc
#                                   uint64_t null3, PAL_XREGS_STATE* xsave_area, bool to_runtime);
# Keep rdx, r8 and r9 not overwritten in the function to make it reentrant
# Do not pass parameters by rdi and rsi since movsb need to use rdi, rsi and rcx for copying

    .global _eswitch_sgx_context
    .type _eswitch_sgx_context, @function
_eswitch_sgx_context:
.Leswitch_sgx_context_start:
    .cfi_startproc
    # check to_runtime, decide target ssa 
    cmpq $0, %r9
    jne 1f
    # If to_runtime = false, set:
    # r10 -- pointer to ussa
    # r11 -- pointer to ugpr
    # rbx -- ESWITCH_FLAG_USER
    movq %gs:SGX_USSA, %r10
    movq %gs:SGX_UGPR, %r11
    movq $ESWITCH_FLAG_USER, %rbx
    jmp 2f

    # If to_runtime = true, set:
    # r10 -- pointer to ssa[0]
    # r11 -- pointer to gpr[0]
    # rbx -- 0
1:
    movq %gs:SGX_SSA, %r10
    movq %gs:SGX_GPR, %r11
    movq $0, %rbx
2:
    # copy xsave area
    # get xsave size
    movl g_xsave_size(%rip), %ecx
    movq %r8, %rsi
    movq %r10, %rdi
    rep movsb

    # copy gpr area
    movq $SGX_CPU_CONTEXT_SIZE, %rcx
    movq %rdx, %rsi
    movq %r11, %rdi
    rep movsb

    # gsbase is used for gramine internal usage
    # fsbase is stored in %gs:SGX_FSBASE
    # set fsbase and gsbase
    rdgsbase %rax
    movq %rax, SGX_GPR_GSBASE(%r11)
    movq %gs:SGX_FSBASE, %rax
    movq %rax, SGX_GPR_FSBASE(%r11)

    # call eswitch
    movq $ESWITCH, %rax
    enclu

.Leswitch_sgx_context_done:
    .cfi_endproc


    .global _eswitch_to_user
    .type _eswitch_to_user, @function
_eswitch_to_user:
    movq %gs:SGX_RUNTIME_SIZE, %rax
    cmpq $0, %rax
    je .Lswitch_runtime_disabled
.Lswitch_runtime_enabled:
    movq %gs:SGX_USSA, %rax
    movq %gs:SGX_UGPR, %rbx

    # save rdi
    movq %rdi, %r8

    pushq $0x1F80
    ldmxcsr (%rsp)

    # set ussa xsave area
    movq %rax, %rdi
    leaq 1f(%rip), %r11
    jmp __restore_xregs
1:

    # set ussa gpr
    movq $0, SGX_GPR_RDX(%rbx)
    movq $0x202, SGX_GPR_RFLAGS(%rbx)
    movq %r8, SGX_GPR_RIP(%rbx)
    movq %rsi, SGX_GPR_RSP(%rbx)


    # set $ESWITCH_FLAG_USER to ugpr
    movl $1, (SGX_GPR_EXITINFO + 4)(%rbx)
    # FS and GS will also switch, just save runtime value
    rdfsbase %rax
    movq %rax, SGX_GPR_FSBASE(%rbx)
    rdgsbase %rax
    movq %rax, SGX_GPR_GSBASE(%rbx)
    
    movq $ESWITCH_FLAG_USER, %rbx
    movq $ESWITCH, %rax
    enclu

.Lswitch_runtime_disabled:
    xorq    %rdx, %rdx           # set RDX to 0
    pushq   $0x1F80
    ldmxcsr (%rsp)               # set MXCSR to 0x1F80
    addq    $8, %rsp             # clean stack
    pushq   $0x202
    popfq                        # set lower part of rFLAGS
    movq    %rsi, %rsp           # set stack pointer to second arg
    jmp     *%rdi                # jump to entry point (first arg)

