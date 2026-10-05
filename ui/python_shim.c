#include <Python.h>
#include <stdlib.h>
#include <string.h>

// The scripting layer: CPython embedded in run1's own process, but never owning
// the terminal. One line is evaluated at a time and its output captured — the
// caller shows it in the UI — and the namespace persists between calls, so a
// name set on one line is there on the next.
//
// The steps run1 runs are Python functions defined in SETUP below. `add_turn`
// is the first: what the prompt sends when it is submitted.

static int started = 0;

static const char *SETUP =
    "import io, contextlib, traceback\n"
    "_turns = []\n"
    "def add_turn(text):\n"
    "    _turns.append(str(text))\n"
    "    print('turn added: ' + str(text))\n"
    "def _capture(fn, *args):\n"
    "    buf = io.StringIO()\n"
    "    try:\n"
    "        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):\n"
    "            fn(*args)\n"
    "    except BaseException:\n"
    "        traceback.print_exc(file=buf)\n"
    "    return buf.getvalue()\n"
    "def _run1_eval(code):\n"
    "    buf = io.StringIO()\n"
    "    try:\n"
    "        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):\n"
    "            try:\n"
    "                value = eval(code, globals())\n"
    "            except SyntaxError:\n"
    "                exec(code, globals())\n"
    "            else:\n"
    "                if value is not None:\n"
    "                    print(repr(value))\n"
    "    except BaseException:\n"
    "        traceback.print_exc(file=buf)\n"
    "    return buf.getvalue()\n"
    "def _run1_add(text):\n"
    "    return _capture(add_turn, text)\n";

void run1_python_start(void) {
    if (started) {
        return;
    }
    Py_Initialize();
    PyRun_SimpleString(SETUP);
    started = 1;
}

// Calls the Python function `name` with `text` (or with no argument when `text`
// is NULL) and returns its captured output, or an empty string. The caller
// frees the result with run1_python_free.
static char *call(const char *name, const char *text) {
    run1_python_start();
    PyObject *globals = PyModule_GetDict(PyImport_AddModule("__main__"));
    PyObject *fn = PyDict_GetItemString(globals, name);
    if (fn == NULL) {
        PyErr_Print();
        return strdup("");
    }
    PyObject *argument = text == NULL ? NULL : PyUnicode_FromString(text);
    if (text != NULL && argument == NULL) {
        PyErr_Print();
        return strdup("");
    }
    PyObject *result = PyObject_CallFunctionObjArgs(fn, argument, NULL);
    Py_XDECREF(argument);
    if (result == NULL) {
        PyErr_Print();
        return strdup("");
    }
    const char *text_out = PyUnicode_AsUTF8(result);
    char *output = strdup(text_out == NULL ? "" : text_out);
    Py_DECREF(result);
    return output;
}

char *run1_python_eval(const char *code) {
    return call("_run1_eval", code);
}

char *run1_python_add_turn(const char *text) {
    return call("_run1_add", text);
}

void run1_python_free(char *text) {
    free(text);
}