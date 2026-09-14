import logging


class NoTracebackFormatter(logging.Formatter):
    """Formatter that strips tracebacks from exception log records."""

    def format(self, record: logging.LogRecord) -> str:
        record.exc_info = None
        record.stack_info = None
        return super().format(record)
