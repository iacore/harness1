#include <Python.h>

// Starts CPython once and leaves it running, then opens an IPython session on
// the terminal. The interpreter is deliberately not finalized: a later call
// reuses the same IPython shell, so variables survive between sessions.
//
// The caller must have restored the terminal first — IPython reads a cooked
// tty, not the raw one the TUI draws with.
int run1_ipython(void) {
    if (!Py_IsInitialized()) {
        Py_Initialize();
    }
    return PyRun_SimpleString("import IPython\nIPython.embed()\n");
}