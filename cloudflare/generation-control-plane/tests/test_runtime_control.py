from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

MODULE = Path(__file__).parents[1] / 'local/runtime_control.py'


def load_module():
    spec = importlib.util.spec_from_file_location('runtime_control', MODULE)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Cursor:
    def __init__(self, connection):
        self.connection = connection
        self.result = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def execute(self, query, params=None):
        normalized = ' '.join(query.split())
        self.connection.queries.append((normalized, params))
        if normalized.startswith('select cloudflare_generation_enabled'):
            self.result = (self.connection.enabled, self.connection.environment)
        elif "status in ('queued','running')" in normalized:
            self.result = (self.connection.active_jobs,)
        elif "status in ('pending','dispatching','enqueued')" in normalized:
            self.result = (self.connection.unsettled,)
        elif normalized.startswith('update public.recorrido_cloudflare_generation_runtime'):
            assert params is not None
            self.connection.enabled, self.connection.environment = params
            self.result = None
        else:
            raise AssertionError(normalized)

    def fetchone(self):
        return self.result


class Connection:
    def __init__(self, active_jobs=0, unsettled=0):
        self.enabled = False
        self.environment = 'off'
        self.active_jobs = active_jobs
        self.unsettled = unsettled
        self.queries = []
        self.commits = 0

    def cursor(self):
        return Cursor(self)

    def commit(self):
        self.commits += 1


def test_switch_locks_runtime_and_updates_only_when_drained() -> None:
    module = load_module()
    connection = Connection()
    result = module.switch(connection, 'staging')
    assert result['runtime_enabled'] is True
    assert result['active_environment'] == 'staging'
    assert connection.commits == 1
    assert any(query.endswith('for update') for query, _ in connection.queries)


@pytest.mark.parametrize(('active_jobs', 'unsettled'), [(1, 0), (0, 1)])
def test_switch_refuses_active_or_unsettled_work(active_jobs: int, unsettled: int) -> None:
    module = load_module()
    connection = Connection(active_jobs, unsettled)
    with pytest.raises(RuntimeError, match='runtime_switch_blocked'):
        module.switch(connection, 'staging')
    assert connection.environment == 'off'
    assert connection.commits == 0


@pytest.mark.parametrize(('active_jobs', 'unsettled'), [(1, 0), (0, 1)])
def test_emergency_off_is_allowed_with_active_or_unsettled_work(active_jobs: int, unsettled: int) -> None:
    module = load_module()
    connection = Connection(active_jobs, unsettled)
    connection.enabled = True
    connection.environment = 'staging'
    result = module.switch(connection, 'off')
    assert result['runtime_enabled'] is False
    assert result['active_environment'] == 'off'
    assert connection.commits == 1
