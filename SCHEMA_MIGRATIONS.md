# Schema Migrations

This app must never delete the SwiftData store automatically.

## Current Baseline

- `AppSchemaV1` in [ideas/Persistence.swift](./ideas/Persistence.swift) is the frozen legacy schema.
- `AppSchemaV2` in [ideas/Persistence.swift](./ideas/Persistence.swift) is the current live schema.
- The live app models are exposed through the typealiases and should point at the newest schema only:
  - `Idea`
  - `UserProfile`
  - `Folder`
- The AI provider key is no longer stored in SwiftData. It lives in the keychain, with a one-time `V1 -> V2` migration.

## When To Migrate

Create a new schema version any time you change persisted `@Model` storage:

- add/remove a stored property
- rename a stored property
- change a stored property type
- change relationships
- add/remove a persisted model

Do not create a schema version for:

- UI changes
- methods
- computed properties
- non-persisted helpers

## Future Change Checklist

When you make the next persisted schema change:

1. Add `AppSchemaV3` in `ideas/Persistence.swift`.
2. Copy the latest model shapes into `AppSchemaV3`.
3. Update the typealiases to point to `AppSchemaV3`.
4. Update `AppMigrationPlan.schemas` to `[AppSchemaV1.self, AppSchemaV2.self, AppSchemaV3.self]`.
5. Add a migration stage:
   - simple additive change: `MigrationStage.lightweight(fromVersion: AppSchemaV2.self, toVersion: AppSchemaV3.self)`
   - rename/type/relationship transform: use `MigrationStage.custom(...)`
6. Build and test against an existing local database, not only a fresh install.

## Rules

- Never re-edit old schema versions after shipping them.
- The newest schema is the only one app code should target through the typealiases.
- If the store cannot be opened, show an error and keep the data on disk.
- Never restore the old delete-the-store fallback.

## Dev Resets

If you want to throw away local test data during development, do it manually.

That is allowed for your machine.

It must never happen automatically in production code.
