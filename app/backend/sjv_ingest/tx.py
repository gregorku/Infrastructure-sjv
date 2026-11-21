"""One database transaction for an ingest attempt.

The connection provides ``transaction()``, as psycopg does. On any
exception that transaction is rolled back and the exception propagates.
"""

from contextlib import contextmanager


@contextmanager
def ingest_transaction(conn):
    with conn.transaction():
        yield
