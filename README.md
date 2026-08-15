# lnurl-mint updater

An opt-in systemd watchdog for the installed `/opt/lnurl-mint` deployment.
It checks the upstream repository every 24 hours, performs an advisory GLM 5.2
risk review through the exe.dev LLM endpoint, and can optionally run a tested,
backed-up deployment. The model is advisory-only and has no shell access.

Install:

```bash
sudo install -m 0755 scripts/lnurl-mint-updater.sh /usr/local/sbin/lnurl-mint-updater
sudo install -m 0600 systemd/lnurl-mint-updater.env.example /etc/lnurl-mint-updater.env
sudo install -m 0644 systemd/lnurl-mint-updater.service systemd/lnurl-mint-updater.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now lnurl-mint-updater.timer
```

`AUTO_DEPLOY=false` is the safe default. Deployment backs up and integrity-checks
the mint database, runs tests, swaps the application, restarts it, checks the
health endpoint, and retains a rollback directory.
