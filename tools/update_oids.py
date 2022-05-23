#!/usr/bin/env python
"""
Update the maps of builtin types and names.

You can update this file by executing it, using the PG* env var to connect
"""

import re
import subprocess as sp
from typing import List
from pathlib import Path

ROOT = Path(__file__).parent.parent


version_sql = """
select format($$
# Generated from PostgreSQL %s.%s
$$,
        setting::int / 10000, setting::int % 100)   -- assume PG >= 10
    from pg_settings
    where name = 'server_version_num'
"""

# Note: "record" is a pseudotype but still a useful one to have.
# "pg_lsn" is a documented public type and useful in streaming replication
# treat "char" (with quotes) separately.
py_types_sql = """
select
    'TypeInfo('
    || array_to_string(array_remove(array[
        format('%L', typname),
        oid::text,
        typarray::text,
        case when oid::regtype::text != typname
            then format('alt_name=%L', oid::regtype)
        end,
        case when typdelim != ','
            then format('delimiter=%L', typdelim)
        end
    ], null), ',')
    || '),'
from pg_type t
where
    oid < 10000
    and oid != '"char"'::regtype
    and (typtype = 'b' or typname = 'record')
    and (typname !~ '^(_|pg_)' or typname = 'pg_lsn')
order by typname
"""

py_ranges_sql = """
select
    format('RangeInfo(%L, %s, %s, subtype_oid=%s),',
        typname, oid, typarray, rngsubtype)
from
    pg_type t
    join pg_range r on t.oid = rngtypid
where
    oid < 10000
    and typtype = 'r'
    and (typname !~ '^(_|pg_)' or typname = 'pg_lsn')
order by typname
"""

py_multiranges_sql = """
select
    format('MultirangeInfo(%L, %s, %s, range_oid=%s, subtype_oid=%s),',
        typname, oid, typarray, rngtypid, rngsubtype)
from
    pg_type t
    join pg_range r on t.oid = rngmultitypid
where
    oid < 10000
    and typtype = 'm'
    and (typname !~ '^(_|pg_)' or typname = 'pg_lsn')
order by typname
"""

cython_oids_sql = """
select format('%s_OID = %s', upper(typname), oid)
from pg_type
where
    oid < 10000
    and (typtype = any('{b,r,m}') or typname = 'record')
    and (typname !~ '^(_|pg_)' or typname = 'pg_lsn')
order by typname
"""


def update_python_oids() -> None:
    queries = [version_sql, py_types_sql, py_ranges_sql, py_multiranges_sql]
    fn = ROOT / "psycopg/psycopg/postgres.py"
    update_file(fn, queries)
    sp.check_call(["black", "-q", fn])


def update_cython_oids() -> None:
    queries = [version_sql, cython_oids_sql]
    fn = ROOT / "psycopg_c/psycopg_c/_psycopg/oids.pxd"
    update_file(fn, queries)


def update_file(fn: Path, queries: List[str]) -> None:
    with fn.open("rb") as f:
        lines = f.read().splitlines()

    new = []
    for query in queries:
        out = sp.run(["psql", "-AXqt", "-c", query], stdout=sp.PIPE, check=True)
        new.extend(out.stdout.splitlines())

    new = [b" " * 4 + line if line else b"" for line in new]  # indent
    istart, iend = [
        i
        for i, line in enumerate(lines)
        if re.match(rb"\s*#\s*autogenerated:\s+(start|end)", line)
    ]
    lines[istart + 1 : iend] = new

    with fn.open("wb") as f:
        f.write(b"\n".join(lines))
        f.write(b"\n")


if __name__ == "__main__":
    update_python_oids()
    update_cython_oids()
