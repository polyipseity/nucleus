"""Sync the macOS lock-screen wallpaper with the desktop wallpaper.

macOS keeps two independent wallpaper surfaces for every Space and every
display in ``~/Library/Application Support/com.apple.wallpaper/Store/Index.plist``:
``Desktop`` (the picture on the desktop) and ``Idle`` (the picture shown on the
lock screen and by the screen saver).  Setting a desktop picture -- everything
``desktoppr`` does -- only writes ``Desktop``, so ``Idle`` keeps whatever macOS
was configured with and the lock screen drifts away from the desktop.

This helper rewrites ``Desktop`` and ``Idle`` for every Space and display to the
same folder choice.  The choice is copied from an existing folder choice in the
store and only its URL is repointed, so Apple's exact ``Configuration`` and
``EncodedOptionValues`` shapes (placement, colour, shuffle frequency) survive.

The rewrite is idempotent (a converged store is left untouched), atomic (write
to a sibling temp file, then rename), and keeps one backup of the previous
store. It exits non-zero when the store holds no folder choice to copy (the
caller must then set the folder wallpaper once through System Settings), and
exits 3 when macOS refuses write access to the store.

CLI: converge-macos-wallpaper-store.py <store-plist> <wallpaper-folder>
"""

import datetime
import errno
import os
import plistlib
import shutil
import sys
from copy import deepcopy
from pathlib import Path

_IMAGE_PROVIDER = "com.apple.wallpaper.choice.image"
_FOLDER_TYPE = "imageFolder"
_SURFACE_KEYS = ("Desktop", "Idle")
# macOS can refuse the write outright: the wallpaper store sits under
# ~/Library/Application Support, which is off limits to some processes.
_REFUSAL_ERRNOS = (errno.EACCES, errno.EPERM, errno.EROFS)
_EXIT_REFUSED = 3


class StoreNotWritable(Exception):
    """macOS refused to let this process write the wallpaper store."""


def fail(message):
    print(f"wallpaper-store: {message}", file=sys.stderr)
    sys.exit(1)


def first_choice(surface):
    """Return the first choice of a wallpaper surface, or None."""
    if not isinstance(surface, dict):
        return None
    content = surface.get("Content")
    if not isinstance(content, dict):
        return None
    choices = content.get("Choices")
    if not isinstance(choices, list) or not choices:
        return None
    return choices[0] if isinstance(choices[0], dict) else None


def choice_config(choice):
    """Decode the nested Configuration blob of a choice, or None if unreadable."""
    if not isinstance(choice, dict):
        return None
    blob = choice.get("Configuration")
    if not isinstance(blob, bytes):
        return None
    try:
        config = plistlib.loads(blob)
    except (plistlib.InvalidFileException, ValueError):
        return None
    return config if isinstance(config, dict) else None


def is_folder_choice(choice):
    config = choice_config(choice)
    return config is not None and config.get("type") == _FOLDER_TYPE


def choice_url(choice):
    config = choice_config(choice)
    if config is None:
        return None
    url = config.get("url")
    if not isinstance(url, dict):
        return None
    relative = url.get("relative")
    return relative if isinstance(relative, str) else None


def walk_surfaces(node, found):
    """Collect every node holding a Desktop or Idle surface."""
    if not isinstance(node, dict):
        return
    if any(key in node for key in _SURFACE_KEYS):
        found.append(node)
        return
    for key in sorted(node):
        walk_surfaces(node[key], found)


def is_converged(surface, uris):
    """True when a surface already shows the wallpaper folder."""
    choice = first_choice(surface)
    if choice is None or choice.get("Provider") != _IMAGE_PROVIDER:
        return False
    return is_folder_choice(choice) and choice_url(choice) in uris


def folder_uris(folder):
    """URL forms the store uses for a folder choice.

    ``desktoppr`` appends ``/.`` so macOS keeps treating the path as a folder;
    choices written by the System Settings picker omit it.  Both resolve to the
    same folder, so either counts as converged.
    """
    uri = Path(folder).as_uri()
    return {uri, f"{uri}/."}


def converged_surface(template_surface, target_url, now, previous):
    """Build a surface that shows ``target_url``, reusing the template's shape."""
    surface = {
        "Content": deepcopy(template_surface["Content"]),
        "LastSet": now,
    }
    choice = first_choice(surface)
    config = choice_config(choice)
    if choice is None or config is None:
        fail("wallpaper folder choice template is missing its Configuration blob")
    config["url"]["relative"] = target_url
    choice["Configuration"] = plistlib.dumps(config, fmt=plistlib.FMT_BINARY)
    if isinstance(previous, dict) and isinstance(previous.get("LastUse"), datetime.datetime):
        surface["LastUse"] = previous["LastUse"]
    return surface


def find_template(surfaces):
    """Return the first image-folder surface in the store, or None."""
    for node in surfaces:
        for key in _SURFACE_KEYS:
            surface = node.get(key)
            choice = first_choice(surface)
            if choice is None or choice.get("Provider") != _IMAGE_PROVIDER:
                continue
            if is_folder_choice(choice):
                return surface
    return None


def surface_last_set(template_surface):
    """Current time in the type the store uses for LastSet timestamps."""
    if not isinstance(template_surface.get("LastSet"), datetime.datetime):
        fail("wallpaper surface template has no LastSet timestamp to mirror")
    return datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None, microsecond=0)


def write_atomically(store_path, payload):
    """Replace the store through a sibling temp file, keeping one backup."""
    backup_path = store_path.parent / f"{store_path.name}.nucleus.bak"
    try:
        if not backup_path.exists():
            shutil.copy2(store_path, backup_path)
        temp_path = store_path.parent / f".{store_path.name}.nucleus.tmp"
        temp_path.write_bytes(payload)
        os.chmod(temp_path, 0o644)
        os.replace(temp_path, store_path)
    except OSError as error:
        if error.errno in _REFUSAL_ERRNOS:
            raise StoreNotWritable(str(error)) from error
        raise


def converge(store_path, folder):
    if not store_path.is_file():
        fail(f"wallpaper store not found at {store_path}; set the wallpaper folder once in System Settings")
    original = plistlib.loads(store_path.read_bytes())

    surfaces = []
    walk_surfaces(original, surfaces)
    if not surfaces:
        fail(f"wallpaper store at {store_path} holds no Desktop or Idle surfaces")

    template_surface = find_template(surfaces)
    if template_surface is None:
        fail(
            f"wallpaper store at {store_path} holds no image folder choice to copy; "
            "set the wallpaper folder once in System Settings"
        )

    template_url = choice_url(first_choice(template_surface))
    suffix = "/." if template_url.endswith("/.") else ""
    target_url = f"{Path(folder).as_uri()}{suffix}"
    uris = folder_uris(folder)

    updated = deepcopy(original)
    updated_surfaces = []
    walk_surfaces(updated, updated_surfaces)
    now = surface_last_set(template_surface)
    changed_count = 0
    for node in updated_surfaces:
        for key in _SURFACE_KEYS:
            if key == "Desktop" and key not in node:
                # Space and display nodes carry Desktop; AllSpacesAndDisplays
                # carries the Idle surface alone and must not gain a Desktop.
                continue
            if is_converged(node.get(key), uris):
                continue
            node[key] = converged_surface(template_surface, target_url, now, node.get(key))
            changed_count += 1

    if updated == original:
        print(f"wallpaper store already synced with the folder wallpaper ({len(surfaces)} surfaces)")
        return 0

    try:
        write_atomically(store_path, plistlib.dumps(updated, fmt=plistlib.FMT_BINARY))
    except StoreNotWritable as error:
        print(
            f"wallpaper-store: macOS refused write access to {store_path} ({error}); "
            "choose the wallpaper folder once under System Settings > Wallpaper > Screen Saver "
            "to sync the lock screen",
            file=sys.stderr,
        )
        return _EXIT_REFUSED
    print(f"synced {changed_count} lock-screen and desktop surfaces with {target_url}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        fail("usage: converge-macos-wallpaper-store.py <store-plist> <wallpaper-folder>")
    sys.exit(converge(Path(sys.argv[1]), sys.argv[2]))
