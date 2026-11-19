"""Own-path confinement and reversible Trash primitive shared by maintenance scripts."""
import os
from pathlib import Path
import uuid

PRESERVED_NAMES = frozenset({'keep-0.5.50', 'integrated-trial-04.app'})

def confined(path, roots, allow_root=False):
    path = Path(path).absolute()
    if '..' in path.parts or any(part in PRESERVED_NAMES for part in path.parts):
        raise ValueError('PATH_PRESERVED_OR_UNSAFE')
    for ancestor in [path, *path.parents]:
        if ancestor.is_symlink(): raise ValueError('PATH_SYMLINK')
    for root in roots:
        root = Path(root).absolute()
        if '..' in root.parts or any(p.is_symlink() for p in [root, *root.parents]):
            raise ValueError('ROOT_UNSAFE')
        if path.is_relative_to(root) and (allow_root or path != root): return path
    raise ValueError('PATH_OUTSIDE_ALLOWLIST')

def move_to_trash(path, roots, trash_root, allow_root=False):
    path = confined(path, roots, allow_root)
    # A protected directory anywhere underneath also vetoes moving its parent.
    if path.is_dir() and any(any(path.rglob(name)) for name in PRESERVED_NAMES):
        raise ValueError('PATH_CONTAINS_PRESERVED')
    trash_root = Path(trash_root).absolute()
    if any(p.is_symlink() for p in [trash_root, *trash_root.parents]) or '..' in trash_root.parts:
        raise ValueError('TRASH_UNSAFE')
    trash_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    destination = trash_root / (path.name + '-' + uuid.uuid4().hex)
    os.rename(path, destination)  # Failure leaves the original intact; never falls back to recursive deletion.
    return destination
