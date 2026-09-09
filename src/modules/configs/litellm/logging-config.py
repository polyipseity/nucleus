# Custom logging configuration for LiteLLM proxy.
# Suppresses Python tracebacks while keeping uvicorn access logs and
# WARNING-level messages.  Used via litellm --log_config <this-file>.
#
# WHY: litellm logs full tracebacks via verbose_proxy_logger.exception(...,
# exc_info=True).  These are verbose and not useful for production.  This
# config suppresses them while preserving uvicorn access logs (per user
# request) and WARNING-level Python loggers.

import logging
import sys


class NoTracebackFormatter(logging.Formatter):
    """Formatter that strips tracebacks from exception log records."""

    def format(self, record: logging.LogRecord) -> str:
        record.exc_info = None
        record.stack_info = None
        return super().format(record)


LOGGING = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "notraceback": {
            "()": f"{__name__}.NoTracebackFormatter",
            "format": "%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        },
    },
    "handlers": {
        "stderr": {
            "class": "logging.StreamHandler",
            "stream": "ext://sys.stderr",
            "formatter": "notraceback",
        },
    },
    "root": {
        "handlers": ["stderr"],
        "level": "WARNING",
    },
}
