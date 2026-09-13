# OpenCrew workspace instructions

This directory is a multi-repository workspace, **not a monorepo**.

GitHub organization: opentribe-dev

Independent repositories live under `repos/`:
- server
- agentd
- protocol
- sdk
- app
- website
- cloud
- infra

Cross-repo tasks are expected. Never assume the root Git history includes child repositories. Run Git commands in the affected child repo and keep commits scoped per repository.

Architecture rule: Agent != Model != Runtime != Runtime Session.
Runtime Session = Agent + Conversation + Runtime + Workspace.

Keep self-hosting lightweight: one server process/container, one port, one data directory, SQLite by default, no mandatory Redis/Postgres/Kafka.