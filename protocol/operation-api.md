# Operation API

The artifact uses schedule-driven JSON commands rather than a live HTTP API.

Each request event carries:

- `tenant`
- `operation_type`
- `parent_resource`
- `caller_key`
- `epoch`
- `amount`
- `currency`
- stable payload options

The safe Go reference implements reserve-before-provider behavior. The safe Java reference implements query-before-retry behavior.
