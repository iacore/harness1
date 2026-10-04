#!/usr/bin/env python3
"""Print the API key omp has stored for a provider.

    credentials.py DATABASE PROVIDER

The database is omp's own, `~/.omp/agent/agent.db`; the caller resolves that
path and passes it in, so this needs no environment of its own and says nothing
about where a store lives.

On success the key alone is written to stdout. The exit status is the answer,
so the caller does not have to read stderr to tell one outcome from another:

    0  the key was printed
    1  there is no enabled credential for this provider — not an error
    2  the store could not be read

Only the `key` of the stored credential is printed. A credential omp logs in to
and refreshes, an OAuth token stored under `access`, is not an API key and is
reported as absent.
"""

import json
import sys

NO_CREDENTIAL = 1
UNREADABLE = 2

try:
    import sqlite3
    from urllib.parse import quote
except ImportError as missing:
    # A python without its sqlite3 module cannot read the store at all, which
    # is not the same as a store without a credential in it.
    print(f"credentials: {missing}", file=sys.stderr)
    sys.exit(UNREADABLE)

USAGE = "usage: credentials.py DATABASE PROVIDER"

# `disabled_cause IS NULL` is what makes a credential enabled. The provider is
# bound, never written into the statement.
SQL = """
SELECT data FROM auth_credentials
WHERE provider = ? AND disabled_cause IS NULL
ORDER BY updated_at DESC LIMIT 1
"""


def main(argv):
    if len(argv) != 3:
        print(USAGE, file=sys.stderr)
        return UNREADABLE

    database, provider = argv[1], argv[2]
    try:
        # Read-only, so that a store that is not there is not created by
        # looking for it, and because nothing here ever writes.
        connection = sqlite3.connect(f"file:{quote(database)}?mode=ro", uri=True)
        try:
            row = connection.execute(SQL, (provider,)).fetchone()
        finally:
            connection.close()
    except sqlite3.Error as error:
        print(f"credentials: {database}: {error}", file=sys.stderr)
        return UNREADABLE

    if row is None:
        return NO_CREDENTIAL

    key = json.loads(row[0]).get("key")
    if not key:
        return NO_CREDENTIAL

    print(key)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception:
        # Anything unexpected is a store that could not be read, never a
        # missing credential: exit 1 would report a crash as "not signed in".
        import traceback

        traceback.print_exc()
        sys.exit(UNREADABLE)
