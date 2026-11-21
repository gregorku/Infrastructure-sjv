"""Shared ingest contract. Transport adapters and database writes are separate."""

from sjv_ingest.contract import (
    IDENTIFIER_MISSING,
    IDENTIFIER_PROVEN,
    IDENTIFIER_UNPROVEN,
    MESSAGE_KINDS,
    TRANSPORTS,
    Envelope,
    Fragment,
    Frame,
    Item,
    SourceTime,
    identifier_status,
)
from sjv_ingest.validate import ValidationIssue, ValidationResult, validate

__all__ = (
    "IDENTIFIER_MISSING",
    "IDENTIFIER_PROVEN",
    "IDENTIFIER_UNPROVEN",
    "MESSAGE_KINDS",
    "TRANSPORTS",
    "Envelope",
    "Fragment",
    "Frame",
    "Item",
    "SourceTime",
    "ValidationIssue",
    "ValidationResult",
    "identifier_status",
    "validate",
)
