#ifndef RUNTIME_HANDLER_H
#define RUNTIME_HANDLER_H

extern void (*runtime_default_handler_ptr)(void);
extern void (*runtime_syscall_handler_ptr)(void);

extern void runtime_default_exception_handler_entry(void);
#endif
