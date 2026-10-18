"""Find upstream notices without traversing dependency/build directories."""
import re


def notice_files(folder):
    if not folder or not folder.is_dir():
        return []
    found = []
    for path in sorted(folder.iterdir()):
        if path.is_symlink():
            continue
        named = re.match(r'^(licen[cs]e|copying|notice|ofl)([._-].*)?$|^DEVICON-LICENSE\.txt$', path.name, re.I)
        if path.is_dir() and named:
            found.extend(p for p in sorted(path.rglob('*'))
                         if p.is_file() and not any(q.is_symlink() for q in [p, *p.parents]))
        elif path.is_file():
            embedded = (re.match(r'^(readme([._-].*)?|authors)$', path.name, re.I)
                        and re.search(r'(?im)^(?:#{1,6}\s*)?licen[cs]e\s*:?[ \t]*$',
                                      path.read_text(errors='replace')))
            if named or embedded or path.name.lower().endswith('.license'):
                found.append(path)
    return found
