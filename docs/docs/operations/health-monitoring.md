---
sidebar_position: 1
---

# Health Monitoring

AGMind includes a comprehensive health monitoring system with 26+ automated checks.

## Health Script

```bash
# Run all health checks
sudo /opt/agmind/scripts/health.sh

# Quick check (exit code only)
sudo /opt/agmind/scripts/health.sh --quiet

# Send test alert
sudo /opt/agmind/scripts/health.sh --send-test
```

### Health Check Categories

| Category | Checks | Description |
|----------|--------|-------------|
| Container status | All services | Running, healthy, restart count |
| Database | PostgreSQL | Connectivity, replication lag, connection count |
| Redis | Cache | Connectivity, memory usage, command availability |
| Vector store | Weaviate/Qdrant | API health, collection status |
| Ollama | LLM engine | API status, loaded models |
| GPU | Hardware | Utilization, temperature, memory |
| Disk | Storage | Docker volumes, backup directory |
| Network | Connectivity | Inter-service communication |
| Backup | Data protection | Last backup age, size |

## Prometheus + Grafana

When monitoring is enabled (`MONITORING_MODE=local`), AGMind deploys:

- **Prometheus** — metrics collection (15s scrape interval)
- **Grafana** — dashboards and visualization
- **Alertmanager** — alert routing and notifications
- **cAdvisor** — container metrics
- **Loki** — log aggregation (optional)
- **Promtail** — log shipping

### Dashboards

4 pre-provisioned Grafana dashboards:

1. **AGMind Overview** — service status, CPU, memory, network, disk I/O
2. **AGMind Alerts** — active alerts, alert history, restart counts
3. **AGMind Logs** — error rates by service (requires Loki)
4. **Docker Containers** — per-container resource usage

Access Grafana at `http://your-server:3001/` (credentials in `.env`).

## Cron-based Health Checks

Health checks run automatically via cron:

```bash
# Default: every 5 minutes
*/5 * * * * /opt/agmind/scripts/health.sh --quiet --auto-alert >> /var/log/agmind-health.log 2>&1
```

Failed checks trigger alerts via the configured alert channel (Telegram or webhook).
