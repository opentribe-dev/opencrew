# OpenCrew workspace

Development control repo for **OpenCrew** under GitHub organization **opentribe-dev**.

The actual products are independent Git repositories inside `repos/`.

```text
OpenCrew/
  AGENTS.md
  CLAUDE.md
  repos.json
  oc.ps1
  opencrew.code-workspace
  repos/
    server/.git
    agentd/.git
    protocol/.git
    sdk/.git
    app/.git
    website/.git
    cloud/.git
    infra/.git
```

Common commands:

```powershell
.\oc.ps1 status
.\oc.ps1 pull
.\oc.ps1 push
.\oc.ps1 save "feat: message"
.\oc.ps1 doctor
```