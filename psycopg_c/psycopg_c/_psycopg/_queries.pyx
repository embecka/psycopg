"""
Utility module to manipulate queries
"""

# Copyright (C) 2020 The Psycopg Team

from cpython.ref cimport Py_INCREF
from cpython.tuple cimport PyTuple_New, PyTuple_SET_ITEM

import re
from typing import Any, Dict, List, Mapping, Match, NamedTuple, Optional
from typing import Sequence, Tuple, Union, TYPE_CHECKING
from functools import lru_cache

from psycopg import pq
from psycopg import errors as e
# from psycopg.sql import Composable
from psycopg.abc import Buffer
from psycopg._enums import PyFormat
from psycopg._encodings import conn_encoding

Composable = None  # lazy loaded to avoid circular import


class QueryPart(NamedTuple):
    pre: bytes
    item: Union[int, str]
    format: PyFormat


cdef class PostgresQuery:
    """
    Helper to convert a Python query and parameters into Postgres format.
    """

    cdef readonly bytes query
    cdef readonly object params
    cdef readonly tuple types
    cdef readonly list formats
    cdef Transformer _tx
    cdef list _want_formats
    cdef list _parts
    cdef object _encoding
    cdef list _order

    def __cinit__(self, Transformer transformer):
        self._tx = transformer

        self.params: Optional[Sequence[Optional[Buffer]]] = None
        # these are tuples so they can be used as keys e.g. in prepared stmts
        self.types: Tuple[int, ...] = ()

        # The format requested by the user and the ones to really pass Postgres
        self._want_formats: Optional[List[PyFormat]] = None
        self.formats: Optional[Sequence[pq.Format]] = None

        self._encoding = conn_encoding(transformer.connection)
        self._parts: List[QueryPart]
        self.query = b""
        self._order: Optional[List[str]] = None

    cpdef convert(self, query, vars):
        """
        Set up the query and parameters to convert.

        The results of this function can be obtained accessing the object
        attributes (`query`, `params`, `types`, `formats`).
        """
        global Composable
        if Composable is None:
            from psycopg.sql import Composable

        if isinstance(query, str):
            bquery = query.encode(self._encoding)
        elif isinstance(query, Composable):
            bquery = query.as_bytes(self._tx)
        else:
            bquery = query

        if vars is not None:
            (
                self.query,
                self._want_formats,
                self._order,
                self._parts,
            ) = _query2pg(bquery, self._encoding)
        else:
            self.query = bquery
            self._want_formats = self._order = None

        self.dump(vars)

    cpdef dump(self, vars):
        """
        Process a new set of variables on the query processed by `convert()`.

        This method updates `params` and `types`.
        """
        if vars is not None:
            params = _validate_and_reorder_params(self._parts, vars, self._order)
            assert self._want_formats is not None
            self.params = self._tx.dump_sequence(params, self._want_formats)
            self.types = self._tx.types or ()
            self.formats = self._tx.formats
        else:
            self.params = None
            self.types = ()
            self.formats = None


cdef class PostgresClientQuery(PostgresQuery):
    """
    PostgresQuery subclass merging query and arguments client-side.
    """

    cdef bytes template;

    cpdef convert(self, query, vars):
        """
        Set up the query and parameters to convert.

        The results of this function can be obtained accessing the object
        attributes (`query`, `params`, `types`, `formats`).
        """
        if isinstance(query, str):
            bquery = query.encode(self._encoding)
        elif isinstance(query, Composable):
            bquery = query.as_bytes(self._tx)
        else:
            bquery = query

        if vars is not None:
            (self.template, self._order, self._parts) = _query2pg_client(
                bquery, self._encoding
            )
        else:
            self.query = bquery
            self._order = None

        self.dump(vars)

    cpdef dump(self, vars):
        """
        Process a new set of variables on the query processed by `convert()`.

        This method updates `params` and `types`.
        """
        cdef Py_ssize_t nparams

        if vars is not None:
            params = _validate_and_reorder_params(self._parts, vars, self._order)
            nparams = len(params)
            self.params = p = PyTuple_New(nparams)
            for i in range(nparams):
                item = params[i]
                if item is not None:
                    val = self._tx.as_literal(item)
                else:
                    val = b"NULL"
                Py_INCREF(val)
                PyTuple_SET_ITEM(p, i, val)

            self.query = self.template % self.params
        else:
            self.params = None


#@lru_cache()
#Returns Tuple[bytes, List[PyFormat], Optional[List[str]], List[QueryPart]]:
cdef tuple _query2pg(
    query: bytes, encoding: str
):
    """
    Convert Python query and params into something Postgres understands.

    - Convert Python placeholders (``%s``, ``%(name)s``) into Postgres
      format (``$1``, ``$2``)
    - placeholders can be %s, %t, or %b (auto, text or binary)
    - return ``query`` (bytes), ``formats`` (list of formats) ``order``
      (sequence of names used in the query, in the position they appear)
      ``parts`` (splits of queries and placeholders).
    """
    parts = _split_query(query, encoding)
    order: Optional[List[str]] = None
    chunks: List[bytes] = []
    formats = []

    if isinstance(parts[0].item, int):
        for part in parts[:-1]:
            assert isinstance(part.item, int)
            chunks.append(part.pre)
            chunks.append(b"$%d" % (part.item + 1))
            formats.append(part.format)

    elif isinstance(parts[0].item, str):
        seen: Dict[str, Tuple[bytes, PyFormat]] = {}
        order = []
        for part in parts[:-1]:
            assert isinstance(part.item, str)
            chunks.append(part.pre)
            if part.item not in seen:
                ph = b"$%d" % (len(seen) + 1)
                seen[part.item] = (ph, part.format)
                order.append(part.item)
                chunks.append(ph)
                formats.append(part.format)
            else:
                if seen[part.item][1] != part.format:
                    raise e.ProgrammingError(
                        f"placeholder '{part.item}' cannot have different formats"
                    )
                chunks.append(seen[part.item][0])

    # last part
    chunks.append(parts[-1].pre)

    return b"".join(chunks), formats, order, parts


#Returns Tuple[bytes, Optional[List[str]], List[QueryPart]]
#@lru_cache()
cdef _query2pg_client(
    query: bytes, encoding: str
):
    """
    Convert Python query and params into a template to perform client-side binding
    """
    parts = _split_query(query, encoding, collapse_double_percent=False)
    order: Optional[List[str]] = None
    chunks: List[bytes] = []

    if isinstance(parts[0].item, int):
        for part in parts[:-1]:
            assert isinstance(part.item, int)
            chunks.append(part.pre)
            chunks.append(b"%s")

    elif isinstance(parts[0].item, str):
        seen: Dict[str, Tuple[bytes, PyFormat]] = {}
        order = []
        for part in parts[:-1]:
            assert isinstance(part.item, str)
            chunks.append(part.pre)
            if part.item not in seen:
                ph = b"%s"
                seen[part.item] = (ph, part.format)
                order.append(part.item)
                chunks.append(ph)
            else:
                chunks.append(seen[part.item][0])
                order.append(part.item)

    # last part
    chunks.append(parts[-1].pre)

    return b"".join(chunks), order, parts

#Returns Sequence[Any]
cdef _validate_and_reorder_params(parts, vars, order):
    """
    Verify the compatibility between a query and a set of params.
    """
    # Try concrete types, then abstract types
    t = type(vars)
    if t is list or t is tuple:
        sequence = True
    elif t is dict:
        sequence = False
    elif isinstance(vars, Sequence) and not isinstance(vars, (bytes, str)):
        sequence = True
    elif isinstance(vars, Mapping):
        sequence = False
    else:
        raise TypeError(
            "query parameters should be a sequence or a mapping,"
            f" got {type(vars).__name__}"
        )

    if sequence:
        if len(vars) != len(parts) - 1:
            raise e.ProgrammingError(
                f"the query has {len(parts) - 1} placeholders but"
                f" {len(vars)} parameters were passed"
            )
        if vars and not isinstance(parts[0].item, int):
            raise TypeError("named placeholders require a mapping of parameters")
        return vars  # type: ignore[return-value]

    else:
        if vars and len(parts) > 1 and not isinstance(parts[0][1], str):
            raise TypeError(
                "positional placeholders (%s) require a sequence of parameters"
            )
        try:
            return [vars[item] for item in order or ()]  # type: ignore[call-overload]
        except KeyError:
            raise e.ProgrammingError(
                "query parameter missing:"
                f" {', '.join(sorted(i for i in order or () if i not in vars))}"
            )


_re_placeholder = re.compile(
    rb"""(?x)
        %                       # a literal %
        (?:
            (?:
                \( ([^)]+) \)   # or a name in (braces)
                .               # followed by a format
            )
            |
            (?:.)               # or any char, really
        )
        """
)


#Returns List[QueryPart]
cpdef list _split_query(
    query, encoding = "ascii", collapse_double_percent = True
):
    parts: List[Tuple[bytes, Optional[Match[bytes]]]] = []
    cur = 0

    # pairs [(fragment, match], with the last match None
    m = None
    for m in _re_placeholder.finditer(query):
        pre = query[cur : m.span(0)[0]]
        parts.append((pre, m))
        cur = m.span(0)[1]
    if m:
        parts.append((query[cur:], None))
    else:
        parts.append((query, None))

    rv = []

    # drop the "%%", validate
    i = 0
    phtype = None
    while i < len(parts):
        pre, m = parts[i]
        if m is None:
            # last part
            rv.append(QueryPart(pre, 0, PyFormat.AUTO))
            break

        ph = m.group(0)
        if ph == b"%%":
            # unescape '%%' to '%' if necessary, then merge the parts
            if collapse_double_percent:
                ph = b"%"
            pre1, m1 = parts[i + 1]
            parts[i + 1] = (pre + ph + pre1, m1)
            del parts[i]
            continue

        if ph == b"%(":
            raise e.ProgrammingError(
                "incomplete placeholder:"
                f" '{query[m.span(0)[0]:].split()[0].decode(encoding)}'"
            )
        elif ph == b"% ":
            # explicit messasge for a typical error
            raise e.ProgrammingError(
                "incomplete placeholder: '%'; if you want to use '%' as an"
                " operator you can double it up, i.e. use '%%'"
            )
        elif ph[-1:] not in b"sbt":
            raise e.ProgrammingError(
                "only '%s', '%b', '%t' are allowed as placeholders, got"
                f" '{m.group(0).decode(encoding)}'"
            )

        # Index or name
        item: Union[int, str]
        item = m.group(1).decode(encoding) if m.group(1) else i

        if not phtype:
            phtype = type(item)
        elif phtype is not type(item):
            raise e.ProgrammingError(
                "positional and named placeholders cannot be mixed"
            )

        format = _ph_to_fmt[ph[-1:]]
        rv.append(QueryPart(pre, item, format))
        i += 1

    return rv


_ph_to_fmt = {
    b"s": PyFormat.AUTO,
    b"t": PyFormat.TEXT,
    b"b": PyFormat.BINARY,
}
