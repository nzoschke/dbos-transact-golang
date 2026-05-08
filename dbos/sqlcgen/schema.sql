-- Schema input for sqlc. Mirrors the runtime migrations after they have all
-- been applied. Tables are unqualified; the runtime sets search_path on pool
-- connections so queries resolve into the configured schema.

CREATE TABLE workflow_status (
    workflow_uuid TEXT PRIMARY KEY,
    status TEXT,
    name TEXT,
    authenticated_user TEXT,
    assumed_role TEXT,
    authenticated_roles TEXT,
    request TEXT,
    output TEXT,
    error TEXT,
    executor_id TEXT,
    created_at BIGINT NOT NULL DEFAULT 0,
    updated_at BIGINT NOT NULL DEFAULT 0,
    application_version TEXT,
    application_id TEXT,
    class_name VARCHAR(255) DEFAULT NULL,
    config_name VARCHAR(255) DEFAULT NULL,
    recovery_attempts BIGINT DEFAULT 0,
    queue_name TEXT,
    workflow_timeout_ms BIGINT,
    workflow_deadline_epoch_ms BIGINT,
    inputs TEXT,
    started_at_epoch_ms BIGINT,
    deduplication_id TEXT,
    priority INTEGER NOT NULL DEFAULT 0,
    queue_partition_key TEXT,
    forked_from TEXT,
    owner_xid TEXT DEFAULT NULL,
    parent_workflow_id TEXT DEFAULT NULL,
    serialization TEXT DEFAULT NULL,
    delay_until_epoch_ms BIGINT DEFAULT NULL
);

CREATE TABLE operation_outputs (
    workflow_uuid TEXT NOT NULL,
    function_id INTEGER NOT NULL,
    function_name TEXT NOT NULL DEFAULT '',
    output TEXT,
    error TEXT,
    child_workflow_id TEXT,
    started_at_epoch_ms BIGINT,
    completed_at_epoch_ms BIGINT,
    serialization TEXT DEFAULT NULL,
    PRIMARY KEY (workflow_uuid, function_id),
    FOREIGN KEY (workflow_uuid) REFERENCES workflow_status(workflow_uuid)
        ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE notifications (
    destination_uuid TEXT NOT NULL,
    topic TEXT,
    message TEXT NOT NULL,
    created_at_epoch_ms BIGINT NOT NULL DEFAULT 0,
    message_uuid TEXT NOT NULL DEFAULT '' PRIMARY KEY,
    serialization TEXT DEFAULT NULL,
    consumed BOOLEAN NOT NULL DEFAULT FALSE,
    FOREIGN KEY (destination_uuid) REFERENCES workflow_status(workflow_uuid)
        ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE workflow_events (
    workflow_uuid TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    serialization TEXT DEFAULT NULL,
    PRIMARY KEY (workflow_uuid, key),
    FOREIGN KEY (workflow_uuid) REFERENCES workflow_status(workflow_uuid)
        ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE workflow_events_history (
    workflow_uuid TEXT NOT NULL,
    function_id INTEGER NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    serialization TEXT DEFAULT NULL,
    PRIMARY KEY (workflow_uuid, function_id, key),
    FOREIGN KEY (workflow_uuid) REFERENCES workflow_status(workflow_uuid)
        ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE streams (
    workflow_uuid TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT NOT NULL,
    "offset" INTEGER NOT NULL,
    function_id INTEGER NOT NULL DEFAULT 0,
    serialization TEXT DEFAULT NULL,
    PRIMARY KEY (workflow_uuid, key, "offset"),
    FOREIGN KEY (workflow_uuid) REFERENCES workflow_status(workflow_uuid)
        ON UPDATE CASCADE ON DELETE CASCADE
);

CREATE TABLE event_dispatch_kv (
    service_name TEXT NOT NULL,
    workflow_fn_name TEXT NOT NULL,
    key TEXT NOT NULL,
    value TEXT,
    update_seq NUMERIC(38,0),
    update_time NUMERIC(38,15),
    PRIMARY KEY (service_name, workflow_fn_name, key)
);

CREATE TABLE workflow_schedules (
    schedule_id TEXT PRIMARY KEY,
    schedule_name TEXT NOT NULL UNIQUE,
    workflow_name TEXT NOT NULL,
    workflow_class_name TEXT,
    schedule TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'ACTIVE',
    context TEXT NOT NULL,
    last_fired_at TEXT DEFAULT NULL,
    automatic_backfill BOOLEAN NOT NULL DEFAULT FALSE,
    cron_timezone TEXT DEFAULT NULL,
    queue_name TEXT DEFAULT NULL
);

CREATE TABLE application_versions (
    version_id TEXT NOT NULL PRIMARY KEY,
    version_name TEXT NOT NULL UNIQUE,
    version_timestamp BIGINT NOT NULL DEFAULT 0,
    created_at BIGINT NOT NULL DEFAULT 0
);
