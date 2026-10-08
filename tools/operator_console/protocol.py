from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timezone
from typing import Any, Dict

SCHEMA_VERSION = 1
EVENT_TYPES = {
    'ServiceStarted', 'SessionReady', 'WhisperReceived', 'ParserDecision',
    'RequestQueued', 'SummonStarted', 'SummonCompleted', 'SummonFailed',
    'PaymentExpected', 'PaymentReceived', 'PaymentMissing', 'TradeUncertain',
    'Reconnect', 'ServiceStopped',
}
COMMAND_TYPES = {'Pause', 'Resume', 'ManualWhisper'}
SEVERITIES = {'debug', 'info', 'warning', 'error', 'critical'}
_MAX_TEXT = 512
_SECRET_KEY = re.compile(r'(password|passwd|secret|token|authorization|dpapi|credential|api[_-]?key)', re.I)

class ContractError(ValueError):
    pass

def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')

def _s(value: Any, max_len: int = 256) -> str:
    if value is None:
        return ''
    value = str(value)
    if len(value) > max_len:
        raise ContractError(f'string exceeds {max_len} characters')
    return value

def _sanitize(value: Any, key: str = '') -> Any:
    if _SECRET_KEY.search(key):
        return '[REDACTED]'
    if isinstance(value, dict):
        return {str(k)[:128]: _sanitize(v, str(k)) for k, v in list(value.items())[:128]}
    if isinstance(value, list):
        return [_sanitize(v, key) for v in value[:128]]
    if isinstance(value, str):
        return value[:4096]
    if isinstance(value, (int, float, bool)) or value is None:
        return value
    return str(value)[:4096]

def sanitize_event(event: Dict[str, Any]) -> Dict[str, Any]:
    clean = dict(event)
    clean['metadata'] = _sanitize(clean.get('metadata') or {})
    return clean

def validate_event(event: Dict[str, Any]) -> Dict[str, Any]:
    if not isinstance(event, dict):
        raise ContractError('event must be an object')
    if int(event.get('schema_version', -1)) != SCHEMA_VERSION:
        raise ContractError('unsupported schema_version')
    event_type = _s(event.get('type'), 64)
    if event_type not in EVENT_TYPES:
        raise ContractError(f'unsupported event type: {event_type}')
    event_id = _s(event.get('event_id'), 128)
    if not event_id:
        raise ContractError('event_id required')
    ts_utc = _s(event.get('ts_utc'), 64)
    try:
        datetime.fromisoformat(ts_utc.replace('Z', '+00:00'))
    except Exception as exc:
        raise ContractError('invalid ts_utc') from exc
    severity = _s(event.get('severity') or 'info', 16).lower()
    if severity not in SEVERITIES:
        raise ContractError('invalid severity')
    amount = event.get('amount_copper')
    if amount is None or amount == '':
        amount = 0
    try:
        amount = int(amount)
    except Exception as exc:
        raise ContractError('amount_copper must be integer') from exc
    if amount < 0:
        raise ContractError('amount_copper must be >= 0')
    metadata = event.get('metadata') or {}
    if not isinstance(metadata, dict):
        raise ContractError('metadata must be object')
    return {
        'schema_version': SCHEMA_VERSION,
        'event_id': event_id,
        'ts_utc': ts_utc,
        'type': event_type,
        'session_id': _s(event.get('session_id'), 128),
        'request_id': _s(event.get('request_id'), 128),
        'customer': _s(event.get('customer'), 128),
        'destination': _s(event.get('destination'), 128),
        'state': _s(event.get('state'), 128),
        'amount_copper': amount,
        'correlation_id': _s(event.get('correlation_id'), 128),
        'severity': severity,
        'metadata': _sanitize(metadata),
    }

def make_command(command_type: str, *, session_id: str = '', customer: str = '', text: str = '') -> Dict[str, Any]:
    command_type = _s(command_type, 32)
    if command_type not in COMMAND_TYPES:
        raise ContractError('unsupported command')
    session_id = _s(session_id, 128)
    customer = _s(customer, 128)
    text = _s(text, _MAX_TEXT)
    if command_type == 'ManualWhisper':
        if not session_id or not customer:
            raise ContractError('ManualWhisper requires explicit session_id and customer')
        if not text.strip():
            raise ContractError('ManualWhisper text required')
        if '\n' in text or '\r' in text:
            raise ContractError('ManualWhisper must be single-line')
    elif text:
        raise ContractError('Pause/Resume do not accept text')
    return {
        'kind': 'command',
        'schema_version': SCHEMA_VERSION,
        'command_id': str(uuid.uuid4()),
        'ts_utc': utc_now(),
        'type': command_type,
        'session_id': session_id,
        'customer': customer,
        'text': text,
    }

def encode_line(obj: Dict[str, Any]) -> bytes:
    return (json.dumps(obj, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8')

def make_event(event_type: str, *, event_id: str | None = None, **kwargs: Any) -> Dict[str, Any]:
    base = {
        'schema_version': SCHEMA_VERSION,
        'event_id': event_id or str(uuid.uuid4()),
        'ts_utc': kwargs.pop('ts_utc', utc_now()),
        'type': event_type,
        'session_id': kwargs.pop('session_id', ''),
        'request_id': kwargs.pop('request_id', ''),
        'customer': kwargs.pop('customer', ''),
        'destination': kwargs.pop('destination', ''),
        'state': kwargs.pop('state', ''),
        'amount_copper': kwargs.pop('amount_copper', 0),
        'correlation_id': kwargs.pop('correlation_id', ''),
        'severity': kwargs.pop('severity', 'info'),
        'metadata': kwargs.pop('metadata', {}),
    }
    if kwargs:
        raise ContractError(f'unexpected fields: {sorted(kwargs)}')
    return validate_event(base)
