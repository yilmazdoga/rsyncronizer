"""Single source of truth for the app version: the repo's VERSION file,
bundled into the build by the .spec and read at runtime."""

from . import engine


def app_version() -> str:
    return engine.bundled_version() or "unknown"
