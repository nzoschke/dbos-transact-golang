-- Queries grouped by table. The runtime sets search_path on connection so
-- table names are unqualified.
--
-- Methods that build SQL dynamically or rely on Postgres-specific runtime
-- features stay hand-written in system_database.go for now and will be
-- ported per-dialect when those features get SQLite analogues:
--
--   - listWorkflows / listSchedules: dynamic WHERE/ORDER BY assembly.
--   - dequeueWorkflows: FOR UPDATE SKIP LOCKED + per-call rate-limit/concurrency
--     branches; needs a different locking strategy in SQLite.
--   - forkWorkflow / exportWorkflow / importWorkflow: multi-statement
--     orchestration with branch-conditional SQL.
--   - deleteWorkflows / resumeWorkflows / getWorkflowChildren / cancelAllBefore /
--     awaitWorkflowResult / backfillSchedule / triggerSchedule: chain of
--     queries with control flow that doesn't fit one sqlc :query.
--
-- Everything else lives below and is dialect-portable as written.

-- ===== operation_outputs =====

-- name: CheckChildWorkflow :one
SELECT child_workflow_id
FROM operation_outputs
WHERE workflow_uuid = $1 AND function_id = $2;

-- name: RecordChildWorkflow :exec
INSERT INTO operation_outputs (workflow_uuid, function_id, function_name, child_workflow_id)
VALUES ($1, $2, $3, $4);

-- name: DoesPatchExists :one
SELECT function_name
FROM operation_outputs
WHERE workflow_uuid = $1 AND function_id = $2;

-- name: InsertPatchMarker :exec
INSERT INTO operation_outputs (workflow_uuid, function_id, function_name)
VALUES ($1, $2, $3);

-- name: RecordOperationResult :exec
INSERT INTO operation_outputs (
    workflow_uuid, function_id, output, error, function_name,
    started_at_epoch_ms, completed_at_epoch_ms, serialization, child_workflow_id
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9);

-- ===== workflow_status =====

-- name: GetWorkflowStatus :one
SELECT status
FROM workflow_status
WHERE workflow_uuid = $1;

-- name: GetWorkflowSteps :many
SELECT function_id, function_name, output, error, child_workflow_id,
       started_at_epoch_ms, completed_at_epoch_ms, serialization
FROM operation_outputs
WHERE workflow_uuid = $1
ORDER BY function_id ASC;

-- name: CheckOperationOutput :one
SELECT output, error, function_name, serialization
FROM operation_outputs
WHERE workflow_uuid = $1 AND function_id = $2;

-- name: MarkWorkflowDeadLetter :exec
UPDATE workflow_status
SET status = $1, deduplication_id = NULL, started_at_epoch_ms = NULL, queue_name = NULL
WHERE workflow_uuid = $2 AND status = $3;

-- name: UpdateWorkflowOutcome :exec
UPDATE workflow_status
SET status = $1, output = $2, error = $3, updated_at = $4, deduplication_id = NULL
WHERE workflow_uuid = $5 AND NOT (status = $6 AND $1::TEXT IN ($7, $8));

-- name: UpdateWorkflowToCancelled :exec
UPDATE workflow_status
SET status = $1, updated_at = $2, started_at_epoch_ms = NULL,
    queue_name = NULL, deduplication_id = NULL
WHERE workflow_uuid = $3;

-- name: SetWorkflowDelay :exec
UPDATE workflow_status
SET delay_until_epoch_ms = $1, updated_at = $2
WHERE workflow_uuid = $3
  AND status = $4;

-- name: TransitionDelayedWorkflows :exec
UPDATE workflow_status
SET status = $1
WHERE status = $2
  AND delay_until_epoch_ms <= $3;

-- name: ClearQueueAssignment :execrows
UPDATE workflow_status
SET status = $1, started_at_epoch_ms = NULL
WHERE workflow_uuid = $2
  AND queue_name IS NOT NULL
  AND status = $3;

-- name: GetQueuePartitions :many
SELECT DISTINCT queue_partition_key
FROM workflow_status
WHERE queue_name = $1
  AND status = $2
  AND queue_partition_key IS NOT NULL;

-- name: GarbageCollectCutoffByOffset :one
SELECT created_at
FROM workflow_status
ORDER BY created_at DESC
LIMIT 1 OFFSET $1;

-- name: GarbageCollectWorkflowsBefore :execrows
DELETE FROM workflow_status
WHERE created_at < $1
  AND status NOT IN ($2, $3, $4);

-- name: WorkflowExists :one
SELECT 1 AS one
FROM workflow_status
WHERE workflow_uuid = $1
LIMIT 1;

-- ===== metrics =====

-- name: GetMetricWorkflowCount :many
SELECT name, COUNT(workflow_uuid) AS count
FROM workflow_status
WHERE created_at >= $1 AND created_at < $2
GROUP BY name;

-- name: GetMetricStepCount :many
SELECT function_name, COUNT(*) AS count
FROM operation_outputs
WHERE completed_at_epoch_ms >= $1 AND completed_at_epoch_ms < $2
GROUP BY function_name;

-- ===== notifications / events / streams =====

-- name: InsertNotification :exec
INSERT INTO notifications (destination_uuid, topic, message, serialization)
VALUES ($1, $2, $3, $4);

-- name: NotificationExists :one
SELECT EXISTS (
    SELECT 1 FROM notifications
    WHERE destination_uuid = $1 AND topic = $2
) AS exists;

-- name: ConsumeOldestNotification :one
WITH oldest_entry AS (
    SELECT n.message_uuid
    FROM notifications n
    WHERE n.destination_uuid = $1 AND n.topic = $2
    ORDER BY n.created_at_epoch_ms ASC
    LIMIT 1
)
DELETE FROM notifications
WHERE message_uuid = (SELECT message_uuid FROM oldest_entry)
RETURNING message, serialization;

-- name: UpsertWorkflowEvent :exec
INSERT INTO workflow_events (workflow_uuid, key, value, serialization)
VALUES ($1, $2, $3, $4)
ON CONFLICT (workflow_uuid, key)
DO UPDATE SET value = EXCLUDED.value, serialization = EXCLUDED.serialization;

-- name: UpsertWorkflowEventHistory :exec
INSERT INTO workflow_events_history (workflow_uuid, function_id, key, value, serialization)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (workflow_uuid, function_id, key)
DO UPDATE SET value = EXCLUDED.value, serialization = EXCLUDED.serialization;

-- name: GetWorkflowEvent :one
SELECT value, serialization
FROM workflow_events
WHERE workflow_uuid = $1 AND key = $2;

-- name: StreamIsClosed :one
SELECT 1 AS one
FROM streams
WHERE workflow_uuid = $1 AND key = $2 AND value = $3
LIMIT 1;

-- name: AppendStreamEntry :exec
INSERT INTO streams (workflow_uuid, key, value, "offset", function_id, serialization)
SELECT $1, $2, $3, COALESCE(
    (SELECT MAX("offset") FROM streams WHERE workflow_uuid = $1 AND key = $2), -1
) + 1, $4, $5;

-- name: ReadStream :many
SELECT value, "offset", serialization
FROM streams
WHERE workflow_uuid = $1 AND key = $2 AND "offset" >= $3
ORDER BY "offset" ASC;

-- ===== workflow_schedules =====

-- name: CreateSchedule :exec
INSERT INTO workflow_schedules (
    schedule_id, schedule_name, workflow_name, workflow_class_name,
    schedule, context, status, automatic_backfill, cron_timezone, queue_name
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10);

-- name: UpdateSchedule :exec
UPDATE workflow_schedules
SET status = $1, last_fired_at = $2
WHERE schedule_name = $3;

-- name: UpdateScheduleLastFiredAt :exec
UPDATE workflow_schedules
SET last_fired_at = $1
WHERE schedule_name = $2;

-- name: DeleteSchedule :exec
DELETE FROM workflow_schedules WHERE schedule_name = $1;
