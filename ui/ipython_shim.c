#include <Python.h>
#include <stdlib.h>
#include <string.h>

// run1's scripting layer: an IPython shell embedded in run1's own process, but
// never owning the terminal. A line runs through the shell and what it prints is
// captured — the caller draws it — and the shell keeps the state, the history
// and the completion, so the command line behaves as IPython's does.
//
// `add_turn` is the step run1's own prompt calls when it is submitted. The
// captured text has its colour escapes stripped: the UI measures cells by
// bytes, so runs of colour would be counted as text.

static int started = 0;

// The module dictionary the setup runs in and the steps are looked up in — the
// same one both times, so a step defined by the setup is a step that can be
// called.
static PyObject *namespace = NULL;

static const char *SETUP =
    "import io, contextlib, re, subprocess, sys, traceback\n"
    "from IPython.core.interactiveshell import InteractiveShell\n"
    "shell = InteractiveShell.instance()\n"
    "def _run1_prompt():\n"
    "    return 'In [%d]: ' % shell.execution_count\n"
    "_ansi = re.compile(r'\\x1b\\[[0-9;?]*[A-Za-z]')\n"
    "_turns = []\n"
    "def add_turn(text):\n"
    "    _turns.append(str(text))\n"
    "shell.user_ns['add_turn'] = add_turn\n"
    "def _run1_fish(command):\n"
    "    done = subprocess.run(['fish', '-c', command], capture_output=True, text=True)\n"
    "    sys.stdout.write(done.stdout)\n"
    "    sys.stderr.write(done.stderr)\n"
    "    return done.returncode\n"
    "shell.user_ns['fish'] = _run1_fish\n"
    "def _run1_fish_call(command):\n"
    "    code, out = _capture(_run1_fish, command)\n"
    "    if code:\n"
    "        out += '[fish exit %d]\\n' % code\n"
    "    return out\n"
    "def _capture(fn, *args):\n"
    "    buf = io.StringIO()\n"
    "    result = None\n"
    "    try:\n"
    "        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):\n"
    "            result = fn(*args)\n"
    "    except BaseException:\n"
    "        traceback.print_exc(file=buf)\n"
    "    return result, _ansi.sub('', buf.getvalue())\n"
    "def _run1_run(code):\n"
    "    _, out = _capture(lambda c: shell.run_cell(shell.transform_cell(c), store_history=True), code)\n"
    "    return out\n"
    "def _run1_complete(line, cursor):\n"
    "    text = line[:cursor]\n"
    "    start = len(text)\n"
    "    while start > 0 and (text[start-1].isalnum() or text[start-1] in '._'):\n"
    "        start -= 1\n"
    "    word = text[start:]\n"
    "    if not word:\n"
    "        return ''\n"
    "    completer = shell.Completer\n"
    "    matches = completer.attr_matches(word) if '.' in word else completer.global_matches(word)\n"
    "    return '\\n'.join(matches)\n"
    "def _run1_history(offset):\n"
    "    hist = shell.history_manager.input_hist_parsed\n"
    "    if offset < 1 or offset >= len(hist):\n"
    "        return ''\n"
    "    return hist[-offset]\n"
    "def _run1_add(text):\n"
    "    _, out = _capture(add_turn, text)\n"
    "    return out\n"
    // The `run1` module: the same steps, under one importable name, for the
    // IPython line and for the python tool alike. What needs the harness
    // itself — its prompt, its turns, a model call — goes through `_run1_host`,
    // the callback the harness registers.
    "import json as _json, sys as _sys, types as _types\n"
    "_run1 = _types.ModuleType('run1')\n"
    "_run1.__doc__ = \"run1: the harness this interpreter is embedded in.\"\n"
    "_run1.fish = _run1_fish_call\n"
    "_run1.system_prompt = lambda: _run1_host('prompt', '') or ''\n"
    "_run1.add_turn = lambda text: _run1_host('add', str(text)) or ''\n"
    "_run1.turns = lambda: _json.loads(_run1_host('turns', '') or '[]')\n"
    "_run1.ask = lambda prompt: _json.loads(_run1_host('ask', str(prompt)) or 'null')\n"
    "_run1.__all__ = ['fish', 'system_prompt', 'add_turn', 'turns', 'ask']\n"
    "_sys.modules['run1'] = _run1\n"
    "shell.user_ns['run1'] = _run1\n";

// The other direction: a Python call that reaches the harness itself. One
// entry point with a method name and an argument keeps the boundary thin — the
// host answers with a JSON string it allocated, or nothing, and the shim frees
// it.
typedef char *(*run1_host_fn)(void *context, const char *method, const char *argument);

static run1_host_fn host = NULL;
static void *host_context = NULL;

void run1_python_set_host(run1_host_fn fn, void *context) {
    host = fn;
    host_context = context;
}

static PyObject *host_call(PyObject *self, PyObject *args) {
    (void)self;
    const char *method;
    const char *argument;
    if (!PyArg_ParseTuple(args, "ss", &method, &argument)) {
        return NULL;
    }
    if (host == NULL) {
        Py_RETURN_NONE;
    }
    char *result = host(host_context, method, argument);
    if (result == NULL) {
        Py_RETURN_NONE;
    }
    PyObject *out = PyUnicode_FromString(result);
    free(result);
    return out;
}

static PyMethodDef host_method = {
    "_run1_host",
    host_call,
    METH_VARARGS,
    "Call into run1: a method name and an argument, answered with JSON.",
};

void run1_python_start(void) {
    if (started) {
        return;
    }
    Py_Initialize();
    namespace = PyModule_GetDict(PyImport_AddModule("__main__"));
    // The setup builds the `run1` module, which reaches the harness through
    // this: a C function placed in the namespace the setup runs in.
    PyObject *host_function = PyCFunction_New(&host_method, NULL);
    if (host_function != NULL) {
        PyDict_SetItemString(namespace, "_run1_host", host_function);
        Py_DECREF(host_function);
    }
    PyObject *result = PyRun_String(SETUP, Py_file_input, namespace, namespace);
    if (result == NULL) {
        PyErr_Print();
    }
    Py_XDECREF(result);
    started = 1;
}

// Returns the captured output of calling `name`, or an empty string. The
// interpreter is started first: building a Python object before `Py_Initialize`
// has run is what a crash here looks like. `mode` is the argument list — 0 is
// one string, 1 is a string and an integer, 2 is one integer.
static char *call(const char *name, const char *text, long number, int mode) {
    run1_python_start();
    PyObject *fn = PyDict_GetItemString(namespace, name);
    if (fn == NULL) {
        fprintf(stderr, "run1: no such step: %s\n", name);
        return strdup("");
    }

    PyObject *result = NULL;
    if (mode == 0) {
        PyObject *text_object = PyUnicode_FromString(text);
        result = PyObject_CallFunctionObjArgs(fn, text_object, NULL);
        Py_XDECREF(text_object);
    } else if (mode == 1) {
        PyObject *text_object = PyUnicode_FromString(text);
        PyObject *number_object = PyLong_FromLong(number);
        result = PyObject_CallFunctionObjArgs(fn, text_object, number_object, NULL);
        Py_XDECREF(text_object);
        Py_XDECREF(number_object);
    } else {
        PyObject *number_object = PyLong_FromLong(number);
        result = PyObject_CallFunctionObjArgs(fn, number_object, NULL);
        Py_XDECREF(number_object);
    }

    if (result == NULL) {
        PyErr_Print();
        return strdup("");
    }
    const char *out = PyUnicode_AsUTF8(result);
    char *output = strdup(out == NULL ? "" : out);
    Py_DECREF(result);
    return output;
}

char *run1_python_run(const char *code) {
    return call("_run1_run", code, 0, 0);
}

char *run1_python_complete(const char *line, int cursor) {
    return call("_run1_complete", line, cursor, 1);
}

char *run1_python_history(int offset) {
    return call("_run1_history", NULL, offset, 2);
}

char *run1_python_fish(const char *command) {
    return call("_run1_fish_call", command, 0, 0);
}

char *run1_python_add_turn(const char *text) {
    return call("_run1_add", text, 0, 0);
}

// The steps above hand back an allocation; this one writes into the caller's
// buffer instead, because the prompt is re-read with every Tab and a copy that
// is thrown away is not worth making.
size_t run1_python_prompt(char *out, size_t capacity) {
    if (capacity == 0) {
        return 0;
    }
    run1_python_start();
    PyObject *fn = PyDict_GetItemString(namespace, "_run1_prompt");
    if (fn == NULL) {
        return 0;
    }
    PyObject *result = PyObject_CallFunctionObjArgs(fn, NULL);
    if (result == NULL) {
        PyErr_Print();
        return 0;
    }
    const char *text = PyUnicode_AsUTF8(result);
    size_t length = text == NULL ? 0 : strlen(text);
    if (length >= capacity) {
        length = capacity - 1;
    }
    if (length != 0) {
        memcpy(out, text, length);
    }
    out[length] = '\0';
    Py_DECREF(result);
    return length;
}

void run1_python_free(char *text) {
    free(text);
}