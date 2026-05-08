-- name: CheckChildWorkflow :one
SELECT child_workflow_id
FROM operation_outputs
WHERE workflow_uuid = $1 AND function_id = $2;

-- name: GetWorkflowStatus :one
SELECT status
FROM workflow_status
WHERE workflow_uuid = $1;
