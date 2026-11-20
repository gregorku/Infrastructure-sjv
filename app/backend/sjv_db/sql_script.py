"""Split a SQL file into statements without breaking dollar-quoted bodies."""


def sql_statements(script: str) -> list[str]:
    statements: list[str] = []
    buf: list[str] = []
    i = 0
    length = len(script)
    dollar: str | None = None
    while i < length:
        if dollar is None and script.startswith("--", i):
            newline = script.find("\n", i)
            i = length if newline < 0 else newline + 1
            continue
        if dollar is None and script[i] == "'":
            buf.append(script[i])
            i += 1
            while i < length:
                buf.append(script[i])
                if script[i] == "'":
                    if i + 1 < length and script[i + 1] == "'":
                        buf.append(script[i + 1])
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            continue
        if script.startswith("$", i):
            end = i + 1
            while end < length and (script[end].isalnum() or script[end] == "_"):
                end += 1
            if end < length and script[end] == "$":
                tag = script[i : end + 1]
                if dollar is None:
                    dollar = tag
                elif dollar == tag:
                    dollar = None
                buf.append(tag)
                i = end + 1
                continue
        if dollar is None and script[i] == ";":
            statement = "".join(buf).strip()
            if statement:
                statements.append(statement)
            buf = []
            i += 1
            continue
        buf.append(script[i])
        i += 1
    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return statements
