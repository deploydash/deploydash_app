import re

_CREATE_DATABASE_RE = re.compile(rb"^\s*CREATE\s+DATABASE\b", re.IGNORECASE)
_ROLE_STATEMENT_RE = re.compile(
    rb"^\s*(?:CREATE|ALTER|DROP)\s+(?:ROLE|USER|GROUP)\b",
    re.IGNORECASE,
)
_ALTER_SYSTEM_RE = re.compile(rb"^\s*ALTER\s+SYSTEM\b", re.IGNORECASE)
_SESSION_AUTHORIZATION_RE = re.compile(
    rb"^\s*SET\s+SESSION\s+AUTHORIZATION\b",
    re.IGNORECASE,
)
_CONCURRENTLY_RE = re.compile(rb"\bCONCURRENTLY\b", re.IGNORECASE)
_CREATE_EXTENSION_RE = re.compile(
    rb"^\s*CREATE\s+EXTENSION\b",
    re.IGNORECASE,
)
_EXTENSION_NAME_RE = re.compile(
    rb'^\s*CREATE\s+EXTENSION\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:"([^"]+)"|([A-Za-z_][\w$]*))',
    re.IGNORECASE,
)
_COMMENT_ON_EXTENSION_RE = re.compile(
    rb"^\s*COMMENT\s+ON\s+EXTENSION\b",
    re.IGNORECASE,
)
_COMMENT_ON_EXTENSION_NAME_RE = re.compile(
    rb'^\s*COMMENT\s+ON\s+EXTENSION\s+(?:"([^"]+)"|([A-Za-z_][\w$]*))',
    re.IGNORECASE,
)
_COPY_FROM_STDIN_RE = re.compile(
    rb"^\s*COPY\b.*\bFROM\s+STDIN\b",
    re.IGNORECASE | re.DOTALL,
)
_OWNER_TO_RE = re.compile(
    rb"^\s*ALTER\s+\w+"
    rb"(?!.*\bRENAME\s+(?:COLUMN\s+)?OWNER\s+TO\b)"
    rb".*\bOWNER\s+TO\b",
    re.IGNORECASE | re.DOTALL,
)
_GRANT_REVOKE_RE = re.compile(rb"^\s*(?:GRANT|REVOKE)\b", re.IGNORECASE)
_ALTER_DEFAULT_PRIVILEGES_RE = re.compile(
    rb"^\s*ALTER\s+DEFAULT\s+PRIVILEGES\b",
    re.IGNORECASE,
)
_META_COMMAND_RE = re.compile(rb"\\([A-Za-z]+)")
_DOLLAR_TAG_OPEN_RE = re.compile(rb"\$[A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*\$|\$\$")
_DUMP_SPECIAL_BYTE_RE = re.compile(rb"['\"$;\-/]")

_BLOCKING_STATEMENT_PATTERNS = (
    (
        _CREATE_DATABASE_RE,
        "create_database",
        "The dump creates a database. Re-export a single database "
        "without pg_dump -C and import that file instead.",
    ),
    (
        _ROLE_STATEMENT_RE,
        "role_statement",
        "The dump creates, changes or drops a database role. Imports "
        "cannot manage roles; re-export a single database without roles "
        "and import that file instead.",
    ),
    (
        _ALTER_SYSTEM_RE,
        "alter_system",
        "The dump changes server settings (ALTER SYSTEM). Imports cannot "
        "change server settings; apply them from Server management instead.",
    ),
    (
        _SESSION_AUTHORIZATION_RE,
        "session_authorization",
        "The dump changes the session authorization. Imports run as a "
        "temporary import role; remove SET SESSION AUTHORIZATION and "
        "import again.",
    ),
    (
        _CONCURRENTLY_RE,
        "concurrent_statement",
        "The dump uses CONCURRENTLY, which cannot run inside the single "
        "transaction imports use. Re-export without concurrent operations "
        "or run those statements separately.",
    ),
)
_OWNERSHIP_STATEMENT_PATTERNS = (
    _OWNER_TO_RE,
    _GRANT_REVOKE_RE,
    _ALTER_DEFAULT_PRIVILEGES_RE,
)
_META_CONNECT_COMMANDS = (b"connect", b"c")
_META_INCLUDE_COMMANDS = (b"include", b"ir", b"i")
_ALWAYS_AVAILABLE_DUMP_EXTENSIONS = ("plpgsql",)
_ESTRING_PREFIXES = (0x45, 0x65)
_IDENTIFIER_CONTINUE_BYTES = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_$"


def _scan_local_sql_dump(path, *, enabled_extensions=()):
    """Scan a workstation dump for statements the hardened import rejects.

    Runs on the desktop before anything is uploaded, so a doomed import
    fails here with guidance instead of halfway through on the server.
    Blocking findings stop the import; ownership statements only count,
    because the caller may opt into filtering them out (#84).
    """
    blocking = []
    notices = []
    ownership_statement_count = 0
    extension_statement_count = 0
    enabled = tuple(enabled_extensions or ())
    with open(path, "rb") as handle:
        for kind, original, code, start_line in _iter_sql_dump_segments(handle):
            if kind in ("copy_data", "trailing"):
                continue
            if kind == "meta":
                finding, notice = _classify_dump_meta_command(original, start_line)
                if finding is not None:
                    blocking.append(finding)
                if notice is not None:
                    notices.append(notice)
                continue
            finding, is_ownership, is_extension = _classify_dump_statement(
                code,
                original,
                start_line,
                enabled_extensions=enabled,
            )
            if finding is not None:
                blocking.append(finding)
            if is_ownership:
                ownership_statement_count += 1
            if is_extension:
                extension_statement_count += 1
            if kind == "unterminated":
                blocking.append(
                    {
                        "code": "unterminated_statement",
                        "line": start_line,
                        "message": "The file ends inside a statement. "
                        "Re-export the dump; a truncated file cannot be imported.",
                    }
                )
    return {
        "blocking": blocking,
        "ownership_statement_count": ownership_statement_count,
        "extension_statement_count": extension_statement_count,
        "notices": notices,
    }


def _write_filtered_sql_dump(
    source_path,
    dest_path,
    *,
    enabled_extensions=(),
    drop_ownership=True,
    drop_extensions=False,
):
    """Copy a dump minus caller-selected managed statements.

    The "ignore ownership" import option rewrites the workstation file
    through here before upload, which is what lets plain pg_dump output
    referencing foreign roles import cleanly under the owner session (#84).
    Extension setup is also removed when Deploy Dash already owns those
    extensions, while comments on application objects remain untouched.
    """
    dropped_statements = 0
    dropped_ownership_statements = 0
    dropped_extension_statements = 0
    with open(source_path, "rb") as source, open(dest_path, "wb") as dest:
        for kind, original, code, _ in _iter_sql_dump_segments(source):
            if kind in ("statement", "unterminated"):
                _, is_ownership, is_extension = _classify_dump_statement(
                    code,
                    original,
                    0,
                    enabled_extensions=tuple(enabled_extensions or ()),
                )
                if drop_ownership and is_ownership:
                    dropped_statements += 1
                    dropped_ownership_statements += 1
                    continue
                if drop_extensions and is_extension:
                    dropped_statements += 1
                    dropped_extension_statements += 1
                    continue
            dest.write(original)
    return {
        "dropped_statements": dropped_statements,
        "dropped_ownership_statements": dropped_ownership_statements,
        "dropped_extension_statements": dropped_extension_statements,
    }


def _iter_sql_dump_segments(handle):
    """Split a binary dump into statements, meta commands and COPY data.

    Yields (kind, original, code, start_line): statements carry a code view
    with quoted and commented bytes blanked so keyword matching never sees
    string contents, while the original bytes stay byte-identical for the
    filter to replay. A final segment with code but no semicolon is
    "unterminated"; bytes after the last semicolon are "trailing". Streams
    line by line so multi-gigabyte dumps never sit in memory whole (#84).
    """
    statement = bytearray()
    code = bytearray()
    start_line = 1
    lineno = 0
    in_copy_data = False
    quote = None
    quote_escape = False
    dollar_tag = None
    block_depth = 0
    for raw_line in handle:
        lineno += 1
        if in_copy_data:
            yield ("copy_data", bytes(raw_line), None, lineno)
            if raw_line.strip() == b"\\.":
                in_copy_data = False
            continue
        if (
            quote is None
            and dollar_tag is None
            and block_depth == 0
            and raw_line.lstrip().startswith(b"\\")
        ):
            yield ("meta", bytes(raw_line), bytes(raw_line), lineno)
            continue
        if not code.strip():
            start_line = lineno
        pos = 0
        length = len(raw_line)
        while pos < length:
            if quote is None and dollar_tag is None and block_depth == 0:
                special = _DUMP_SPECIAL_BYTE_RE.search(raw_line, pos)
                if special is None:
                    statement += raw_line[pos:]
                    code += raw_line[pos:]
                    break
                if special.start() > pos:
                    statement += raw_line[pos : special.start()]
                    code += raw_line[pos : special.start()]
                    pos = special.start()
            byte = raw_line[pos]
            if dollar_tag is not None:
                if raw_line.startswith(dollar_tag, pos):
                    statement += dollar_tag
                    code += b" " * len(dollar_tag)
                    pos += len(dollar_tag)
                    dollar_tag = None
                else:
                    statement.append(byte)
                    code.append(0x20)
                    pos += 1
            elif quote is not None:
                if quote_escape and byte == 0x5C:
                    chunk = raw_line[pos : pos + 2]
                    statement += chunk
                    code += b" " * len(chunk)
                    pos += len(chunk)
                elif byte == quote:
                    following = raw_line[pos + 1 : pos + 2]
                    if following and following[0] == quote:
                        statement += raw_line[pos : pos + 2]
                        code += b"  "
                        pos += 2
                    else:
                        statement.append(byte)
                        code.append(0x20)
                        quote = None
                        pos += 1
                else:
                    statement.append(byte)
                    code.append(0x20)
                    pos += 1
            elif block_depth > 0:
                pair = raw_line[pos : pos + 2]
                if pair == b"/*":
                    statement += pair
                    code += b"  "
                    block_depth += 1
                    pos += 2
                elif pair == b"*/":
                    statement += pair
                    code += b"  "
                    block_depth -= 1
                    pos += 2
                else:
                    statement.append(byte)
                    code.append(0x20)
                    pos += 1
            elif byte == 0x3B:
                statement.append(byte)
                code.append(0x20)
                pos += 1
                code_bytes = bytes(code)
                if _COPY_FROM_STDIN_RE.search(code_bytes):
                    in_copy_data = True
                    statement += raw_line[pos:]
                    code += b" " * (length - pos)
                    pos = length
                yield ("statement", bytes(statement), code_bytes, start_line)
                statement = bytearray()
                code = bytearray()
            elif byte in (0x27, 0x22):
                tail = (b"\x00\x00" + bytes(code[-2:]))[-2:]
                quote_escape = (
                    byte == 0x27
                    and tail[1] in _ESTRING_PREFIXES
                    and tail[0] not in _IDENTIFIER_CONTINUE_BYTES
                )
                statement.append(byte)
                code.append(0x20)
                quote = byte
                pos += 1
            elif byte == 0x24:
                tag_match = _DOLLAR_TAG_OPEN_RE.match(raw_line, pos)
                if tag_match is None:
                    statement.append(byte)
                    code.append(byte)
                    pos += 1
                else:
                    tag = tag_match.group(0)
                    statement += tag
                    code += b" " * len(tag)
                    dollar_tag = tag
                    pos += len(tag)
            elif byte == 0x2D:
                if raw_line[pos : pos + 2] == b"--":
                    statement += raw_line[pos:]
                    code += b" " * (length - pos)
                    pos = length
                else:
                    statement.append(byte)
                    code.append(byte)
                    pos += 1
            elif raw_line[pos : pos + 2] == b"/*":
                statement += b"/*"
                code += b"  "
                block_depth = 1
                pos += 2
            else:
                statement.append(byte)
                code.append(byte)
                pos += 1
    if code.strip():
        yield ("unterminated", bytes(statement), bytes(code), start_line)
    elif statement:
        # Trailing whitespace and comments after the last semicolon: no
        # statement to classify, but the filter must replay these bytes.
        yield ("trailing", bytes(statement), None, start_line)


def _classify_dump_statement(code, original, start_line, *, enabled_extensions):
    """Decide whether one statement blocks the import or is droppable.

    Returns (blocking finding or None, is-ownership, is-managed-extension).
    Blocking wins over
    ownership: a statement the import cannot run is reported even when it
    also looks like a privilege statement. Keyword matching reads the
    blanked code view; the original bytes only feed name extraction (#84).
    """
    for pattern, finding_code, message in _BLOCKING_STATEMENT_PATTERNS:
        if pattern.search(code):
            return (
                {"code": finding_code, "line": start_line, "message": message},
                False,
                False,
            )
    extension_name = _extension_statement_name(code, original)
    if extension_name is not None:
        if extension_name and (
            extension_name in enabled_extensions
            or extension_name in _ALWAYS_AVAILABLE_DUMP_EXTENSIONS
        ):
            return None, False, True
        if extension_name:
            message = (
                f"The dump needs the '{extension_name}' extension. "
                f"Enable {extension_name} in Database settings and import again."
            )
        else:
            message = (
                "The dump creates an extension Deploy Dash could not "
                "identify. Enable every extension the dump needs in Database "
                "settings and import again."
            )
        return (
            {"code": "missing_extension", "line": start_line, "message": message},
            False,
            False,
        )
    for pattern in _OWNERSHIP_STATEMENT_PATTERNS:
        if pattern.search(code):
            return None, True, False
    return None, False, False


def _classify_dump_meta_command(line, start_line):
    """Decide whether one psql backslash command blocks the import.

    Returns (blocking finding or None, notice or None). Database switches
    and file reads cannot work in the throwaway client so they block with
    guidance; a shell escape only ever runs inside that disposable client,
    so it is a notice rather than a blocker (#84).
    """
    text = line.strip()
    if text.startswith(b"\\!"):
        return None, {
            "code": "shell_escape",
            "line": start_line,
            "message": "The dump runs a shell command (\\!), which executes "
            "only inside the throwaway import client and is discarded "
            "afterwards.",
        }
    command_match = _META_COMMAND_RE.match(text)
    if command_match is None:
        return None, None
    command = command_match.group(1).lower()
    if command in _META_CONNECT_COMMANDS:
        return {
            "code": "connect_command",
            "line": start_line,
            "message": "The dump switches databases (\\connect). Re-export a "
            "single database without pg_dump -C and import that file instead.",
        }, None
    if command in _META_INCLUDE_COMMANDS:
        return {
            "code": "include_command",
            "line": start_line,
            "message": "The dump reads another file (\\include). Inline the "
            "referenced statements into one dump file and import that instead.",
        }, None
    if command == b"copy":
        return {
            "code": "copy_command",
            "line": start_line,
            "message": "The dump uses client-side \\copy, which cannot see "
            "workstation files from the server. Rewrite it as server-side "
            "COPY ... FROM stdin or inline the data.",
        }, None
    return None, None


def _extension_statement_name(code, original):
    """Pull the extension name out of managed extension statements.

    Returns None for other statements and "" when the statement names no
    parseable extension, so the caller reports "enable it" guidance either
    way instead of failing the import opaquely. The code view locates the
    statement past leading comments, but the name itself comes from the
    original bytes, where quoted names are still intact (#84).
    """
    if _CREATE_EXTENSION_RE.match(code) is not None:
        name_pattern = _EXTENSION_NAME_RE
    elif _COMMENT_ON_EXTENSION_RE.match(code) is not None:
        name_pattern = _COMMENT_ON_EXTENSION_NAME_RE
    else:
        return None
    offset = len(code) - len(code.lstrip())
    name_match = name_pattern.match(original[offset:])
    if name_match is None:
        return ""
    name = name_match.group(1) or name_match.group(2)
    return name.decode("ascii", errors="replace")


__all__ = tuple(name for name in globals() if not name.startswith("__"))
