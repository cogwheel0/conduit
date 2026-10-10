"""Conduit push notifications for Hermes Agent.

A ``conduit`` platform plugin. It encrypts a short notification to every
subscribed Conduit device (Web Push, RFC 8291) when a reply started from
Conduit finishes, when a cron job delivers with ``deliver: conduit``, and when
Conduit asks for a test push. Only ciphertext ever leaves this server.

This module stays import-light on purpose: the dashboard route file loads the
package to reach ``ops`` without pulling in the gateway, so the gateway-facing
modules are imported inside ``register``.
"""

PLUGIN_NAME = "conduit"
VERSION = "1.0.0"
PROTO = 1


def register(ctx) -> None:
    """Plugin entry point, called once per process by the Hermes plugin loader."""
    from . import adapter, hooks

    adapter.register(ctx)
    hooks.register(ctx)


__all__ = ["PLUGIN_NAME", "PROTO", "VERSION", "register"]
