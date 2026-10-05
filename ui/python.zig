//! The embedded CPython interpreter and IPython on top of it. `python_shim.c`
//! starts the interpreter once and leaves it running, so one IPython shell —
//! with one set of variables — answers every session the UI opens.

extern fn run1_ipython() c_int;

/// Opens an interactive IPython session on the terminal and returns its status
/// once it exits — zero when the session ended normally, by Ctrl-D or `exit()`.
/// The caller must have put the terminal back into its normal mode first:
/// IPython reads a cooked tty, not the raw one the TUI draws with.
pub fn embed() c_int {
    return run1_ipython();
}