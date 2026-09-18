#!/usr/bin/env python3
"""
nitsql - Multi-Dialect SQL Analyzer (example)

Production-ready static analysis for SQL files across MSSQL, PostgreSQL,
Oracle, MySQL, and SQLite dialects.  Auto-detects the dialect from file
content or accepts a --dialect override.

Usage:
    python analyze_sql.py <file_or_directory>
    python analyze_sql.py --dialect mssql <file>
    python analyze_sql.py --dialect postgresql <file>
    python analyze_sql.py --dialect oracle <file>
    python analyze_sql.py --dialect mysql <file>
    python analyze_sql.py --dialect sqlite <file>
    python analyze_sql.py --all
    python analyze_sql.py --json <file>
    python analyze_sql.py --severity critical <file>
    python analyze_sql.py --fix <file>

Requires: Python 3.8+  (stdlib only -- no external dependencies)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class Dialect(Enum):
    MSSQL = "mssql"
    POSTGRESQL = "postgresql"
    ORACLE = "oracle"
    MYSQL = "mysql"
    SQLITE = "sqlite"
    UNKNOWN = "unknown"


class Severity(Enum):
    CRITICAL = "CRITICAL"
    HIGH = "HIGH"
    MEDIUM = "MEDIUM"
    LOW = "LOW"

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Violation:
    rule_id: str
    severity: Severity
    line_number: int
    line_text: str
    message: str
    suggestion: str
    dialect_specific: bool = False
    fix_text: Optional[str] = None

    def to_dict(self) -> dict:
        d = {
            "rule_id": self.rule_id,
            "severity": self.severity.value,
            "line_number": self.line_number,
            "line_text": self.line_text,
            "message": self.message,
            "suggestion": self.suggestion,
            "dialect_specific": self.dialect_specific,
        }
        if self.fix_text is not None:
            d["fix_text"] = self.fix_text
        return d

# ---------------------------------------------------------------------------
# Helpers: comment / string stripping
# ---------------------------------------------------------------------------

_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
_LINE_COMMENT_RE = re.compile(r"--[^\r\n]*")
# String literal regexes.  Inner alternation handles:
#   [^'\\]   any char other than the quote or a backslash (newlines included)
#   \\.      backslash-escape (PostgreSQL E'..' / MySQL escape strings)
#   ''       doubled-quote escape (SQL Server / standard SQL)
# Without the '' branch, a multi-line string like
#   SET @sql = N'SELECT * FROM OPENQUERY(LINKED_SRV, ''SELECT ...'')'
# would be split into multiple empty strings + raw text, leaving the
# embedded SQL in the clean variant where every other rule mis-fires on it.
_SINGLE_QUOTED_RE = re.compile(r"'(?:[^'\\]|\\.|'')*'")
_DOUBLE_QUOTED_RE = re.compile(r'"(?:[^"\\]|\\.|"")*"')
_DOLLAR_QUOTED_RE = re.compile(r"\$\$.*?\$\$", re.DOTALL)
_BACKTICK_QUOTED_RE = re.compile(r"`[^`]*`")


def _strip_block_comments(text: str) -> str:
    """Remove /* ... */ block comments, preserving line count."""
    def _replace(m):  # type: ignore[override]
        return "\n" * m.group(0).count("\n")
    return _BLOCK_COMMENT_RE.sub(_replace, text)


def _strip_line_comments(text: str) -> str:
    """Remove -- line comments."""
    return _LINE_COMMENT_RE.sub("", text)


def _strip_string_literals(text: str) -> str:
    """Replace string literals with a placeholder to avoid false positives.

    IMPORTANT: Dollar-quoted blocks ($$...$$) in PostgreSQL contain executable
    code (function/procedure bodies), NOT string data.  We must NOT strip them
    or the analyzer will be blind to violations inside PL/pgSQL bodies.
    We only strip single-quoted, double-quoted, and backtick-quoted literals.
    """
    text = _SINGLE_QUOTED_RE.sub("'__STR__'", text)
    text = _DOUBLE_QUOTED_RE.sub("'__STR__'", text)
    text = _BACKTICK_QUOTED_RE.sub("`__ID__`", text)
    return text


def _prepare_content(raw: str) -> Tuple[str, List[str], str, List[str]]:
    """Return (clean_content, clean_lines, raw_content, raw_lines).

    *clean* variants have comments and string literals removed so that
    pattern matching doesn't fire on commented-out code or string constants.
    *raw* variants keep the original text for display purposes.
    Line counts are preserved across both variants.
    """
    # Normalise line endings
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    raw_lines = raw.split("\n")

    clean = _strip_block_comments(raw)
    clean = _strip_line_comments(clean)
    clean = _strip_string_literals(clean)
    clean_lines = clean.split("\n")

    return clean, clean_lines, raw, raw_lines


# ---------------------------------------------------------------------------
# Pragma escape hatches and contextual demotion
# ---------------------------------------------------------------------------
#
# Line pragma:   -- nitsql:ignore             (suppress all rules on this line)
#                -- nitsql:ignore=SA0002      (suppress one rule)
#                -- nitsql:ignore=SA0002,SA-MS007  (suppress multiple)
# File pragma:   -- nitsql:ignore-file        (suppress all rules in file)
#                -- nitsql:ignore-file=SA0002 (suppress one rule in file)
#
# The pragma is matched against the RAW (un-stripped) line so it survives
# _strip_line_comments removing the comment text from the clean variant.

_IGNORE_FILE_PRAGMA_RE = re.compile(
    r"--\s*(?:nitsql|sql-valid8)\s*:\s*ignore-file(?:\s*=\s*([A-Za-z0-9_\-,\s]+))?",
    re.IGNORECASE,
)
_IGNORE_LINE_PRAGMA_RE = re.compile(
    r"--\s*(?:nitsql|sql-valid8)\s*:\s*ignore(?!\s*-file)(?:\s*=\s*([A-Za-z0-9_\-,\s]+))?",
    re.IGNORECASE,
)


def _parse_pragma_ids(group_text):  # type: (Optional[str]) -> set
    """Parse a comma-separated rule id list. Empty -> {'*'} (wildcard)."""
    if not group_text:
        return {"*"}
    ids = set()
    for token in group_text.split(","):
        token = token.strip()
        if token:
            ids.add(token)
    return ids if ids else {"*"}


def _collect_pragmas(raw_lines):  # type: (List[str]) -> Tuple[Dict[int, set], set]
    """Scan raw lines for ignore pragmas.

    Returns (per_line_ignores, file_ignores) where per_line_ignores maps a
    1-based line number to a set of rule ids (or {'*'} for all rules), and
    file_ignores is the union of file-level pragmas anywhere in the file.
    """
    per_line = {}  # type: Dict[int, set]
    file_ignores = set()  # type: set
    for i, line in enumerate(raw_lines, 1):
        m_file = _IGNORE_FILE_PRAGMA_RE.search(line)
        if m_file:
            file_ignores |= _parse_pragma_ids(m_file.group(1))
            continue
        m_line = _IGNORE_LINE_PRAGMA_RE.search(line)
        if m_line:
            existing = per_line.get(i, set())
            per_line[i] = existing | _parse_pragma_ids(m_line.group(1))
    return per_line, file_ignores


def _is_ignored(rule_id, line_number, per_line, file_ignores):
    # type: (str, int, Dict[int, set], set) -> bool
    if "*" in file_ignores or rule_id in file_ignores:
        return True
    rules = per_line.get(line_number)
    if rules and ("*" in rules or rule_id in rules):
        return True
    return False


# Linked-server dynamic SQL patterns -- T-SQL has no sp_executesql variant
# that supports passing parameters across a linked-server boundary, so
# SQL-injection findings on these patterns can't be remediated by ordinary
# parameterisation. We still flag them, but at HIGH instead of CRITICAL so
# legacy passthrough code (the cloud data warehouse via third-party, etc.) doesn't block CI.
#
# Patterns recognised:
#   EXEC (@var) AT [server]           -- direct linked-server EXEC
#   OPENQUERY(<server>, '<query>')    -- pass-through query (query is opaque
#                                        text at the T-SQL level)
#   OPENROWSET('<provider>', ...)     -- similar pass-through
_LINKED_SERVER_EXEC_RE = re.compile(
    r"\b(?:EXEC|EXECUTE)\s*\(\s*@\w+\s*\)\s+AT\s+\[?\w+\]?",
    re.IGNORECASE,
)
_OPENQUERY_RE = re.compile(r"\bOPENQUERY\s*\(", re.IGNORECASE)
_OPENROWSET_RE = re.compile(r"\bOPENROWSET\s*\(", re.IGNORECASE)


def _file_has_linked_server_exec(content):  # type: (str) -> bool
    if _LINKED_SERVER_EXEC_RE.search(content):
        return True
    if _OPENQUERY_RE.search(content):
        return True
    if _OPENROWSET_RE.search(content):
        return True
    return False


# ---------------------------------------------------------------------------
# CTE name extraction (used by SA0008 to avoid flagging CTE refs as
# unqualified table references).
# ---------------------------------------------------------------------------
#
# Recognises:
#   WITH cte_name AS ( ... )
#   WITH cte_name (col1, col2) AS ( ... )
#   ), next_cte AS ( ... )
#   ), next_cte (col1) AS ( ... )

_CTE_WITH_RE = re.compile(
    r"\bWITH\s+(\w+)(?:\s*\([^()]*\))?\s+AS\s*\(",
    re.IGNORECASE,
)
_CTE_CONT_RE = re.compile(
    r"\)\s*,\s*(\w+)(?:\s*\([^()]*\))?\s+AS\s*\(",
    re.IGNORECASE,
)


def _extract_cte_names(content):  # type: (str) -> set
    names = set()
    for m in _CTE_WITH_RE.finditer(content):
        names.add(m.group(1).upper())
    for m in _CTE_CONT_RE.finditer(content):
        names.add(m.group(1).upper())
    return names

# ---------------------------------------------------------------------------
# Dialect detection
# ---------------------------------------------------------------------------

class DialectDetector:
    """Score-based SQL dialect detection from file content."""

    # Weighted markers: (pattern, weight)
    _MSSQL_MARKERS: List[Tuple[str, int]] = [
        (r"\bSET\s+NOCOUNT\b", 5),
        (r"@@IDENTITY\b", 4),
        (r"\bsp_executesql\b", 5),
        (r"\bIDENTITY\s*\(", 4),
        (r"\bBEGIN\s+TRY\b", 5),
        (r"\bXACT_ABORT\b", 5),
        (r"\bTOP\s+\d+\b", 3),
        (r"\bNVARCHAR\b", 3),
        (r"\bsys\.dm_", 5),
        (r"\bGETDATE\s*\(\s*\)", 4),
        (r"\bVARCHAR\s*\(\s*MAX\s*\)", 3),
        (r"\bBEGIN\s+CATCH\b", 5),
        (r"\bWITH\s*\(\s*NOLOCK\s*\)", 5),
    ]

    _POSTGRESQL_MARKERS: List[Tuple[str, int]] = [
        (r"\bDO\s+\$\$", 6),
        (r"::\w+", 4),
        (r"\bRETURNING\b", 4),
        (r"\bILIKE\b", 5),
        (r"~\s*'", 3),
        (r"\$\$\s*LANGUAGE\b", 6),
        (r"\bCREATE\s+OR\s+REPLACE\s+FUNCTION\b", 4),
        (r"\bSERIAL\b", 4),
        (r"\bNOW\s*\(\s*\)", 3),
        (r"\bGENERATED\s+(ALWAYS|BY\s+DEFAULT)\s+AS\s+IDENTITY\b", 5),
        (r"\bCONCURRENTLY\b", 5),
        (r"--\s*Target:\s*PostgreSQL", 8),
    ]

    _ORACLE_MARKERS: List[Tuple[str, int]] = [
        (r"\bDBMS_\w+\.", 6),
        (r"\bNVL\s*\(", 4),
        (r"\bSYSDATE\b", 4),
        (r":=", 5),
        (r"^\s*/\s*$", 4),
        (r"\bPRAGMA\b", 5),
        (r"\bRAISE_APPLICATION_ERROR\b", 6),
        (r"\bVARCHAR2\b", 6),
        (r"\bNUMBER\s*\(", 4),
        (r"\bROWNUM\b", 5),
        (r"\bCONNECT\s+BY\b", 6),
        (r"--\s*Target:\s*Oracle", 8),
    ]

    _MYSQL_MARKERS: List[Tuple[str, int]] = [
        (r"\bDELIMITER\s+//", 6),
        (r"\bENGINE\s*=\s*InnoDB\b", 6),
        (r"\bAUTO_INCREMENT\b", 5),
        (r"`\w+`", 3),
        (r"\bIFNULL\s*\(", 4),
        (r"\bSIGNAL\s+SQLSTATE\b", 6),
        (r"\bLAST_INSERT_ID\s*\(\s*\)", 5),
        (r"\bENGINE\s*=", 4),
        (r"\bENUM\s*\(", 3),
        (r"\bINT\s+UNSIGNED\b", 4),
        (r"\bON\s+DUPLICATE\s+KEY\s+UPDATE\b", 6),
        (r"\bSTRAIGHT_JOIN\b", 5),
        (r"\bSQL_CALC_FOUND_ROWS\b", 5),
        (r"\bGROUP_CONCAT\s*\(", 4),
        (r"--\s*Target:\s*MySQL", 8),
    ]

    _SQLITE_MARKERS: List[Tuple[str, int]] = [
        (r"\bPRAGMA\s+\w+", 6),
        (r"\bAUTOINCREMENT\b", 7),
        (r"\btypeof\s*\(", 5),
        (r"\bsqlite_master\b", 8),
        (r"\bsqlite_sequence\b", 7),
        (r"^\s*\.\w+", 5),                     # dot commands (.mode, .headers, etc.)
        (r"\bGLOB\s+'", 5),
        (r"\bGLOB\s+\?", 4),
        (r"\bINTEGER\s+PRIMARY\s+KEY\b", 4),
        (r"\bPRAGMA\s+journal_mode\b", 7),
        (r"\bPRAGMA\s+foreign_keys\b", 7),
        (r"\bPRAGMA\s+busy_timeout\b", 6),
        (r"\bPRAGMA\s+wal_checkpoint\b", 6),
        (r"\bsqlite_version\s*\(\s*\)", 8),
        (r"--\s*Target:\s*SQLite", 8),
    ]

    @classmethod
    def detect(cls, content: str, filepath: Optional[str] = None) -> Dialect:
        scores = {
            Dialect.MSSQL: 0,
            Dialect.POSTGRESQL: 0,
            Dialect.ORACLE: 0,
            Dialect.MYSQL: 0,
            Dialect.SQLITE: 0,
        }

        # Filename-based hints (boost score when filename contains dialect clue)
        if filepath:
            fname = str(filepath).lower()
            if "mssql" in fname or "tsql" in fname:
                scores[Dialect.MSSQL] += 10
            if "postgresql" in fname or "postgres" in fname or "pgsql" in fname:
                scores[Dialect.POSTGRESQL] += 10
            if "oracle" in fname or "plsql" in fname:
                scores[Dialect.ORACLE] += 10
            if "mysql" in fname or "mariadb" in fname:
                scores[Dialect.MYSQL] += 10
            if "sqlite" in fname or "lite" in fname:
                scores[Dialect.SQLITE] += 10
            # File extension hints
            if fname.endswith(".sqlite") or fname.endswith(".db"):
                scores[Dialect.SQLITE] += 8

        for pattern, weight in cls._MSSQL_MARKERS:
            if re.search(pattern, content, re.IGNORECASE | re.MULTILINE):
                scores[Dialect.MSSQL] += weight

        for pattern, weight in cls._POSTGRESQL_MARKERS:
            if re.search(pattern, content, re.IGNORECASE | re.MULTILINE):
                scores[Dialect.POSTGRESQL] += weight

        for pattern, weight in cls._ORACLE_MARKERS:
            if re.search(pattern, content, re.IGNORECASE | re.MULTILINE):
                scores[Dialect.ORACLE] += weight

        for pattern, weight in cls._MYSQL_MARKERS:
            if re.search(pattern, content, re.IGNORECASE | re.MULTILINE):
                scores[Dialect.MYSQL] += weight

        for pattern, weight in cls._SQLITE_MARKERS:
            if re.search(pattern, content, re.IGNORECASE | re.MULTILINE):
                scores[Dialect.SQLITE] += weight

        best = max(scores, key=lambda d: scores[d])
        if scores[best] == 0:
            return Dialect.UNKNOWN
        return best

# ---------------------------------------------------------------------------
# Reserved words list (shared across dialects)
# ---------------------------------------------------------------------------

_SQL_RESERVED_WORDS = {
    "SELECT", "INSERT", "UPDATE", "DELETE", "FROM", "WHERE", "ORDER",
    "TABLE", "INDEX", "VIEW", "PROCEDURE", "FUNCTION", "TRIGGER",
    "DATABASE", "SCHEMA", "USER", "ROLE", "GRANT", "REVOKE",
    "PRIMARY", "FOREIGN", "KEY", "CONSTRAINT", "DEFAULT", "NULL",
    "AND", "OR", "NOT", "IN", "EXISTS", "BETWEEN", "LIKE", "AS",
    "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "ON",
    "GROUP", "HAVING", "DISTINCT", "TOP", "PERCENT", "WITH",
    "UNION", "EXCEPT", "INTERSECT", "ALL", "ANY", "SOME",
    "BEGIN", "END", "IF", "ELSE", "WHILE", "RETURN", "CASE",
    "WHEN", "THEN", "SET", "DECLARE", "EXEC", "EXECUTE",
    "COMMIT", "ROLLBACK", "TRANSACTION", "IDENTITY", "COLUMN",
    "ALTER", "DROP", "CREATE", "ADD", "VALUES", "INTO", "GO",
    "LIMIT", "OFFSET", "FETCH", "NEXT", "ROWS", "ONLY",
}

# ---------------------------------------------------------------------------
# SQLAnalyzer
# ---------------------------------------------------------------------------

class SQLAnalyzer:
    """Multi-dialect SQL analyzer with 52 checks across 5 dialects."""

    def __init__(self, dialect: Optional[Dialect] = None, show_fixes: bool = False):
        self.forced_dialect = dialect
        self.dialect = Dialect.UNKNOWN  # type: Dialect
        self.violations = []  # type: List[Violation]
        self.show_fixes = show_fixes
        # Per-file context, reset at the start of every analyze_file call.
        self.has_linked_server_exec = False
        self.cte_names = set()  # type: set

    # -- public API ----------------------------------------------------------

    def analyze_file(self, filepath: Path) -> Tuple[Dialect, List[Violation]]:
        """Analyze a single SQL file.  Returns (detected_dialect, violations)."""
        self.violations = []

        path = Path(filepath)
        if not path.is_file():
            print("Error: File not found: {}".format(filepath), file=sys.stderr)
            return (Dialect.UNKNOWN, [])

        raw = path.read_text(encoding="utf-8", errors="ignore")
        clean, clean_lines, raw_content, raw_lines = _prepare_content(raw)

        # Per-file context used by individual rules (pre-computed once).
        # Linked-server detection uses RAW content because OPENQUERY /
        # OPENROWSET are commonly embedded inside a dynamic-SQL string
        # literal (`SET @sql = N'... OPENQUERY(server, ...)'`) which gets
        # replaced with a placeholder in the clean variant.
        self.has_linked_server_exec = _file_has_linked_server_exec(raw_content)
        self.cte_names = _extract_cte_names(clean)

        # Detect or override dialect
        if self.forced_dialect is not None and self.forced_dialect != Dialect.UNKNOWN:
            self.dialect = self.forced_dialect
        else:
            self.dialect = DialectDetector.detect(raw_content, filepath=str(path))

        # Universal checks (all dialects)
        self._run_universal_checks(clean, clean_lines, raw_lines)

        # Dialect-specific checks
        if self.dialect == Dialect.MSSQL:
            self._run_mssql_checks(clean, clean_lines, raw_lines)
        elif self.dialect == Dialect.POSTGRESQL:
            self._run_postgresql_checks(clean, clean_lines, raw_lines)
        elif self.dialect == Dialect.ORACLE:
            self._run_oracle_checks(clean, clean_lines, raw_lines)
        elif self.dialect == Dialect.MYSQL:
            self._run_mysql_checks(clean, clean_lines, raw_lines)
        elif self.dialect == Dialect.SQLITE:
            self._run_sqlite_checks(clean, clean_lines, raw_lines)

        # Apply ignore pragmas (line-level and file-level escape hatches).
        # Pragmas come from RAW lines because line-comments are stripped from
        # the clean variant before pattern matching.
        per_line_ignores, file_ignores = _collect_pragmas(raw_lines)
        if per_line_ignores or file_ignores:
            self.violations = [
                v for v in self.violations
                if not _is_ignored(v.rule_id, v.line_number,
                                   per_line_ignores, file_ignores)
            ]

        return (self.dialect, list(self.violations))

    # =====================================================================
    # UNIVERSAL CHECKS (SA0001 - SA0019)
    # =====================================================================

    def _run_universal_checks(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        self._check_sa0001_select_star(lines, raw_lines)
        self._check_sa0002_sql_injection(lines, raw_lines)
        self._check_sa0003_non_sargable(lines, raw_lines)
        self._check_sa0004_leading_wildcard(lines, raw_lines)
        self._check_sa0005_count_vs_exists(content, lines, raw_lines)
        self._check_sa0006_insert_no_columns(lines, raw_lines)
        self._check_sa0007_cursor_usage(lines, raw_lines)
        self._check_sa0008_schema_not_qualified(lines, raw_lines)
        self._check_sa0009_special_chars(lines, raw_lines)
        self._check_sa0010_reserved_word_ids(lines, raw_lines)
        self._check_sa0011_nullable_expr(lines, raw_lines)
        self._check_sa0012_nondeterministic_where(lines, raw_lines)
        self._check_sa0013_implicit_type_conversion(lines, raw_lines)
        self._check_sa0014_column_arithmetic_both_sides(lines, raw_lines)
        self._check_sa0015_missing_where(content, lines, raw_lines)
        self._check_sa0016_union_vs_union_all(content, lines, raw_lines)
        self._check_sa0017_order_by_in_subquery(content, lines, raw_lines)
        self._check_sa0018_correlated_subquery(content, lines, raw_lines)
        self._check_sa0019_nested_subqueries(content, lines, raw_lines)

    # -- SA0001 SELECT * ---------------------------------------------------

    def _check_sa0001_select_star(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        select_star_re = re.compile(r"\bSELECT\s+\*", re.IGNORECASE)
        exists_re = re.compile(r"\bEXISTS\s*\(\s*SELECT\s+\*", re.IGNORECASE)
        count_star_re = re.compile(r"\bCOUNT\s*\(\s*\*\s*\)", re.IGNORECASE)

        for i, line in enumerate(lines, 1):
            if not select_star_re.search(line):
                continue
            if exists_re.search(line):
                continue
            if count_star_re.search(line):
                continue
            self.violations.append(Violation(
                rule_id="SA0001",
                severity=Severity.HIGH,
                line_number=i,
                line_text=raw_lines[i - 1].strip(),
                message="SELECT * used in production query",
                suggestion="List specific columns: SELECT col1, col2, col3",
                fix_text="Replace SELECT * with explicit column list (e.g. SELECT col1, col2, col3 FROM ...)",
            ))

    # -- SA0002 SQL injection via string concatenation ---------------------

    def _check_sa0002_sql_injection(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        patterns = [
            # MSSQL: EXEC(@variable)
            (r"\bEXEC\s*\(\s*@\w+\s*\)", "EXEC with variable -- use sp_executesql"),
            # String concatenation with + or ||
            (r"['\"].*\+\s*@\w+\s*\+.*['\"]",
             "String concatenation with variable in dynamic SQL"),
            (r"\|\|\s*\w+\s*\|\|",
             "String concatenation (||) in dynamic SQL"),
            # Oracle: EXECUTE IMMEDIATE with ||
            (r"\bEXECUTE\s+IMMEDIATE\b.*\|\|",
             "EXECUTE IMMEDIATE with concatenation"),
            # MySQL / PostgreSQL: PREPARE with CONCAT
            (r"\bPREPARE\b.*\bCONCAT\b",
             "PREPARE with CONCAT -- use parameterised query"),
            # MySQL: SET @sql = CONCAT(... with user input for dynamic SQL
            (r"\bSET\s+@\w+\s*=\s*CONCAT\s*\(",
             "CONCAT used to build dynamic SQL -- use prepared statement with ?"),
            # Triple-quote injection trick
            (r"'''\s*\+\s*@\w+\s*\+\s*'''",
             "Quotes around concatenated variable"),
        ]

        # Contexts where || concatenation is safe (debug output, not dynamic SQL)
        safe_concat_re = re.compile(
            r"\b(?:DBMS_OUTPUT|UTL_FILE|RAISE\s+(?:NOTICE|INFO|WARNING|DEBUG|LOG|EXCEPTION)"
            r"|HTP\.P|DBMS_LOB|PUT_LINE|SQL%BULK_EXCEPTIONS|RAISE_APPLICATION_ERROR)\b",
            re.IGNORECASE,
        )
        # Patterns that specifically flag || concatenation
        concat_pats = {
            r"\|\|\s*\w+\s*\|\|",
            r"\bEXECUTE\s+IMMEDIATE\b.*\|\|",
        }

        # When the file uses `EXEC (@sql) AT [linked_server]`, T-SQL has no
        # sp_executesql equivalent that supports AT linked_server, so the
        # canonical "use parameterised queries" suggestion is not actionable.
        # Demote SA0002 from CRITICAL to HIGH for the file in that case and
        # annotate the message so reviewers know the context.
        demote_for_linked_server = self.has_linked_server_exec

        for i, line in enumerate(lines, 1):
            for pat, desc in patterns:
                if re.search(pat, line, re.IGNORECASE):
                    # Skip || concatenation in debug/output contexts (not SQL injection)
                    # Check current line AND a few preceding lines for context
                    if pat in concat_pats:
                        ctx_start = max(0, i - 4)
                        ctx_block = " ".join(raw_lines[ctx_start:i])
                        if safe_concat_re.search(ctx_block):
                            continue
                    severity = Severity.CRITICAL
                    message_desc = desc
                    if demote_for_linked_server:
                        severity = Severity.HIGH
                        message_desc += (
                            " (linked-server EXEC: sp_executesql does not "
                            "support AT linked_server; consider input validation "
                            "or nitsql:ignore pragma)"
                        )
                    self.violations.append(Violation(
                        rule_id="SA0002",
                        severity=severity,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="SQL injection risk -- {}".format(message_desc),
                        suggestion="Use parameterised queries (sp_executesql, $1, :bind, ?)",
                        fix_text="Replace string concatenation with parameterised query using bind variables",
                    ))
                    break  # one hit per line

    # -- SA0003 Non-SARGable predicates ------------------------------------

    def _check_sa0003_non_sargable(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # We look for function calls on columns within WHERE / AND / OR
        ctx = r"(?:\bWHERE\b|\bAND\b|\bOR\b)"
        fn_patterns = [
            (ctx + r".*\bYEAR\s*\(\s*[\w.]+", "YEAR() on column"),
            (ctx + r".*\bMONTH\s*\(\s*[\w.]+", "MONTH() on column"),
            (ctx + r".*\bUPPER\s*\(\s*[\w.]+", "UPPER() on column"),
            (ctx + r".*\bLOWER\s*\(\s*[\w.]+", "LOWER() on column"),
            (ctx + r".*\bLEFT\s*\(\s*[\w.]+", "LEFT() on column"),
            (ctx + r".*\bCONVERT\s*\(\s*\w+\s*,\s*[\w.]+", "CONVERT() on column"),
            (ctx + r".*\bCAST\s*\(\s*[\w.]+\s+AS\b", "CAST() on column"),
            (ctx + r".*\bSUBSTRING\s*\(\s*[\w.]+", "SUBSTRING() on column"),
            (ctx + r".*\bRIGHT\s*\(\s*[\w.]+", "RIGHT() on column"),
            (ctx + r".*\bDATENAME\s*\(\s*\w+\s*,\s*[\w.]+", "DATENAME() on column"),
            (ctx + r".*\bTO_CHAR\s*\(\s*[\w.]+", "TO_CHAR() on column"),
            (ctx + r".*\bTRUNC\s*\(\s*[\w.]+", "TRUNC() on column"),
            (ctx + r".*\bNVL\s*\(\s*[\w.]+", "NVL() on column"),
            (ctx + r".*\bIFNULL\s*\(\s*[\w.]+", "IFNULL() on column"),
        ]

        for i, line in enumerate(lines, 1):
            for pat, desc in fn_patterns:
                if re.search(pat, line, re.IGNORECASE):
                    self.violations.append(Violation(
                        rule_id="SA0003",
                        severity=Severity.HIGH,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="Non-SARGable predicate: {} prevents index usage".format(
                            desc
                        ),
                        suggestion="Rewrite to avoid wrapping columns in functions inside WHERE",
                        fix_text="Move function to the right side of the comparison or use a computed column/index",
                    ))
                    break

    # -- SA0004 Leading wildcard LIKE '%...' --------------------------------

    def _check_sa0004_leading_wildcard(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        raw_pat = re.compile(r"\bI?LIKE\s+[N]?'%", re.IGNORECASE)
        concat_pat = re.compile(r"\bI?LIKE\s+'%'\s*\+", re.IGNORECASE)
        concat_pat2 = re.compile(r"\bI?LIKE\s+'%'\s*\|\|", re.IGNORECASE)
        concat_pat3 = re.compile(r"\bI?LIKE\s+CONCAT\s*\(\s*'%'", re.IGNORECASE)

        for i, line in enumerate(lines, 1):
            raw_line = raw_lines[i - 1] if i <= len(raw_lines) else ""
            hit = False
            if raw_pat.search(raw_line):
                hit = True
            elif concat_pat.search(raw_line) or concat_pat2.search(raw_line):
                hit = True
            elif concat_pat3.search(raw_line):
                hit = True
            if hit:
                self.violations.append(Violation(
                    rule_id="SA0004",
                    severity=Severity.HIGH,
                    line_number=i,
                    line_text=raw_line.strip(),
                    message="LIKE with leading wildcard '%...' prevents index usage",
                    suggestion="Use full-text search or redesign query to avoid leading wildcards",
                    fix_text="Replace LIKE '%value' with full-text search (CONTAINS/MATCH) or reverse-index strategy",
                ))

    # -- SA0005 COUNT(*) > 0 instead of EXISTS ------------------------------

    def _check_sa0005_count_vs_exists(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Flag COUNT(*) used for an existence check (EXISTS short-circuits).

        Tight pattern set to keep false positives low:
          - Direct: `COUNT(*) > 0` (and >=, =, <>, != 0) on a single line.
          - Subquery comparison `) > 0` where a COUNT(*) appears on the
            same line OR the immediately-preceding line (window of 1).
            The previous version's wider 3- and 8-line windows produced
            cross-statement false positives in long procedures.
          - The variable-compare heuristic (`IF @cnt > 0`) was removed
            entirely -- it required parser-level reasoning to correlate
            with the SELECT COUNT(*) assignment and was unreliable.
        """
        direct_re = re.compile(
            r"\bCOUNT\s*\(\s*\*\s*\)\s*(?:>|>=|=|<>|!=)\s*0\b", re.IGNORECASE
        )
        count_lines = set()  # type: set
        for i, line in enumerate(lines, 1):
            if re.search(r"\bCOUNT\s*\(\s*\*\s*\)", line, re.IGNORECASE):
                count_lines.add(i)

        subq_re = re.compile(r"\)\s*(?:>|>=|=|<>|!=)\s*0\b")

        for i, line in enumerate(lines, 1):
            matched = False
            if direct_re.search(line):
                matched = True
            elif subq_re.search(line):
                if i in count_lines or (i - 1) in count_lines:
                    matched = True
            if matched:
                self.violations.append(Violation(
                    rule_id="SA0005",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="COUNT(*) used for existence check -- EXISTS stops at first row",
                    suggestion="Use IF EXISTS (SELECT 1 FROM ...) instead",
                    fix_text="Replace COUNT(*) > 0 with EXISTS (SELECT 1 FROM ... WHERE ...)",
                ))

    # -- SA0006 INSERT without explicit column list -------------------------

    def _check_sa0006_insert_no_columns(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Single-line: INSERT INTO table VALUES (
        single_pat = re.compile(
            r"\bINSERT\s+INTO\s+[\w.\[\]`\"]+\s+VALUES\s*\(", re.IGNORECASE
        )
        # Multi-line: INSERT INTO table\n  VALUES (
        insert_pat = re.compile(
            r"\bINSERT\s+INTO\s+([\w.\[\]`\"]+)\s*$", re.IGNORECASE
        )
        values_pat = re.compile(r"^\s*VALUES\s*\(", re.IGNORECASE)

        for i, line in enumerate(lines, 1):
            if single_pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA0006",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="INSERT without explicit column list -- fragile on schema changes",
                    suggestion="Always specify columns: INSERT INTO tbl (col1, col2) VALUES (...)",
                    fix_text="Add column list: INSERT INTO table_name (col1, col2, ...) VALUES (...)",
                ))
            elif insert_pat.search(line):
                # Check if next non-empty line is VALUES (without column list)
                for j in range(i, min(i + 3, len(lines))):
                    next_line = lines[j].strip()
                    if not next_line:
                        continue
                    if values_pat.search(next_line):
                        self.violations.append(Violation(
                            rule_id="SA0006",
                            severity=Severity.MEDIUM,
                            line_number=i,
                            line_text=raw_lines[i - 1].strip(),
                            message="INSERT without explicit column list -- fragile on schema changes",
                            suggestion="Always specify columns: INSERT INTO tbl (col1, col2) VALUES (...)",
                            fix_text="Add column list: INSERT INTO table_name (col1, col2, ...) VALUES (...)",
                        ))
                    break  # Only check the first non-empty line after INSERT

    # -- SA0007 Cursor usage ------------------------------------------------

    def _check_sa0007_cursor_usage(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        patterns = [
            re.compile(r"\bDECLARE\s+\w+\s+CURSOR\b", re.IGNORECASE),
            re.compile(r"\bFOR\s+\w+\s+IN\s*\(", re.IGNORECASE),
            re.compile(r"\bOPEN\s+\w+\s*;", re.IGNORECASE),
        ]
        for i, line in enumerate(lines, 1):
            for pat in patterns:
                if pat.search(line):
                    self.violations.append(Violation(
                        rule_id="SA0007",
                        severity=Severity.HIGH,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="Cursor usage detected -- prefer set-based operations",
                        suggestion="Replace cursor logic with set-based UPDATE/INSERT/DELETE",
                        fix_text="Rewrite as a single set-based SQL statement (UPDATE ... FROM, INSERT ... SELECT, etc.)",
                    ))
                    break

    # -- SA0008 Schema not qualified ----------------------------------------

    def _check_sa0008_schema_not_qualified(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Flag unqualified table refs after FROM/JOIN.

        Skips:
          - Temp tables (#name, ##name) and table variables (@name)
          - Trigger pseudo-tables (inserted, deleted, EXCLUDED, OLD, NEW)
          - CTE names extracted from WITH clauses anywhere in the file
          - SQL keywords that may appear after FROM/JOIN contextually

        Iterates EVERY FROM/JOIN occurrence per line via finditer, so a
        line like `FROM ipm.X v1 INNER JOIN inserted v2` is inspected
        once per target (not just the first).
        """
        pseudo_tables = {
            "INSERTED", "DELETED",        # MSSQL triggers
            "EXCLUDED", "OLD", "NEW",     # PG / row triggers
            "DUAL",                        # Oracle
            "INFORMATION_SCHEMA",
        }
        follow_keywords = {
            "SELECT", "WHERE", "SET", "VALUES", "AS", "ON",
            "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS",
            "JOIN", "APPLY", "LATERAL", "USING", "WITH", "ORDER", "GROUP",
        }
        # Capture a possibly-qualified identifier after FROM / JOIN, e.g.
        #   FROM svc.Subscriber          -> captures `svc.Subscriber`
        #   FROM Foo                    -> captures `Foo`
        #   FROM #stat                  -> captures `#stat`
        #   FROM [dbo].[Table] alias    -> captures `[dbo].[Table]`
        # The trailing word-boundary lookahead `(?=\s|,|;|\)|\(|$|--)`
        # anchors the end of the identifier so the engine can't backtrack
        # `\w*` to match only a prefix and then claim the rest is "after"
        # the identifier (which produced false positives like
        # `FROM svc.Subscriber` matching `s`).
        join_re = re.compile(
            r"\b(?:FROM|JOIN)\s+"
            r"(\[?[#@]{0,2}[A-Za-z_]\w*\]?(?:\.\[?\w+\]?)*)"
            r"(?=\s|,|;|\)|\(|$|--)",
            re.IGNORECASE,
        )

        for i, line in enumerate(lines, 1):
            for m in join_re.finditer(line):
                raw_ref = m.group(1)
                # Already-qualified (contains a dot) -> skip.
                if "." in raw_ref:
                    continue
                # Strip identifier delimiters for classification
                ref = raw_ref.strip("[]\"`")
                if not ref:
                    continue
                # Temp tables / table variables
                if ref.startswith("#") or ref.startswith("@"):
                    continue
                upper = ref.upper()
                if upper in pseudo_tables:
                    continue
                if upper in follow_keywords:
                    continue
                if upper in self.cte_names:
                    continue
                self.violations.append(Violation(
                    rule_id="SA0008",
                    severity=Severity.LOW,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="Table reference may not be schema-qualified",
                    suggestion="Use schema-qualified names: schema.TableName",
                    fix_text="Prefix table with schema name: dbo.{} or public.{}".format(
                        ref, ref
                    ),
                ))

    # -- SA0009 Special characters in object names --------------------------

    def _check_sa0009_special_chars(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Bracketed identifiers with problematic characters
        bracket_re = re.compile(
            r"\[[\w]*[^A-Za-z0-9_\[\]\s][\w]*\]"
        )
        for i, line in enumerate(lines, 1):
            if bracket_re.search(line):
                self.violations.append(Violation(
                    rule_id="SA0009",
                    severity=Severity.LOW,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="Object name contains special characters requiring delimiters",
                    suggestion="Use only letters, numbers, and underscores in identifiers",
                    fix_text="Rename object to use only [A-Za-z0-9_] characters",
                ))

    # -- SA0010 Reserved words as identifiers --------------------------------

    def _check_sa0010_reserved_word_ids(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        escaped = "|".join(re.escape(w) for w in _SQL_RESERVED_WORDS)
        alias_re = re.compile(
            r"\bAS\s+[\[`\"]?(" + escaped + r")[\]`\"]?\b", re.IGNORECASE
        )
        for i, line in enumerate(lines, 1):
            m = alias_re.search(line)
            if m:
                word = m.group(1)
                self.violations.append(Violation(
                    rule_id="SA0010",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="Reserved word '{}' used as identifier".format(word),
                    suggestion="Avoid using SQL reserved words as column or object names",
                    fix_text="Rename '{}' to a non-reserved name (e.g. '{}_{}_name')".format(
                        word, word.lower(), "col"
                    ),
                ))

    # -- SA0011 Nullable column in expression without null-safe fn ----------

    def _check_sa0011_nullable_expr(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        r"""Flag arithmetic on identifier operands aliased with AS, when no
        null-safe wrapper (ISNULL / COALESCE / NVL / IFNULL) is present.

        Requires at least one operand to be a qualified column reference
        (`alias.column`) so plain literal arithmetic like `a + 1 AS n` and
        simple variable math don't fire. The earlier looser pattern
        `\w+ [+\-*/] \w+ AS` matched far too broadly.
        """
        arith_re = re.compile(
            r"(?:\w+\.\w+\s*[+\-*/]\s*(?:\w+\.)?\w+"
            r"|\w+\s*[+\-*/]\s*\w+\.\w+)"
            r"\s+AS\s+\w+",
            re.IGNORECASE,
        )
        safe_re = re.compile(
            r"\b(?:ISNULL|COALESCE|NVL|IFNULL)\s*\(", re.IGNORECASE
        )
        for i, line in enumerate(lines, 1):
            if arith_re.search(line) and not safe_re.search(line):
                self.violations.append(Violation(
                    rule_id="SA0011",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="Arithmetic on potentially nullable column without null-safe function",
                    suggestion="Wrap nullable columns with COALESCE/ISNULL/NVL before arithmetic",
                    fix_text="Wrap column with COALESCE(column_name, 0) before performing arithmetic",
                ))

    # -- SA0012 Non-deterministic function in WHERE -------------------------

    def _check_sa0012_nondeterministic_where(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        ctx = r"(?:\bWHERE\b|\bAND\b|\bOR\b)"
        fn_pats = [
            r"\bGETDATE\s*\(\s*\)",
            r"\bNOW\s*\(\s*\)",
            r"\bSYSDATE\b",
            r"\bCURRENT_TIMESTAMP\b",
            r"\bSYSDATETIME\s*\(\s*\)",
            r"\bUTC_TIMESTAMP\s*\(\s*\)",
            r"\bNEWID\s*\(\s*\)",
            r"\bRAND\s*\(\s*\)",
            r"\bSYS_GUID\s*\(\s*\)",
        ]
        combined = ctx + r".*(?:" + "|".join(fn_pats) + r")"
        pat = re.compile(combined, re.IGNORECASE)

        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA0012",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="Non-deterministic function in WHERE evaluated per row",
                    suggestion="Extract the function result into a variable before the query",
                    fix_text="Assign the function result to a variable first, then use the variable in WHERE",
                ))

    # -- SA0013 Implicit type conversion risk --------------------------------

    def _check_sa0013_implicit_type_conversion(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Flag narrowing CAST/CONVERT that could lose data.

        Only matches when CAST(...) AS smaller-int / CONVERT(smaller-int, ...)
        is on the line.  The earlier "INT keyword co-occurring with TINYINT
        keyword on the same line" heuristic was deleted because it matched
        CREATE TABLE column lists (`(c1 INT, c2 TINYINT)`) which are
        definitions, not conversions, generating a flood of false positives.
        """
        narrow_pats = [
            (r"\bCAST\s*\([^)]*\bAS\s+(?:TINYINT|SMALLINT)\s*\)",
             "Potential data loss from CAST to smaller integer type"),
            (r"\bCONVERT\s*\(\s*(?:TINYINT|SMALLINT)\s*,",
             "Potential data loss from CONVERT to smaller integer type"),
            (r"\bCAST\s*\([^)]*\bFLOAT\b[^)]*\bAS\s+(?:INT|BIGINT|DECIMAL)\s*[(,)]",
             "Potential data loss from FLOAT CAST to integer/decimal"),
        ]
        for i, line in enumerate(lines, 1):
            for pat, msg in narrow_pats:
                if re.search(pat, line, re.IGNORECASE):
                    self.violations.append(Violation(
                        rule_id="SA0013",
                        severity=Severity.HIGH,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message=msg,
                        suggestion="Use explicit CAST/CONVERT with range validation",
                        fix_text="Add range validation before narrowing conversion or use a wider target type",
                    ))
                    break

    # -- SA0014 Column arithmetic on both sides of comparison ---------------

    def _check_sa0014_column_arithmetic_both_sides(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Only flag arithmetic on the LEFT side of comparisons (prevents index usage).
        # Arithmetic on the RIGHT side (e.g., >= CURRENT_DATE - INTERVAL) is fine.
        ctx_pats = [
            r"\bWHERE\b.*\w+\s*[+\-*/]\s*\w+\s*[><=!]",
            r"\bAND\b.*\w+\s*[+\-*/]\s*\w+\s*[><=!]",
        ]
        # Exclude known constant expressions on the left side
        safe_left_re = re.compile(
            r"(?:CURRENT_DATE|CURRENT_TIMESTAMP|NOW\s*\(\)|GETDATE\s*\(\)|SYSDATE|SYSTIMESTAMP"
            r"|DATEADD|DATEDIFF|DATE_SUB|DATE_ADD)\s*[+\-*/]",
            re.IGNORECASE,
        )
        var_re = re.compile(r"[@:$]\w+\s*[+\-*/]")

        for i, line in enumerate(lines, 1):
            for pat in ctx_pats:
                if re.search(pat, line, re.IGNORECASE):
                    # Skip parameterised expressions and constant date arithmetic
                    if not var_re.search(line) and not safe_left_re.search(line):
                        self.violations.append(Violation(
                            rule_id="SA0014",
                            severity=Severity.MEDIUM,
                            line_number=i,
                            line_text=raw_lines[i - 1].strip(),
                            message="Column arithmetic in WHERE prevents index usage",
                            suggestion="Isolate column on one side: 'col > y * x' instead of 'col / x > y'",
                            fix_text="Rearrange: move column alone to one side of the operator",
                        ))
                        break

    # -- SA0015 Missing WHERE clause on UPDATE/DELETE (CRITICAL) -----------

    def _check_sa0015_missing_where(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Detect UPDATE or DELETE statements without a WHERE clause.

        Scans for UPDATE ... SET or DELETE FROM blocks and checks whether a
        WHERE clause appears before the statement terminates (semicolon or
        next DML keyword).  Correctly skips:
          - TRUNCATE TABLE (intentional full-table wipe)
          - DELETE with JOIN (the JOIN itself acts as a filter)
          - UPDATE with JOIN/FROM (same reasoning)
        """
        # Match the start of UPDATE or DELETE statements
        # Exclude Oracle DDL: UPDATE INDEXES, UPDATE GLOBAL INDEXES, UPDATE LOCAL INDEXES
        update_re = re.compile(r"^\s*UPDATE\b(?!\s+(?:GLOBAL\s+|LOCAL\s+)?INDEXES\b)", re.IGNORECASE)
        delete_re = re.compile(r"^\s*DELETE\b", re.IGNORECASE)
        where_re = re.compile(r"\bWHERE\b", re.IGNORECASE)
        join_re = re.compile(r"\bJOIN\b", re.IGNORECASE)
        from_re = re.compile(r"\bFROM\b", re.IGNORECASE)
        # Patterns that indicate UPDATE/DELETE is part of MERGE/UPSERT (not standalone)
        merge_ctx_re = re.compile(
            r"\bMERGE\b|\bWHEN\s+(?:NOT\s+)?MATCHED\b|\bDO\s+UPDATE\s+SET\b"
            r"|\bON\s+CONFLICT\b|\bON\s+DUPLICATE\s+KEY\b",
            re.IGNORECASE,
        )
        # Terminators: semicolon, GO, next DML
        terminator_re = re.compile(
            r";\s*$|^\s*GO\s*$|^\s*(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)\b",
            re.IGNORECASE,
        )

        i = 0
        while i < len(lines):
            line = lines[i]
            stmt_start = -1
            is_delete = False

            if update_re.search(line):
                stmt_start = i
            elif delete_re.search(line):
                stmt_start = i
                is_delete = True

            if stmt_start < 0:
                i += 1
                continue

            # Skip UPDATE clauses that are part of MERGE/UPSERT/ON CONFLICT
            in_merge = False
            lookback = max(0, stmt_start - 10)
            for k in range(lookback, stmt_start + 1):
                if merge_ctx_re.search(lines[k]):
                    in_merge = True
                    break
            if in_merge:
                i += 1
                continue

            # Scan forward to find WHERE, JOIN, or end-of-statement
            # Track parenthesis depth so subquery keywords aren't mistaken for terminators
            found_where = False
            found_join = False
            paren_depth = 0
            j = stmt_start
            while j < min(stmt_start + 50, len(lines)):
                scan_line = lines[j]
                # Check keywords BEFORE updating depth (WHERE may share a line with '(')
                depth_before = paren_depth
                # WHERE/JOIN at the statement level (depth 0) counts as the filter
                if where_re.search(scan_line) and depth_before <= 0:
                    found_where = True
                    break
                if join_re.search(scan_line) and depth_before <= 0:
                    found_join = True
                    break
                # For UPDATE ... FROM (MSSQL pattern), the FROM acts as a filter context
                if not is_delete and j > stmt_start and from_re.search(scan_line) and depth_before <= 0:
                    found_join = True
                    break
                # Now update depth for this line
                paren_depth += scan_line.count("(") - scan_line.count(")")
                # Check for terminator only at statement level (not inside subqueries)
                if j > stmt_start and paren_depth <= 0 and terminator_re.search(scan_line):
                    break
                # Single-line statement ending with ;
                if j == stmt_start and scan_line.rstrip().endswith(";"):
                    break
                j += 1

            if not found_where and not found_join:
                self.violations.append(Violation(
                    rule_id="SA0015",
                    severity=Severity.CRITICAL,
                    line_number=stmt_start + 1,
                    line_text=raw_lines[stmt_start].strip(),
                    message="UPDATE/DELETE without WHERE clause affects ALL rows in the table",
                    suggestion="Add a WHERE clause to limit affected rows, or use TRUNCATE TABLE for intentional full wipe",
                    fix_text="Add WHERE clause: ... WHERE <condition>",
                ))

            i = j + 1 if j > stmt_start else i + 1

    # -- SA0016 UNION without UNION ALL when duplicates are impossible ------

    def _check_sa0016_union_vs_union_all(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Detect UNION (without ALL) which forces an expensive DISTINCT sort.

        If the branches already return distinct rows (e.g. different literal
        values, different table sources with no overlap), UNION ALL is cheaper.
        We flag every bare UNION as a potential issue since the developer should
        consciously decide whether dedup is needed.
        """
        # Match UNION that is NOT followed by ALL
        # Must be careful not to match inside UNION ALL
        union_bare_re = re.compile(r"\bUNION\b(?!\s+ALL\b)", re.IGNORECASE)

        for i, line in enumerate(lines, 1):
            if union_bare_re.search(line):
                self.violations.append(Violation(
                    rule_id="SA0016",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="UNION forces duplicate elimination sort -- use UNION ALL if duplicates are impossible",
                    suggestion="Replace UNION with UNION ALL when result sets are already distinct",
                    fix_text="Replace UNION with UNION ALL (if duplicates cannot occur between branches)",
                ))

    # -- SA0017 ORDER BY in subqueries without TOP/LIMIT/FETCH -------------

    def _check_sa0017_order_by_in_subquery(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Detect ORDER BY inside subqueries that lack TOP/LIMIT/FETCH/OFFSET.

        In most dialects, ORDER BY in a subquery without a row-limiting clause
        is meaningless (the optimizer may ignore it) and adds overhead.
        """
        # Find subquery openings: ( SELECT
        subq_open_re = re.compile(r"\(\s*SELECT\b", re.IGNORECASE)
        top_limit_re = re.compile(
            r"\bTOP\s+\d+|\bLIMIT\b|\bFETCH\s+(?:FIRST|NEXT)\b|\bOFFSET\b|\bROW_NUMBER\s*\(",
            re.IGNORECASE,
        )
        order_by_re = re.compile(r"\bORDER\s+BY\b", re.IGNORECASE)

        for i, line in enumerate(lines, 1):
            if not subq_open_re.search(line):
                continue

            # Scan forward to find matching closing paren, tracking depth
            depth = 0
            subq_text_lines = []  # type: List[str]
            found_close = False
            for j in range(i - 1, min(i + 60, len(lines))):
                scan = lines[j]
                for ch in scan:
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth == 0:
                            found_close = True
                subq_text_lines.append(scan)
                if found_close:
                    break

            subq_text = "\n".join(subq_text_lines)
            if order_by_re.search(subq_text) and not top_limit_re.search(subq_text):
                # Find the actual ORDER BY line within the subquery
                for k in range(i - 1, min(i - 1 + len(subq_text_lines), len(lines))):
                    if order_by_re.search(lines[k]):
                        self.violations.append(Violation(
                            rule_id="SA0017",
                            severity=Severity.MEDIUM,
                            line_number=k + 1,
                            line_text=raw_lines[k].strip(),
                            message="ORDER BY in subquery without TOP/LIMIT/FETCH is meaningless",
                            suggestion="Remove ORDER BY from subquery or add TOP/LIMIT/FETCH if ordering is needed",
                            fix_text="Remove the ORDER BY clause from this subquery, or add LIMIT/TOP/FETCH FIRST N ROWS",
                        ))
                        break

    # -- SA0018 Correlated subquery that can be rewritten as JOIN -----------

    def _check_sa0018_correlated_subquery(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Detect correlated subqueries in SELECT or WHERE clauses.

        A correlated subquery references a column from the outer query, causing
        the subquery to execute once per outer row.  This is often rewritable
        as a JOIN for better performance.

        Detection heuristic: a subquery (SELECT inside parens) that references
        an outer alias via alias.column syntax where the alias is defined in an
        outer FROM/JOIN clause.
        """
        # Find outer aliases: FROM table_name alias or FROM table_name AS alias
        alias_re = re.compile(
            r"\b(?:FROM|JOIN)\s+[\w.\[\]`\"]+\s+(?:AS\s+)?(\w+)\b", re.IGNORECASE
        )

        outer_aliases = set()  # type: set
        for line in lines:
            for m in alias_re.finditer(line):
                alias = m.group(1).upper()
                # Skip SQL keywords that could be confused with aliases
                if alias not in _SQL_RESERVED_WORDS:
                    outer_aliases.add(alias)

        if not outer_aliases:
            return

        # Now find subqueries that reference outer aliases
        subq_re = re.compile(r"\(\s*SELECT\b", re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if not subq_re.search(line):
                continue

            # Gather subquery text
            depth = 0
            subq_lines = []  # type: List[str]
            found_close = False
            for j in range(i - 1, min(i + 40, len(lines))):
                scan = lines[j]
                for ch in scan:
                    if ch == "(":
                        depth += 1
                    elif ch == ")":
                        depth -= 1
                        if depth == 0:
                            found_close = True
                subq_lines.append(scan)
                if found_close:
                    break

            subq_text = "\n".join(subq_lines)
            # Check if subquery references outer alias
            for alias in outer_aliases:
                correlated_ref = re.compile(
                    r"\b" + re.escape(alias) + r"\.\w+", re.IGNORECASE
                )
                # The reference must be inside the subquery, not in the outer query portion
                inner_text = subq_text
                if correlated_ref.search(inner_text):
                    # Verify this is in a WHERE clause context of the subquery
                    if re.search(r"\bWHERE\b", inner_text, re.IGNORECASE):
                        self.violations.append(Violation(
                            rule_id="SA0018",
                            severity=Severity.MEDIUM,
                            line_number=i,
                            line_text=raw_lines[i - 1].strip(),
                            message="Correlated subquery referencing outer alias '{}' -- consider rewriting as JOIN".format(
                                alias
                            ),
                            suggestion="Rewrite as JOIN or LEFT JOIN for better performance",
                            fix_text="Convert correlated subquery to JOIN: ... JOIN (...) sub ON sub.key = outer.key",
                        ))
                        break  # one violation per subquery

    # -- SA0019 Multiple nested subqueries (>2 levels deep) -----------------

    def _check_sa0019_nested_subqueries(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Detect deeply nested subqueries (more than 2 levels of SELECT nesting).

        Deeply nested subqueries are hard to read, hard to optimise, and often
        indicate the query should be refactored into CTEs or temp tables.
        """
        subq_re = re.compile(r"\(\s*SELECT\b", re.IGNORECASE)

        for i, line in enumerate(lines, 1):
            if not subq_re.search(line):
                continue

            # Scan from line 0 to line i, track paren-depth of (SELECT blocks
            select_depth = 0
            max_depth = 0
            paren_depth = 0
            select_at_depth = {}  # type: Dict[int, bool]

            for k in range(0, i):
                scan = lines[k]
                pos = 0
                while pos < len(scan):
                    # Check for ( SELECT pattern
                    remainder = scan[pos:]
                    if re.match(r"\(\s*SELECT\b", remainder, re.IGNORECASE):
                        paren_depth += 1
                        select_at_depth[paren_depth] = True
                        select_depth += 1
                        if select_depth > max_depth:
                            max_depth = select_depth
                        pos += 1
                        continue
                    if scan[pos] == "(":
                        paren_depth += 1
                        pos += 1
                        continue
                    if scan[pos] == ")":
                        if select_at_depth.get(paren_depth, False):
                            select_depth -= 1
                            select_at_depth[paren_depth] = False
                        paren_depth -= 1
                        if paren_depth < 0:
                            paren_depth = 0
                        pos += 1
                        continue
                    pos += 1

            # Now check current line
            current_select_depth = select_depth
            scan = lines[i - 1]
            pos = 0
            while pos < len(scan):
                remainder = scan[pos:]
                if re.match(r"\(\s*SELECT\b", remainder, re.IGNORECASE):
                    paren_depth += 1
                    select_at_depth[paren_depth] = True
                    current_select_depth += 1
                    pos += 1
                    continue
                if scan[pos] == "(":
                    paren_depth += 1
                    pos += 1
                    continue
                if scan[pos] == ")":
                    if select_at_depth.get(paren_depth, False):
                        current_select_depth -= 1
                        select_at_depth[paren_depth] = False
                    paren_depth -= 1
                    if paren_depth < 0:
                        paren_depth = 0
                    pos += 1
                    continue
                pos += 1

            if current_select_depth > 2:
                self.violations.append(Violation(
                    rule_id="SA0019",
                    severity=Severity.LOW,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="Subquery nested {} levels deep -- consider simplifying".format(
                        current_select_depth
                    ),
                    suggestion="Refactor deeply nested subqueries into CTEs (WITH clause) or temp tables",
                    fix_text="Rewrite using WITH (CTE): WITH cte1 AS (SELECT ...), cte2 AS (SELECT ... FROM cte1) SELECT ...",
                ))

    # =====================================================================
    # MSSQL-SPECIFIC CHECKS
    # =====================================================================

    def _run_mssql_checks(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        self._check_ms001_nocount(content, lines, raw_lines)
        self._check_ms002_xact_abort(content, lines, raw_lines)
        self._check_ms003_at_identity(lines, raw_lines)
        self._check_ms004_deprecated_join(lines, raw_lines)
        self._check_ms005_sp_prefix(lines, raw_lines)
        self._check_ms006_small_varchar(lines, raw_lines)
        self._check_ms007_exec_variable(lines, raw_lines)
        self._check_ms008_trycatch_transaction(content, lines, raw_lines)
        self._check_ms009_nolock(lines, raw_lines)
        self._check_ms010_deprecated_types(lines, raw_lines)
        # Compute ALTER TABLE ADD CONSTRAINT spans once and share between
        # SA-MS011 and SA-MS012 (both scan the same regions).
        add_constraint_spans = self._find_add_constraint_spans(content)
        self._check_ms011_resumable_in_constraint(content, raw_lines, add_constraint_spans)
        self._check_ms012_wait_low_priority_in_constraint(content, raw_lines, add_constraint_spans)
        self._check_ms013_resumable_in_transaction(content, raw_lines)

    # SA-MS001 Missing SET NOCOUNT ON
    def _check_ms001_nocount(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        proc_re = re.compile(
            r"\bCREATE\s+(?:OR\s+ALTER\s+)?PROC(?:EDURE)?\b", re.IGNORECASE
        )
        nocount_re = re.compile(r"\bSET\s+NOCOUNT\s+ON\b", re.IGNORECASE)

        proc_starts = []  # type: List[int]
        for i, line in enumerate(lines, 1):
            if proc_re.search(line):
                proc_starts.append(i)

        for idx, start in enumerate(proc_starts):
            end = proc_starts[idx + 1] - 1 if idx + 1 < len(proc_starts) else len(lines)
            body = "\n".join(lines[start - 1 : end])
            if not nocount_re.search(body):
                self.violations.append(Violation(
                    rule_id="SA-MS001",
                    severity=Severity.HIGH,
                    line_number=start,
                    line_text=raw_lines[start - 1].strip(),
                    message="Stored procedure missing SET NOCOUNT ON",
                    suggestion="Add 'SET NOCOUNT ON;' as first statement after BEGIN",
                    dialect_specific=True,
                    fix_text="Add SET NOCOUNT ON; as the first line after AS BEGIN",
                ))

    # SA-MS002 Transaction without SET XACT_ABORT ON (CRITICAL)
    def _check_ms002_xact_abort(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Flag any procedure that opens an explicit transaction without
        SET XACT_ABORT ON.

        Severity is CRITICAL because this is a hard *production deploy*
        failure, not a style nit: Flyway's SQL Server parser classifies a
        batch that opens BEGIN TRAN[SACTION] *without* SET XACT_ABORT ON as
        non-transactional. When such a proc is bundled into a repeatable
        migration alongside transactional statements (GRANT, CREATE VIEW,
        sibling procs that DO set it), Flyway aborts the entire migration
        with "Detected both transactional and non-transactional statements
        within the same migration (even though mixed is false)".

        Detection is regex-free (a hand-rolled tokenizer) and per-procedure,
        so a proc missing the SET is caught even when sibling procs in the
        same file have it. Runs on the comment/string-stripped `content`, so
        transaction keywords inside comments or string literals don't fire.
        """

        def tokenize(text):
            # Maximal runs of identifier chars -> UPPERCASED tokens, each
            # paired with its 1-based line number. Every other character
            # (whitespace, punctuation, ';', parentheses) is a separator.
            out = []
            buf = []
            line_no = 1
            tok_line = 1
            for ch in text:
                if ch == "\n":
                    if buf:
                        out.append(("".join(buf).upper(), tok_line))
                        buf = []
                    line_no += 1
                    continue
                if ch.isalnum() or ch == "_" or ch == "@" or ch == "#":
                    if not buf:
                        tok_line = line_no
                    buf.append(ch)
                elif buf:
                    out.append(("".join(buf).upper(), tok_line))
                    buf = []
            if buf:
                out.append(("".join(buf).upper(), tok_line))
            return out

        toks = tokenize(content)
        n = len(toks)
        if n == 0:
            return

        # Procedure starts: CREATE [OR ALTER] PROC|PROCEDURE
        proc_starts = []
        for k in range(n):
            if toks[k][0] != "CREATE":
                continue
            j = k + 1
            if j + 1 < n and toks[j][0] == "OR" and toks[j + 1][0] == "ALTER":
                j += 2
            if j < n and toks[j][0] in ("PROC", "PROCEDURE"):
                proc_starts.append(k)

        # Each procedure owns the token span up to the next procedure. With no
        # procedures, scan the whole file as a single span (covers bare
        # transactional scripts -- preserves the original file-level check).
        if proc_starts:
            spans = []
            for i, s in enumerate(proc_starts):
                e = proc_starts[i + 1] if i + 1 < len(proc_starts) else n
                spans.append((s, e))
        else:
            spans = [(0, n)]

        for lo, hi in spans:
            # BEGIN TRAN | BEGIN TRANSACTION -- NOT BEGIN TRY / BEGIN CATCH,
            # and NOT COMMIT/ROLLBACK TRANSACTION (those aren't preceded by BEGIN).
            tran_line = None
            for k in range(lo, hi - 1):
                if toks[k][0] == "BEGIN" and toks[k + 1][0] in ("TRAN", "TRANSACTION"):
                    tran_line = toks[k][1]
                    break
            if tran_line is None:
                continue
            # SET XACT_ABORT ON anywhere in the same span.
            has_xact = False
            for k in range(lo, hi - 2):
                if (toks[k][0] == "SET"
                        and toks[k + 1][0] == "XACT_ABORT"
                        and toks[k + 2][0] == "ON"):
                    has_xact = True
                    break
            if has_xact:
                continue

            report_line = toks[lo][1] if proc_starts else tran_line
            line_text = (
                raw_lines[report_line - 1].strip()
                if 0 <= report_line - 1 < len(raw_lines) else ""
            )
            self.violations.append(Violation(
                rule_id="SA-MS002",
                severity=Severity.CRITICAL,
                line_number=report_line,
                line_text=line_text,
                message="Procedure opens an explicit transaction without SET XACT_ABORT ON",
                suggestion=(
                    "Add 'SET XACT_ABORT ON;' right after SET NOCOUNT ON. Without it, "
                    "Flyway's SQL Server parser treats the batch as non-transactional "
                    "and aborts mixed-statement migrations on deploy."
                ),
                dialect_specific=True,
                fix_text="Add SET XACT_ABORT ON; before BEGIN TRANSACTION",
            ))

    # SA-MS003 @@IDENTITY
    def _check_ms003_at_identity(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        pat = re.compile(r"@@IDENTITY\b", re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-MS003",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="@@IDENTITY returns wrong value when triggers insert into other tables",
                    suggestion="Use SCOPE_IDENTITY() instead of @@IDENTITY",
                    dialect_specific=True,
                    fix_text="Replace @@IDENTITY with SCOPE_IDENTITY()",
                ))

    # SA-MS004 Deprecated *= or =* join
    def _check_ms004_deprecated_join(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        pat = re.compile(r"\*=|=\*")
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-MS004",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="Deprecated outer join syntax (*= or =*)",
                    suggestion="Use ANSI JOIN syntax: LEFT/RIGHT OUTER JOIN",
                    dialect_specific=True,
                    fix_text="Replace *= with LEFT OUTER JOIN, or =* with RIGHT OUTER JOIN using ANSI syntax",
                ))

    # SA-MS005 sp_ prefix
    def _check_ms005_sp_prefix(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        pat = re.compile(
            r"\bCREATE\s+(?:OR\s+ALTER\s+)?PROC(?:EDURE)?\s+\[?sp_", re.IGNORECASE
        )
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-MS005",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="sp_ prefix reserved for system stored procedures",
                    suggestion="Use a different prefix (e.g. usp_) or no prefix",
                    dialect_specific=True,
                    fix_text="Rename procedure from sp_ prefix to usp_ or another custom prefix",
                ))

    # SA-MS006 VARCHAR(1)/VARCHAR(2)
    def _check_ms006_small_varchar(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Flag VARCHAR(1)/(2) and NVARCHAR(1)/(2) in column definitions.

        Skips lines that look like inline CAST/CONVERT expressions in
        queries -- those are runtime conversions where CHAR(1) is NOT a
        drop-in replacement (CHAR space-pads), and the rule's intent is
        storage definition, not expression typing.
        """
        cast_context_re = re.compile(
            r"\b(?:CAST|CONVERT)\s*\(", re.IGNORECASE
        )
        pats = [
            (re.compile(r"\bVARCHAR\s*\(\s*1\s*\)", re.IGNORECASE), "VARCHAR(1)"),
            (re.compile(r"\bVARCHAR\s*\(\s*2\s*\)", re.IGNORECASE), "VARCHAR(2)"),
            (re.compile(r"\bNVARCHAR\s*\(\s*1\s*\)", re.IGNORECASE), "NVARCHAR(1)"),
            (re.compile(r"\bNVARCHAR\s*\(\s*2\s*\)", re.IGNORECASE), "NVARCHAR(2)"),
        ]
        for i, line in enumerate(lines, 1):
            if cast_context_re.search(line):
                continue
            for pat, name in pats:
                if pat.search(line):
                    fixed = name.replace("VARCHAR", "CHAR")
                    self.violations.append(Violation(
                        rule_id="SA-MS006",
                        severity=Severity.MEDIUM,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="{} should be CHAR/NCHAR for fixed small sizes".format(name),
                        suggestion="Use CHAR(1) or NCHAR(1) instead of {}".format(name),
                        dialect_specific=True,
                        fix_text="Replace {} with {}".format(name, fixed),
                    ))
                    break

    # SA-MS007 EXEC(@sql) instead of sp_executesql
    def _check_ms007_exec_variable(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Flag EXEC(@variable) -- prefer sp_executesql for parameterisation.

        For `EXEC (@sql) AT linked_server`, sp_executesql has no AT-variant,
        so the line is demoted to MEDIUM with an explanatory note.  Devs
        can still use `-- nitsql:ignore=SA-MS007` to suppress entirely.
        """
        pat = re.compile(r"\bEXEC\s*\(\s*@\w+\s*\)", re.IGNORECASE)
        at_pat = re.compile(
            r"\bEXEC\s*\(\s*@\w+\s*\)\s+AT\s+\[?\w+\]?", re.IGNORECASE
        )
        for i, line in enumerate(lines, 1):
            if not pat.search(line):
                continue
            if at_pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-MS007",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message=(
                        "EXEC(@sql) AT linked_server -- sp_executesql does not "
                        "support AT linked_server; validate inputs at boundaries"
                    ),
                    suggestion="Validate / allow-list @sql contents at source, or use -- nitsql:ignore=SA-MS007",
                    dialect_specific=True,
                    fix_text="Document inputs and review for injection; sp_executesql is not an option here",
                ))
            else:
                self.violations.append(Violation(
                    rule_id="SA-MS007",
                    severity=Severity.HIGH,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="EXEC(@sql) does not support parameterisation",
                    suggestion="Use sp_executesql with @params for safe dynamic SQL",
                    dialect_specific=True,
                    fix_text="Replace EXEC(@sql) with EXEC sp_executesql @sql, N'@param INT', @param = @value",
                ))

    # SA-MS008 Missing TRY-CATCH around transactions
    def _check_ms008_trycatch_transaction(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        has_tran = re.search(r"\bBEGIN\s+TRAN(?:SACTION)?\b", content, re.IGNORECASE)
        has_try = re.search(r"\bBEGIN\s+TRY\b", content, re.IGNORECASE)

        if has_tran and not has_try:
            for i, line in enumerate(lines, 1):
                if re.search(r"\bBEGIN\s+TRAN", line, re.IGNORECASE):
                    self.violations.append(Violation(
                        rule_id="SA-MS008",
                        severity=Severity.HIGH,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="Transaction without TRY-CATCH error handling",
                        suggestion="Wrap transaction in BEGIN TRY / BEGIN CATCH with ROLLBACK in CATCH",
                        dialect_specific=True,
                        fix_text="Wrap with: BEGIN TRY ... BEGIN TRAN ... COMMIT TRAN END TRY BEGIN CATCH ROLLBACK TRAN; THROW; END CATCH",
                    ))
                    break

    # SA-MS009 NOLOCK hint
    def _check_ms009_nolock(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        pat = re.compile(r"\bWITH\s*\(\s*NOLOCK\s*\)", re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-MS009",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="NOLOCK hint can cause dirty reads, skipped rows, or duplicates",
                    suggestion="Consider Read Committed Snapshot Isolation (RCSI) instead",
                    dialect_specific=True,
                    fix_text="Remove WITH (NOLOCK) and enable RCSI at database level instead",
                ))

    # SA-MS010 Deprecated TEXT/NTEXT/IMAGE
    def _check_ms010_deprecated_types(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        pats = [
            (re.compile(r"\bTEXT\b(?!\s*(?:NOT\s+)?NULL)", re.IGNORECASE),
             "TEXT is deprecated", "Use VARCHAR(MAX)"),
            (re.compile(r"\bNTEXT\b", re.IGNORECASE),
             "NTEXT is deprecated", "Use NVARCHAR(MAX)"),
            (re.compile(r"\bIMAGE\b(?!\s*(?:NOT\s+)?NULL)", re.IGNORECASE),
             "IMAGE is deprecated", "Use VARBINARY(MAX)"),
        ]
        ddl_re = re.compile(
            r"\b(?:CREATE|ALTER)\s+TABLE\b", re.IGNORECASE
        )
        in_ddl = False
        for i, line in enumerate(lines, 1):
            if ddl_re.search(line):
                in_ddl = True
            if in_ddl:
                for pat, msg, sug in pats:
                    if pat.search(line):
                        self.violations.append(Violation(
                            rule_id="SA-MS010",
                            severity=Severity.MEDIUM,
                            line_number=i,
                            line_text=raw_lines[i - 1].strip(),
                            message=msg,
                            suggestion=sug,
                            dialect_specific=True,
                            fix_text="Replace deprecated type: {}".format(sug),
                        ))
                        break
            # Reset DDL context on GO or blank line after a closing paren
            if re.search(r"^\s*GO\s*$", line, re.IGNORECASE) or (
                in_ddl and re.search(r"^\s*\)\s*;?\s*$", line)
            ):
                in_ddl = False

    # --- Helper: find ALTER TABLE ADD CONSTRAINT PK/UQ statement spans -------

    def _find_add_constraint_spans(
        self, content: str
    ) -> List[Tuple[int, int]]:
        """Return list of (start_pos, end_pos) spans for each
        ALTER TABLE ... ADD CONSTRAINT ... (PRIMARY KEY|UNIQUE) ... ;
        statement.  Used by SA-MS011 / SA-MS012 to detect option misuse."""
        spans = []  # type: List[Tuple[int, int]]
        # Anchored on ALTER TABLE ... ADD CONSTRAINT ... PRIMARY KEY|UNIQUE
        start_re = re.compile(
            r"\bALTER\s+TABLE\b[^;]*?\bADD\s+CONSTRAINT\b[^;]*?"
            r"\b(?:PRIMARY\s+KEY|UNIQUE)\b",
            re.IGNORECASE | re.DOTALL,
        )
        for m in start_re.finditer(content):
            start = m.start()
            # End at the next semicolon or GO on its own line.
            # Allow GO at end-of-file (no trailing newline) as well.
            tail = content[m.end():]
            end_match = re.search(r";|\n\s*GO\s*(?:\n|\Z)", tail, re.IGNORECASE)
            end = m.end() + (end_match.end() if end_match else len(tail))
            spans.append((start, end))
        return spans

    @staticmethod
    def _pos_to_line(content: str, pos: int) -> int:
        return content.count("\n", 0, pos) + 1

    # SA-MS011 RESUMABLE used in ALTER TABLE ADD CONSTRAINT (error 155)
    def _check_ms011_resumable_in_constraint(
        self, content: str, raw_lines: List[str],
        spans: List[Tuple[int, int]],
    ) -> None:
        if not spans:
            return
        resumable_re = re.compile(r"\bRESUMABLE\s*=\s*ON\b", re.IGNORECASE)
        for start, end in spans:
            block = content[start:end]
            m = resumable_re.search(block)
            if m:
                line_no = self._pos_to_line(content, start + m.start())
                self.violations.append(Violation(
                    rule_id="SA-MS011",
                    severity=Severity.CRITICAL,
                    line_number=line_no,
                    line_text=raw_lines[line_no - 1].strip() if line_no <= len(raw_lines) else "",
                    message="RESUMABLE = ON is not valid for ALTER TABLE ADD CONSTRAINT "
                            "(SQL Server rejects it — not a recognized ALTER TABLE option)",
                    suggestion="Remove RESUMABLE from ALTER TABLE ADD CONSTRAINT. It is only "
                               "supported by CREATE INDEX / ALTER INDEX REBUILD.",
                    dialect_specific=True,
                    fix_text="Drop `RESUMABLE = ON, MAX_DURATION = N MINUTES` from the "
                             "ALTER TABLE ADD CONSTRAINT WITH clause",
                ))

    # SA-MS012 WAIT_AT_LOW_PRIORITY inside ALTER TABLE ADD CONSTRAINT (error 155)
    def _check_ms012_wait_low_priority_in_constraint(
        self, content: str, raw_lines: List[str],
        spans: List[Tuple[int, int]],
    ) -> None:
        if not spans:
            return
        wait_re = re.compile(r"\bWAIT_AT_LOW_PRIORITY\b", re.IGNORECASE)
        for start, end in spans:
            block = content[start:end]
            m = wait_re.search(block)
            if m:
                line_no = self._pos_to_line(content, start + m.start())
                self.violations.append(Violation(
                    rule_id="SA-MS012",
                    severity=Severity.CRITICAL,
                    line_number=line_no,
                    line_text=raw_lines[line_no - 1].strip() if line_no <= len(raw_lines) else "",
                    message="WAIT_AT_LOW_PRIORITY is not valid for ALTER TABLE ADD CONSTRAINT "
                            "(SQL Server error 155)",
                    suggestion="Use flat `ONLINE = ON` on ALTER TABLE ADD CONSTRAINT PK/UQ. "
                               "WAIT_AT_LOW_PRIORITY is only valid on CREATE INDEX / ALTER INDEX REBUILD.",
                    dialect_specific=True,
                    fix_text="Replace `ONLINE = ON (WAIT_AT_LOW_PRIORITY (...))` with `ONLINE = ON` "
                             "inside the ALTER TABLE ADD CONSTRAINT WITH clause",
                ))

    # SA-MS013 RESUMABLE = ON in a transactional / migration context (error 574)
    def _check_ms013_resumable_in_transaction(
        self, content: str, raw_lines: List[str]
    ) -> None:
        # Detect RESUMABLE = ON anywhere in the script
        resumable_re = re.compile(r"\bRESUMABLE\s*=\s*ON\b", re.IGNORECASE)
        resumable_hits = list(resumable_re.finditer(content))
        if not resumable_hits:
            return

        # Heuristics that signal a transactional / migration context where
        # SQL Server will reject RESUMABLE with error 574:
        #   1) Explicit BEGIN TRAN[SACTION] in the script
        #   2) File path looks like a Flyway / Liquibase versioned migration
        #      (V1_00001__*.sql, V001__*.sql, changeSet, etc.)
        in_explicit_tran = re.search(
            r"\bBEGIN\s+TRAN(?:SACTION)?\b", content, re.IGNORECASE
        ) is not None
        # Migration-file hints we might see inside the script itself.
        # NOTE: comments are stripped from `content`, so we must scan the
        # raw, comment-preserving text here.
        raw_text = "\n".join(raw_lines)
        migration_hints = re.search(
            r"(?:^|\n)\s*--\s*(?:flyway|liquibase|changeset)\b",
            raw_text, re.IGNORECASE,
        ) is not None

        if not (in_explicit_tran or migration_hints):
            return  # Ad-hoc maintenance script — RESUMABLE is fine

        for m in resumable_hits:
            line_no = self._pos_to_line(content, m.start())
            # Skip hits already flagged by SA-MS011 (ALTER TABLE ADD CONSTRAINT)
            # to avoid double-reporting on the same line.
            already_flagged = any(
                v.rule_id == "SA-MS011" and v.line_number == line_no
                for v in self.violations
            )
            if already_flagged:
                continue
            self.violations.append(Violation(
                rule_id="SA-MS013",
                severity=Severity.CRITICAL,
                line_number=line_no,
                line_text=raw_lines[line_no - 1].strip() if line_no <= len(raw_lines) else "",
                message="RESUMABLE = ON cannot run inside a user transaction "
                        "(SQL Server error 574). Flyway/Liquibase wrap migrations in a transaction.",
                suggestion="Remove RESUMABLE for transactional migrations and rely on "
                           "ONLINE = ON (WAIT_AT_LOW_PRIORITY (...)). Use RESUMABLE only in "
                           "ad-hoc maintenance scripts executed outside any transaction. "
                           "Flyway exception: if the migration is annotated with "
                           "`runInTransaction=false` (script config or `-- Flyway: runInTransaction=false`), "
                           "RESUMABLE is valid because Flyway will not wrap it in a transaction.",
                dialect_specific=True,
                fix_text="Drop `, RESUMABLE = ON, MAX_DURATION = N MINUTES` from the "
                         "index option list when the script runs inside a transaction",
            ))

    # =====================================================================
    # POSTGRESQL-SPECIFIC CHECKS
    # =====================================================================

    def _run_postgresql_checks(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        self._check_pg001_serial(lines, raw_lines)
        self._check_pg002_varchar_vs_text(lines, raw_lines)
        self._check_pg003_concurrent_index(lines, raw_lines)
        self._check_pg004_security_definer(content, lines, raw_lines)
        self._check_pg005_implicit_cast(lines, raw_lines)

    # SA-PG001 SERIAL instead of GENERATED AS IDENTITY
    def _check_pg001_serial(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        pat = re.compile(r"\b(?:BIG)?SERIAL\b", re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-PG001",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="SERIAL type is legacy -- prefer GENERATED AS IDENTITY",
                    suggestion="Use INTEGER GENERATED ALWAYS AS IDENTITY instead of SERIAL",
                    dialect_specific=True,
                    fix_text="Replace SERIAL with INTEGER GENERATED ALWAYS AS IDENTITY",
                ))

    # SA-PG002 VARCHAR(255) or bare VARCHAR vs TEXT
    def _check_pg002_varchar_vs_text(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # In PostgreSQL, VARCHAR(255) is a common anti-pattern from MySQL/MSSQL
        # habits.  TEXT has identical performance and is idiomatic.
        varchar255_pat = re.compile(r"\bVARCHAR\s*\(\s*255\s*\)", re.IGNORECASE)
        bare_varchar = re.compile(r"\bVARCHAR\s*(?!\s*\()", re.IGNORECASE)
        # Make sure we're in a DDL context (column definition)
        ddl_ctx = re.compile(
            r"\b(?:CREATE|ALTER)\s+TABLE\b", re.IGNORECASE
        )
        in_ddl = False
        for i, line in enumerate(lines, 1):
            if ddl_ctx.search(line):
                in_ddl = True
            if in_ddl:
                if varchar255_pat.search(line):
                    self.violations.append(Violation(
                        rule_id="SA-PG002",
                        severity=Severity.MEDIUM,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="VARCHAR(255) is an anti-pattern in PostgreSQL",
                        suggestion="Use TEXT instead; VARCHAR(255) adds no benefit over TEXT in PostgreSQL",
                        dialect_specific=True,
                        fix_text="Replace VARCHAR(255) with TEXT",
                    ))
                elif bare_varchar.search(line):
                    self.violations.append(Violation(
                        rule_id="SA-PG002",
                        severity=Severity.LOW,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="VARCHAR without length is equivalent to TEXT in PostgreSQL",
                        suggestion="Use TEXT instead of VARCHAR (without length) for clarity",
                        dialect_specific=True,
                        fix_text="Replace VARCHAR with TEXT",
                    ))
            if re.search(r"^\s*\)\s*;?\s*$", line):
                in_ddl = False

    # SA-PG003 CREATE INDEX without CONCURRENTLY
    def _check_pg003_concurrent_index(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        create_idx = re.compile(
            r"\bCREATE\s+(?:UNIQUE\s+)?INDEX\b", re.IGNORECASE
        )
        concurrent = re.compile(r"\bCONCURRENTLY\b", re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if create_idx.search(line) and not concurrent.search(line):
                self.violations.append(Violation(
                    rule_id="SA-PG003",
                    severity=Severity.HIGH,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="CREATE INDEX without CONCURRENTLY locks writes on the table",
                    suggestion="Use CREATE INDEX CONCURRENTLY for production tables",
                    dialect_specific=True,
                    fix_text="Add CONCURRENTLY keyword: CREATE INDEX CONCURRENTLY ...",
                ))

    # SA-PG004 SECURITY DEFINER without search_path
    def _check_pg004_security_definer(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        definer_re = re.compile(r"\bSECURITY\s+DEFINER\b", re.IGNORECASE)
        search_path_re = re.compile(r"\bSET\s+search_path\b", re.IGNORECASE)

        if definer_re.search(content) and not search_path_re.search(content):
            for i, line in enumerate(lines, 1):
                if definer_re.search(line):
                    self.violations.append(Violation(
                        rule_id="SA-PG004",
                        severity=Severity.CRITICAL,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="SECURITY DEFINER function without SET search_path -- privilege escalation risk",
                        suggestion="Add 'SET search_path = public' (or appropriate schema) to the function",
                        dialect_specific=True,
                        fix_text="Add to function definition: SET search_path = public, pg_temp",
                    ))
                    break

    # SA-PG005 Implicit casting with = on mismatched types
    def _check_pg005_implicit_cast(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Pattern: column::text = integer_literal  or  integer_col = 'string'
        # Heuristic: comparison between a cast and a literal of different type
        pat = re.compile(
            r"::\w+\s*=\s*\d+|\d+\s*=\s*\w+::", re.IGNORECASE
        )
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-PG005",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="Implicit casting between mismatched types in comparison",
                    suggestion="Explicitly cast both sides to the same type",
                    dialect_specific=True,
                    fix_text="Cast both sides explicitly: column::integer = value::integer",
                ))

    # =====================================================================
    # ORACLE-SPECIFIC CHECKS
    # =====================================================================

    def _run_oracle_checks(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        self._check_ora001_when_others_null(lines, raw_lines)
        self._check_ora002_varchar_not_varchar2(lines, raw_lines)
        self._check_ora003_missing_commit(content, lines, raw_lines)
        self._check_ora004_select_into_no_handler(content, lines, raw_lines)
        self._check_ora005_long_type(lines, raw_lines)

    # SA-ORA001 WHEN OTHERS THEN NULL
    def _check_ora001_when_others_null(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        pat = re.compile(
            r"\bWHEN\s+OTHERS\s+THEN\s+NULL\b", re.IGNORECASE
        )
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-ORA001",
                    severity=Severity.CRITICAL,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="WHEN OTHERS THEN NULL swallows all exceptions silently",
                    suggestion="Log or re-raise exceptions; never silently swallow WHEN OTHERS",
                    dialect_specific=True,
                    fix_text="Replace NULL with logging: DBMS_OUTPUT.PUT_LINE(SQLERRM); RAISE;",
                ))

    # SA-ORA002 VARCHAR instead of VARCHAR2
    def _check_ora002_varchar_not_varchar2(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Match VARCHAR that is NOT followed by 2 -- in any context (DDL, params, variables)
        pat = re.compile(r"\bVARCHAR\b(?!\s*2)", re.IGNORECASE)
        varchar2_pat = re.compile(r"\bVARCHAR2\b", re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if pat.search(line) and not varchar2_pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-ORA002",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="VARCHAR behaves differently from VARCHAR2 in Oracle",
                    suggestion="Always use VARCHAR2 instead of VARCHAR in Oracle",
                    dialect_specific=True,
                    fix_text="Replace VARCHAR with VARCHAR2",
                ))

    # SA-ORA003 Missing COMMIT in procedure
    def _check_ora003_missing_commit(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        proc_re = re.compile(
            r"\bCREATE\s+(?:OR\s+REPLACE\s+)?PROCEDURE\b", re.IGNORECASE
        )
        commit_re = re.compile(r"\bCOMMIT\b", re.IGNORECASE)
        dml_re = re.compile(
            r"\b(?:INSERT|UPDATE|DELETE|MERGE)\b", re.IGNORECASE
        )

        if proc_re.search(content) and dml_re.search(content) and not commit_re.search(content):
            for i, line in enumerate(lines, 1):
                if proc_re.search(line):
                    self.violations.append(Violation(
                        rule_id="SA-ORA003",
                        severity=Severity.MEDIUM,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="Procedure with DML but no explicit COMMIT",
                        suggestion="Add explicit COMMIT or document that caller is responsible for commit",
                        dialect_specific=True,
                        fix_text="Add COMMIT; before END; or document the commit strategy",
                    ))
                    break

    # SA-ORA004 SELECT INTO without NO_DATA_FOUND handler
    def _check_ora004_select_into_no_handler(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Detect SELECT ... INTO patterns (single-line or multi-line)
        select_re = re.compile(r"\bSELECT\b(?!.*\bCOUNT\b)", re.IGNORECASE)
        into_re = re.compile(r"\bINTO\b", re.IGNORECASE)
        handler_re = re.compile(r"\bNO_DATA_FOUND\b", re.IGNORECASE)

        # Find procedure/function boundaries and check each one
        proc_re = re.compile(
            r"\bCREATE\s+(?:OR\s+REPLACE\s+)?(?:PROCEDURE|FUNCTION)\b", re.IGNORECASE
        )
        proc_starts = []  # type: List[int]
        for i, line in enumerate(lines, 1):
            if proc_re.search(line):
                proc_starts.append(i)

        for idx, start in enumerate(proc_starts):
            end = proc_starts[idx + 1] - 1 if idx + 1 < len(proc_starts) else len(lines)
            body = "\n".join(lines[start - 1 : end])
            has_handler = handler_re.search(body)
            if has_handler:
                continue

            # Scan for SELECT ... INTO (single or multi-line within 3 lines)
            found_select_into = False
            select_line = -1
            for j in range(start - 1, end):
                line_text = lines[j]
                # Single-line: SELECT ... INTO ... FROM
                if select_re.search(line_text) and into_re.search(line_text):
                    found_select_into = True
                    select_line = j
                    break
                # Multi-line: SELECT on one line, INTO on next 1-3 lines
                if select_re.search(line_text) and not into_re.search(line_text):
                    for k in range(j + 1, min(j + 4, end)):
                        if into_re.search(lines[k]):
                            found_select_into = True
                            select_line = j
                            break
                    if found_select_into:
                        break

            if found_select_into:
                self.violations.append(Violation(
                    rule_id="SA-ORA004",
                    severity=Severity.HIGH,
                    line_number=select_line + 1,
                    line_text=raw_lines[select_line].strip(),
                    message="SELECT INTO without NO_DATA_FOUND exception handler",
                    suggestion="Add EXCEPTION WHEN NO_DATA_FOUND THEN ... handler",
                    dialect_specific=True,
                    fix_text="Add: EXCEPTION WHEN NO_DATA_FOUND THEN <handle_missing_data>;",
                ))

    # SA-ORA005 LONG data type
    def _check_ora005_long_type(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Check for LONG data type in any context -- DDL, parameters, variables
        # LONG is deprecated in Oracle; use CLOB instead
        pat = re.compile(r"\bLONG\b(?!\s+RAW\b)", re.IGNORECASE)
        # But avoid matching "LONG" in comments and non-type contexts like
        # "long-running" or "LONG INTEGER"
        type_ctx = re.compile(
            r"(?:\bIN\s+LONG\b|\bOUT\s+LONG\b|\bLONG\s*[,);]|\bLONG\s*$|\w+\s+LONG\b)",
            re.IGNORECASE
        )
        for i, line in enumerate(lines, 1):
            if pat.search(line) and type_ctx.search(line):
                self.violations.append(Violation(
                    rule_id="SA-ORA005",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="LONG data type is deprecated in Oracle",
                    suggestion="Use CLOB instead of LONG",
                    dialect_specific=True,
                    fix_text="Replace LONG with CLOB",
                ))

    # =====================================================================
    # MYSQL-SPECIFIC CHECKS
    # =====================================================================

    def _run_mysql_checks(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        self._check_my001_missing_innodb(content, lines, raw_lines)
        self._check_my002_float_currency(lines, raw_lines)
        self._check_my003_auto_increment_gap(content, lines, raw_lines)
        self._check_my004_enum_type(lines, raw_lines)
        self._check_my005_select_no_limit(lines, raw_lines)

    # SA-MY001 Missing ENGINE=InnoDB
    def _check_my001_missing_innodb(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        create_re = re.compile(r"\bCREATE\s+TABLE\b", re.IGNORECASE)
        engine_innodb = re.compile(r"\bENGINE\s*=\s*InnoDB\b", re.IGNORECASE)
        engine_any = re.compile(r"\bENGINE\s*=\s*\w+", re.IGNORECASE)

        if create_re.search(content):
            # Check each CREATE TABLE block
            for i, line in enumerate(lines, 1):
                if create_re.search(line):
                    # Scan forward to find engine clause or end of statement
                    block = []
                    for j in range(i - 1, min(i + 50, len(lines))):
                        block.append(lines[j])
                        if ";" in lines[j]:
                            break
                    block_text = "\n".join(block)
                    if engine_any.search(block_text) and not engine_innodb.search(block_text):
                        self.violations.append(Violation(
                            rule_id="SA-MY001",
                            severity=Severity.HIGH,
                            line_number=i,
                            line_text=raw_lines[i - 1].strip(),
                            message="Table not using InnoDB engine -- MyISAM lacks transaction support",
                            suggestion="Use ENGINE=InnoDB for transaction and foreign key support",
                            dialect_specific=True,
                            fix_text="Change ENGINE clause to ENGINE=InnoDB",
                        ))
                    elif not engine_any.search(block_text):
                        self.violations.append(Violation(
                            rule_id="SA-MY001",
                            severity=Severity.LOW,
                            line_number=i,
                            line_text=raw_lines[i - 1].strip(),
                            message="CREATE TABLE without explicit ENGINE -- defaults may vary",
                            suggestion="Explicitly specify ENGINE=InnoDB",
                            dialect_specific=True,
                            fix_text="Add ENGINE=InnoDB at end of CREATE TABLE statement",
                        ))

    # SA-MY002 FLOAT/DOUBLE for currency
    def _check_my002_float_currency(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Look for FLOAT or DOUBLE in column definitions that hint at money
        money_ctx = re.compile(
            r"(?:price|cost|amount|balance|salary|fee|rate|total|tax|revenue|"
            r"payment|charge|discount|budget|income|profit)\w*\s+"
            r"(?:FLOAT|DOUBLE)\b",
            re.IGNORECASE,
        )
        # Also flag bare FLOAT/DOUBLE in DDL context
        float_re = re.compile(
            r"\b(?:FLOAT|DOUBLE)\b(?!\s+PRECISION)", re.IGNORECASE
        )
        ddl_re = re.compile(r"\b(?:CREATE|ALTER)\s+TABLE\b", re.IGNORECASE)
        in_ddl = False

        for i, line in enumerate(lines, 1):
            if ddl_re.search(line):
                in_ddl = True
            if in_ddl:
                if money_ctx.search(line):
                    self.violations.append(Violation(
                        rule_id="SA-MY002",
                        severity=Severity.HIGH,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="FLOAT/DOUBLE used for monetary column -- imprecise",
                        suggestion="Use DECIMAL(p,s) for currency values",
                        dialect_specific=True,
                        fix_text="Replace FLOAT/DOUBLE with DECIMAL(19,4) for monetary values",
                    ))
                elif float_re.search(line):
                    self.violations.append(Violation(
                        rule_id="SA-MY002",
                        severity=Severity.MEDIUM,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="FLOAT/DOUBLE in table definition -- check if DECIMAL is more appropriate",
                        suggestion="Use DECIMAL(p,s) when exact precision is needed",
                        dialect_specific=True,
                        fix_text="Consider replacing FLOAT/DOUBLE with DECIMAL(p,s) if precision matters",
                    ))
            if re.search(r"^\s*\)\s*", line):
                in_ddl = False

    # SA-MY003 AUTO_INCREMENT gap awareness
    def _check_my003_auto_increment_gap(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        auto_re = re.compile(r"\bAUTO_INCREMENT\b", re.IGNORECASE)
        if auto_re.search(content):
            for i, line in enumerate(lines, 1):
                if auto_re.search(line):
                    self.violations.append(Violation(
                        rule_id="SA-MY003",
                        severity=Severity.LOW,
                        line_number=i,
                        line_text=raw_lines[i - 1].strip(),
                        message="AUTO_INCREMENT may produce gaps on rollback or bulk insert",
                        suggestion="Do not rely on AUTO_INCREMENT being contiguous; use for uniqueness only",
                        dialect_specific=True,
                        fix_text="No code change needed -- ensure application logic does not assume contiguous IDs",
                    ))
                    break  # one warning per file is enough

    # SA-MY004 ENUM type
    def _check_my004_enum_type(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        pat = re.compile(r"\bENUM\s*\(", re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-MY004",
                    severity=Severity.MEDIUM,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="ENUM requires ALTER TABLE to add new values -- poor for evolving domains",
                    suggestion="Use a lookup/reference table instead of ENUM",
                    dialect_specific=True,
                    fix_text="Replace ENUM with a foreign key to a lookup table",
                ))

    # SA-MY005 SELECT without LIMIT
    def _check_my005_select_no_limit(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        # Only flag top-level SELECTs (not sub-queries) that lack LIMIT
        select_re = re.compile(r"^\s*SELECT\b", re.IGNORECASE)
        limit_re = re.compile(r"\bLIMIT\b", re.IGNORECASE)
        subq_re = re.compile(r"\(\s*SELECT\b", re.IGNORECASE)

        i = 0
        while i < len(lines):
            line = lines[i]
            i += 1
            if not select_re.search(line):
                continue
            if subq_re.search(line):
                continue
            # Look ahead up to 30 lines for LIMIT or end-of-statement
            found_limit = False
            for j in range(i - 1, min(i + 30, len(lines))):
                if limit_re.search(lines[j]):
                    found_limit = True
                    break
                if ";" in lines[j] and j > i - 1:
                    break
            if not found_limit:
                self.violations.append(Violation(
                    rule_id="SA-MY005",
                    severity=Severity.LOW,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="SELECT without LIMIT may return unbounded rows",
                    suggestion="Add LIMIT clause for application queries to prevent excessive data transfer",
                    dialect_specific=True,
                    fix_text="Add LIMIT clause: ... LIMIT 1000 (adjust as appropriate)",
                ))

    # =====================================================================
    # SQLITE-SPECIFIC CHECKS
    # =====================================================================

    def _run_sqlite_checks(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        self._check_lite001_journal_mode_wal(content, lines, raw_lines)
        self._check_lite002_foreign_keys(content, lines, raw_lines)
        self._check_lite003_autoincrement(lines, raw_lines)
        self._check_lite004_busy_timeout(content, lines, raw_lines)
        self._check_lite005_varchar_length(lines, raw_lines)

    # SA-LITE001 Missing PRAGMA journal_mode=WAL
    def _check_lite001_journal_mode_wal(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """SQLite performs dramatically better with WAL mode for concurrent reads.

        Without WAL, readers block writers and writers block readers.
        This check flags files that contain DML or DDL but do not set WAL mode.
        """
        has_dml = re.search(
            r"\b(?:INSERT|UPDATE|DELETE|CREATE\s+TABLE|SELECT)\b", content, re.IGNORECASE
        )
        has_wal = re.search(
            r"\bPRAGMA\s+journal_mode\s*=\s*WAL\b", content, re.IGNORECASE
        )
        has_any_journal = re.search(
            r"\bPRAGMA\s+journal_mode\b", content, re.IGNORECASE
        )

        if has_dml and not has_wal:
            # Find the first PRAGMA or the first line to report on
            target_line = 1
            for i, line in enumerate(lines, 1):
                if has_any_journal and re.search(r"\bPRAGMA\s+journal_mode\b", line, re.IGNORECASE):
                    target_line = i
                    break
                if re.search(r"\bPRAGMA\b", line, re.IGNORECASE):
                    target_line = i
                    break
                if re.search(r"\b(?:CREATE\s+TABLE|INSERT|SELECT)\b", line, re.IGNORECASE):
                    target_line = i
                    break
            self.violations.append(Violation(
                rule_id="SA-LITE001",
                severity=Severity.HIGH,
                line_number=target_line,
                line_text=raw_lines[target_line - 1].strip(),
                message="Missing PRAGMA journal_mode=WAL -- SQLite defaults to DELETE mode which blocks concurrent access",
                suggestion="Add 'PRAGMA journal_mode=WAL;' at the start of your connection setup",
                dialect_specific=True,
                fix_text="Add at top of file: PRAGMA journal_mode=WAL;",
            ))

    # SA-LITE002 Missing PRAGMA foreign_keys=ON
    def _check_lite002_foreign_keys(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """SQLite does NOT enforce foreign keys by default.  They must be
        explicitly enabled per connection with PRAGMA foreign_keys=ON.
        """
        has_fk_def = re.search(
            r"\bFOREIGN\s+KEY\b|\bREFERENCES\b", content, re.IGNORECASE
        )
        has_fk_pragma = re.search(
            r"\bPRAGMA\s+foreign_keys\s*=\s*(?:ON|1|TRUE)\b", content, re.IGNORECASE
        )

        if has_fk_def and not has_fk_pragma:
            target_line = 1
            for i, line in enumerate(lines, 1):
                if re.search(r"\bFOREIGN\s+KEY\b|\bREFERENCES\b", line, re.IGNORECASE):
                    target_line = i
                    break
            self.violations.append(Violation(
                rule_id="SA-LITE002",
                severity=Severity.HIGH,
                line_number=target_line,
                line_text=raw_lines[target_line - 1].strip(),
                message="Foreign keys defined but PRAGMA foreign_keys=ON is missing -- constraints will NOT be enforced",
                suggestion="Add 'PRAGMA foreign_keys=ON;' before any DML statements",
                dialect_specific=True,
                fix_text="Add at top of file: PRAGMA foreign_keys=ON;",
            ))

    # SA-LITE003 Using AUTOINCREMENT unnecessarily
    def _check_lite003_autoincrement(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        """In SQLite, INTEGER PRIMARY KEY is already an alias for rowid and
        auto-generates values.  AUTOINCREMENT adds overhead (maintains the
        sqlite_sequence table) and is rarely needed -- it only guarantees
        monotonically increasing IDs (never reuses deleted IDs), which most
        applications don't require.
        """
        pat = re.compile(r"\bAUTOINCREMENT\b", re.IGNORECASE)
        for i, line in enumerate(lines, 1):
            if pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-LITE003",
                    severity=Severity.LOW,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="AUTOINCREMENT adds overhead -- INTEGER PRIMARY KEY already auto-generates IDs",
                    suggestion="Remove AUTOINCREMENT unless you specifically need non-reuse of deleted rowids",
                    dialect_specific=True,
                    fix_text="Remove AUTOINCREMENT: change to 'column_name INTEGER PRIMARY KEY'",
                ))

    # SA-LITE004 Missing PRAGMA busy_timeout
    def _check_lite004_busy_timeout(
        self, content: str, lines: List[str], raw_lines: List[str]
    ) -> None:
        """Without busy_timeout, SQLite immediately returns SQLITE_BUSY when
        the database is locked, instead of retrying.  This causes spurious
        errors under any concurrent access.
        """
        has_write = re.search(
            r"\b(?:INSERT|UPDATE|DELETE|CREATE)\b", content, re.IGNORECASE
        )
        has_busy = re.search(
            r"\bPRAGMA\s+busy_timeout\b", content, re.IGNORECASE
        )

        if has_write and not has_busy:
            target_line = 1
            for i, line in enumerate(lines, 1):
                if re.search(r"\bPRAGMA\b", line, re.IGNORECASE):
                    target_line = i
                    break
                if re.search(r"\b(?:INSERT|UPDATE|DELETE|CREATE)\b", line, re.IGNORECASE):
                    target_line = i
                    break
            self.violations.append(Violation(
                rule_id="SA-LITE004",
                severity=Severity.MEDIUM,
                line_number=target_line,
                line_text=raw_lines[target_line - 1].strip(),
                message="Missing PRAGMA busy_timeout -- concurrent writes will get SQLITE_BUSY immediately",
                suggestion="Add 'PRAGMA busy_timeout=5000;' (5 seconds) for concurrent access",
                dialect_specific=True,
                fix_text="Add at top of file: PRAGMA busy_timeout=5000;",
            ))

    # SA-LITE005 VARCHAR with length constraint in SQLite
    def _check_lite005_varchar_length(
        self, lines: List[str], raw_lines: List[str]
    ) -> None:
        """SQLite ignores VARCHAR length constraints entirely.  VARCHAR(10) and
        VARCHAR(10000) both store as TEXT with no length enforcement.  This
        misleads developers into thinking the constraint is enforced.
        """
        pat = re.compile(r"\bVARCHAR\s*\(\s*\d+\s*\)", re.IGNORECASE)
        # Only flag in DDL context
        ddl_re = re.compile(r"\b(?:CREATE|ALTER)\s+TABLE\b", re.IGNORECASE)
        in_ddl = False

        for i, line in enumerate(lines, 1):
            if ddl_re.search(line):
                in_ddl = True
            if in_ddl and pat.search(line):
                self.violations.append(Violation(
                    rule_id="SA-LITE005",
                    severity=Severity.LOW,
                    line_number=i,
                    line_text=raw_lines[i - 1].strip(),
                    message="VARCHAR(N) length constraint has no effect in SQLite -- all text is stored as TEXT",
                    suggestion="Use TEXT instead of VARCHAR(N) in SQLite, or add CHECK constraint for length",
                    dialect_specific=True,
                    fix_text="Replace VARCHAR(N) with TEXT, and add CHECK(length(column) <= N) if needed",
                ))
            if re.search(r"^\s*\)\s*;?\s*$", line):
                in_ddl = False

    # =====================================================================
    # Output formatters
    # =====================================================================

    @staticmethod
    def _supports_color() -> bool:
        """Check if the terminal likely supports ANSI colour codes."""
        if os.environ.get("NO_COLOR"):
            return False
        if os.environ.get("TERM") == "dumb":
            return False
        if hasattr(sys.stdout, "isatty") and sys.stdout.isatty():
            return True
        # On Windows, check if the terminal supports VT100
        if sys.platform == "win32":
            try:
                import ctypes
                kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
                mode = ctypes.c_ulong()
                handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
                if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                    # ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
                    if mode.value & 0x0004:
                        return True
                    # Try to enable it
                    kernel32.SetConsoleMode(handle, mode.value | 0x0004)
                    return True
            except Exception:
                pass
        return False


# ---------------------------------------------------------------------------
# Formatting helpers (module-level for reuse)
# ---------------------------------------------------------------------------

_SEVERITY_ORDER = {
    Severity.CRITICAL: 0,
    Severity.HIGH: 1,
    Severity.MEDIUM: 2,
    Severity.LOW: 3,
}

_SEVERITY_COLORS = {
    Severity.CRITICAL: "\033[91m",  # Red
    Severity.HIGH: "\033[93m",      # Yellow
    Severity.MEDIUM: "\033[94m",    # Blue
    Severity.LOW: "\033[90m",       # Gray
}
_RESET = "\033[0m"


def _format_report(
    filepath: str,
    dialect: Dialect,
    violations: List[Violation],
    use_color: bool,
    show_fixes: bool = False,
) -> str:
    """Build the human-readable report string."""
    parts = []  # type: List[str]
    sep = "=" * 70

    parts.append(sep)
    parts.append("SQL Valid8 Analyzer - Multi-Dialect SQL Analysis")
    parts.append(sep)
    parts.append("")
    parts.append("File: {}".format(filepath))
    parts.append("Detected Dialect: {}".format(dialect.value.upper()))
    parts.append("")

    if not violations:
        parts.append("No issues found.")
        parts.append("")
        return "\n".join(parts)

    # Group by severity
    grouped = {}  # type: Dict[Severity, List[Violation]]
    for v in violations:
        grouped.setdefault(v.severity, []).append(v)

    for sev in [Severity.CRITICAL, Severity.HIGH, Severity.MEDIUM, Severity.LOW]:
        vlist = grouped.get(sev)
        if not vlist:
            continue
        vlist.sort(key=lambda v: v.line_number)
        if use_color:
            parts.append("{}{}:{}".format(_SEVERITY_COLORS[sev], sev.value, _RESET))
        else:
            parts.append("{}:".format(sev.value))
        for v in vlist:
            preview = v.line_text[:80]
            if len(v.line_text) > 80:
                preview += "..."
            parts.append("  Line {}: [{}] {}".format(v.line_number, v.rule_id, v.message))
            if preview:
                parts.append("    | {}".format(preview))
            parts.append("    -> {}".format(v.suggestion))
            if show_fixes and v.fix_text:
                if use_color:
                    parts.append("    \033[92mFIX:\033[0m {}".format(v.fix_text))
                else:
                    parts.append("    FIX: {}".format(v.fix_text))
            parts.append("")

    # Summary line
    counts = {}  # type: Dict[str, int]
    for v in violations:
        key = v.severity.value
        counts[key] = counts.get(key, 0) + 1
    summary_parts = []
    for sev_name in ["CRITICAL", "HIGH", "MEDIUM", "LOW"]:
        c = counts.get(sev_name, 0)
        if c:
            summary_parts.append("{} {}".format(c, sev_name))
    parts.append(
        "Summary: {} issues found ({})".format(len(violations), ", ".join(summary_parts))
    )
    parts.append("")
    return "\n".join(parts)


def _format_json(
    filepath: str,
    dialect: Dialect,
    violations: List[Violation],
) -> dict:
    """Build the JSON-serialisable report dict."""
    return {
        "file": filepath,
        "dialect": dialect.value,
        "violations_count": len(violations),
        "violations": [v.to_dict() for v in violations],
    }


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="analyze_sql",
        description="nitsql - Multi-Dialect SQL Analyzer (example)",
    )
    p.add_argument(
        "paths",
        nargs="*",
        help="SQL file(s) or directories to analyse",
    )
    p.add_argument(
        "--dialect",
        choices=["mssql", "postgresql", "oracle", "mysql", "sqlite"],
        default=None,
        help="Override auto-detected dialect",
    )
    p.add_argument(
        "--all",
        action="store_true",
        dest="scan_all",
        help="Recursively analyse all .sql files under current directory",
    )
    p.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Output results as JSON (for CI/CD integration)",
    )
    p.add_argument(
        "--severity",
        choices=["critical", "high", "medium", "low"],
        default=None,
        help="Filter output to this severity level and above",
    )
    p.add_argument(
        "--fix",
        action="store_true",
        dest="show_fixes",
        help="Show suggested fix text for each violation",
    )
    return p


def _collect_files(paths: List[str], scan_all: bool) -> List[Path]:
    """Resolve CLI paths into a list of .sql files."""
    files = []  # type: List[Path]
    if scan_all:
        files.extend(Path(".").rglob("*.sql"))
    for p in paths:
        pp = Path(p)
        if pp.is_file():
            files.append(pp)
        elif pp.is_dir():
            files.extend(pp.rglob("*.sql"))
        else:
            print("Warning: '{}' not found, skipping".format(p), file=sys.stderr)
    return sorted(set(files))


def _filter_severity(
    violations: List[Violation], min_severity: Optional[str]
) -> List[Violation]:
    """Keep only violations at or above *min_severity*."""
    if min_severity is None:
        return violations
    threshold = {
        "critical": 0,
        "high": 1,
        "medium": 2,
        "low": 3,
    }.get(min_severity.lower(), 3)
    return [v for v in violations if _SEVERITY_ORDER[v.severity] <= threshold]


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    if not args.paths and not args.scan_all:
        parser.print_help(sys.stderr)
        return 1

    dialect_override = None  # type: Optional[Dialect]
    if args.dialect:
        dialect_override = Dialect(args.dialect)

    files = _collect_files(args.paths or [], args.scan_all)
    if not files:
        print("No .sql files found.", file=sys.stderr)
        return 0

    use_color = SQLAnalyzer._supports_color() and not args.json_output
    show_fixes = args.show_fixes

    all_violations = []  # type: List[Violation]
    json_reports = []  # type: List[dict]
    critical_count = 0
    file_results = []  # type: List[Tuple[str, int, bool]]

    for fp in files:
        analyzer = SQLAnalyzer(dialect=dialect_override, show_fixes=show_fixes)
        dialect, violations = analyzer.analyze_file(fp)
        violations = _filter_severity(violations, args.severity)
        violations.sort(key=lambda v: (_SEVERITY_ORDER[v.severity], v.line_number))

        file_critical = sum(1 for v in violations if v.severity == Severity.CRITICAL)
        file_high = sum(1 for v in violations if v.severity == Severity.HIGH)
        # A file passes if it has no CRITICAL or HIGH violations
        file_pass = (file_critical == 0 and file_high == 0)
        file_results.append((str(fp), len(violations), file_pass))

        all_violations.extend(violations)
        critical_count += file_critical

        if args.json_output:
            json_reports.append(_format_json(str(fp), dialect, violations))
        else:
            report = _format_report(str(fp), dialect, violations, use_color, show_fixes)
            print(report)

    # Compute summary statistics
    total_files = len(files)
    total_violations = len(all_violations)
    sev_counts = {}  # type: Dict[str, int]
    for v in all_violations:
        sev_counts[v.severity.value] = sev_counts.get(v.severity.value, 0) + 1

    pass_count = sum(1 for _, _, passed in file_results if passed)
    fail_count = total_files - pass_count
    overall_pass = (critical_count == 0)

    if args.json_output:
        output = {
            "files_analyzed": total_files,
            "total_violations": total_violations,
            "severity_counts": {
                "CRITICAL": sev_counts.get("CRITICAL", 0),
                "HIGH": sev_counts.get("HIGH", 0),
                "MEDIUM": sev_counts.get("MEDIUM", 0),
                "LOW": sev_counts.get("LOW", 0),
            },
            "files_passed": pass_count,
            "files_failed": fail_count,
            "overall_result": "PASS" if overall_pass else "FAIL",
            "reports": json_reports,
        }
        print(json.dumps(output, indent=2))
    else:
        # Print grand summary
        sep = "=" * 70
        print(sep)
        print("SUMMARY")
        print(sep)
        print("")
        print("Files analysed:  {}".format(total_files))
        print("Total violations: {}".format(total_violations))
        print("")
        print("Violations by severity:")
        print("  CRITICAL: {}".format(sev_counts.get("CRITICAL", 0)))
        print("  HIGH:     {}".format(sev_counts.get("HIGH", 0)))
        print("  MEDIUM:   {}".format(sev_counts.get("MEDIUM", 0)))
        print("  LOW:      {}".format(sev_counts.get("LOW", 0)))
        print("")
        print("Files passed:  {} / {}".format(pass_count, total_files))
        print("Files failed:  {} / {}".format(fail_count, total_files))
        print("")
        if use_color:
            if overall_pass:
                print("\033[92mOverall result: PASS\033[0m")
            else:
                print("\033[91mOverall result: FAIL\033[0m")
        else:
            print("Overall result: {}".format("PASS" if overall_pass else "FAIL"))
        print(sep)

    # Non-zero exit if critical violations found (for CI/CD gating)
    if critical_count > 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
