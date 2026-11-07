"""Shared Web Push code for the Conduit server plugins.

This package is the single source. `server-plugins/openwebui/build.py` inlines
it into the Open WebUI function, and `server-plugins/hermes/sync.py` copies it
into the Hermes plugin; CI checks both copies are up to date.
"""

from . import payload, webpush

__all__ = ["payload", "webpush"]
