"""Runs one of the decomp's extractor scripts, letting it read a US *asset hack* ROM.

The extractors (DevOldSchool's conkers-bfd-decomp) only accept the exact US ROM: each one
checks the whole ROM's SHA-1 before it starts. A ROM hack that only changes some assets
(the uncensored ROM, a translation) has the same layout, so they can read it, but that
check stops them first.

    python decomp_shim.py <script.py> [args...]

With CM_ROM_ALIAS=<hack sha1>:<us sha1> in the environment, a SHA-1 of exactly the hack's
whole image reports the US value, so the identity check passes. Nothing else changes:
every per-asset check still runs against the real bytes, so an asset the hack really
changed and the extractor can't prove still fails loudly (cmtools then skips that step).
"""
import hashlib
import os
import runpy
import sys

ROM_SIZE = 64 * 1024 * 1024


class _AliasedHash:
    """A hash object that answers with the US digest if it hashed exactly the hack ROM."""

    def __init__(self, real, size, hack, us):
        self._real, self._size, self._hack, self._us = real, size, hack, us

    def update(self, data):
        self._size += len(data)
        self._real.update(data)

    def hexdigest(self):
        value = self._real.hexdigest()
        return self._us if self._size == ROM_SIZE and value == self._hack else value

    def digest(self):
        return bytes.fromhex(self.hexdigest())

    def copy(self):
        return _AliasedHash(self._real.copy(), self._size, self._hack, self._us)

    def __getattr__(self, name):
        return getattr(self._real, name)


def _install(hack: str, us: str) -> None:
    real_sha1, real_new = hashlib.sha1, hashlib.new

    def sha1(data=b"", **kwargs):
        return _AliasedHash(real_sha1(data, **kwargs), len(data), hack, us)

    def new(name, data=b"", **kwargs):
        if name.lower() == "sha1":
            return sha1(data, **kwargs)
        return real_new(name, data, **kwargs)

    hashlib.sha1, hashlib.new = sha1, new


def main() -> None:
    alias = os.environ.get("CM_ROM_ALIAS", "")
    if ":" in alias:
        _install(*alias.split(":", 1))
    script = os.path.abspath(sys.argv[1])
    sys.argv = [script] + sys.argv[2:]
    sys.path[0] = os.path.dirname(script)
    runpy.run_path(script, run_name="__main__")


if __name__ == "__main__":
    main()
