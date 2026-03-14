---
sidebar_position: 4
---

# Alerting

AGMind supports push notifications via Telegram and webhooks.

## Configuration

Set alert mode during installation or in `.env`:

```bash
# Telegram
ALERT_MODE=telegram
ALERT_TELEGRAM_TOKEN=your-bot-token
ALERT_TELEGRAM_CHAT_ID=your-chat-id

# Webhook (Slack, Discord, etc.)
ALERT_MODE=webhook
ALERT_WEBHOOK_URL=https://hooks.slack.com/services/...
```

## Alert Rules

Pre-configured Prometheus alert rules:

### Container Alerts
| Alert | Condition | Severity |
|-------|-----------|----------|
| ContainerDown | Service down > 1 min | critical |
| ContainerRestarting | > 3 restarts in 15 min | warning |
| ContainerHighCPU | CPU > 80% for 5 min | warning |
| ContainerHighMemory | Memory > 85% for 5 min | warning |

### Host Alerts
| Alert | Condition | Severity |
|-------|-----------|----------|
| HighCPUUsage | CPU > 90% for 10 min | warning |
| HighMemoryUsage | Memory > 90% for 5 min | critical |
| DiskSpaceLow | Disk > 85% for 5 min | critical |

### Service Alerts
| Alert | Condition | Severity |
|-------|-----------|----------|
| PostgresDown | DB unreachable > 1 min | critical |
| RedisDown | Redis unreachable > 1 min | critical |

## Testing Alerts

```bash
# Send test alert via health script
sudo /opt/agmind/scripts/health.sh --send-test

# Check Alertmanager status
curl -s http://localhost:9093/api/v2/alerts | python3 -m json.tool
```

## Alertmanager

Alertmanager handles alert routing, grouping, and silencing.

Access at: `http://localhost:9093/` (internal network only)

Configuration: `/opt/agmind/monitoring/alertmanager.yml`

### Silencing Alerts

Use Alertmanager UI or API to silence alerts during maintenance:

```bash
# Silence all alerts for 2 hours
curl -X POST http://localhost:9093/api/v2/silences \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [{"name": "severity", "value": ".*", "isRegex": true}],
    "startsAt": "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'",
    "endsAt": "'$(date -u -d "+2 hours" +%Y-%m-%dT%H:%M:%SZ)'",
    "createdBy": "admin",
    "comment": "Planned maintenance"
  }'
```
