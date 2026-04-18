# Alert channels — how to route AGmind alerts (Phase 37+50)

**By default AGmind doesn't send alerts anywhere.** Alerts fire into Prometheus
and are visible in Grafana (`AGMind Alerts` dashboard) and Alertmanager UI, but
the `default` receiver is empty. Vendor (AGmind team) never sees customer
incidents through this channel.

To route alerts somewhere actionable, pick ONE of the channels below. All
configured via the install wizard step «Уведомления о сбоях» or by editing
`/opt/agmind/docker/.env` + restart of `alertmanager` container.

---

## 1. Telegram (self-managed bot)

**Use case:** small team, 1-5 on-call engineers, everyone has Telegram.

**Setup:**
1. Open @BotFather in Telegram → `/newbot` → get bot token like `123456789:AA...`
2. Message your bot (or add to a group and message there)
3. `curl "https://api.telegram.org/bot<TOKEN>/getUpdates"` → find `chat.id`
4. In wizard (`sudo bash install.sh`) choose `3 Telegram-бот`, paste token + chat_id

Or edit `.env` directly:
```bash
ALERT_MODE=telegram
ALERT_TELEGRAM_TOKEN=123456789:AA...
ALERT_TELEGRAM_CHAT_ID=-1001234567890
sudo docker compose restart alertmanager
```

**Token rotation:** BotFather → `/revoke` → `/newbot` → update `.env` → restart
alertmanager.

**Important:** this is CUSTOMER's bot. Vendor never sees these messages.
Do not paste the vendor's test bot into production — replace with customer-owned.

---

## 2. Email (SMTP relay)

**Use case:** enterprise with corporate mail infrastructure, everyone reads email.

**Requires:** SMTP relay host:port, sender address, recipient address, optional
AUTH credentials.

**Setup via wizard:** choose `4 Email через SMTP`, supply fields.

Manual:
```bash
ALERT_MODE=email
ALERT_EMAIL_TO=ops@client.ru
ALERT_EMAIL_FROM=alerts@agmind.local
ALERT_EMAIL_SMARTHOST=smtp.client.ru:587
ALERT_EMAIL_AUTH_USER=alerts@client.ru
ALERT_EMAIL_AUTH_PASS=strong-password
sudo docker compose restart alertmanager
```

**SMTP relay examples:**
- Yandex:   `smtp.yandex.ru:587` + login/password
- Gmail:    `smtp.gmail.com:587` + App Password
- Mailru:   `smtp.mail.ru:465`
- Internal Postfix: `smtp.company.local:25` (often no auth)

**TLS:** template forces `require_tls: true` — secure connection required.
If your relay uses plain SMTP on port 25, edit `alertmanager.yml` after
install and set `require_tls: false`.

---

## 3. Webhook (Slack / Teams / Mattermost / Zabbix / custom)

**Use case:** team already on a chat platform, or integration into existing
monitoring (Zabbix, PagerDuty, OpsGenie, incident.io).

**Setup:** get webhook URL from target system, wizard step `2 Webhook URL`.

Manual:
```bash
ALERT_MODE=webhook
ALERT_WEBHOOK_URL=https://hooks.slack.com/services/T00/B00/xxxx
sudo docker compose restart alertmanager
```

**Payload format:** Alertmanager sends its native JSON (version=4). Slack and
Teams accept it directly via incoming-webhook. For others (Zabbix, custom
backends) you may need a thin transformer — see [Alertmanager webhook docs](https://prometheus.io/docs/alerting/latest/configuration/#webhook_config).

---

## 4. Off (default)

```bash
ALERT_MODE=none
sudo docker compose restart alertmanager
```

Alerts still evaluate in Prometheus and remain visible in:
- `http://agmind-dify.local:3001` → Grafana → `AGMind Alerts` dashboard
- `http://agmind-dify.local:9093` → Alertmanager UI (if exposed)

Suitable when operator checks the dashboards on schedule and doesn't need push.

---

## Multi-channel

Nothing stops you from enabling more than one. `alertmanager.yml` supports
multiple `telegram_configs`, `email_configs`, and `webhook_configs` under the
same receiver. Edit `alertmanager.yml` directly after install:

```yaml
receivers:
  - name: default
    telegram_configs:
      - bot_token: '...'
        chat_id: -100...
        send_resolved: true
    email_configs:
      - to: ops@client.ru
        from: alerts@agmind.local
        smarthost: smtp.client.ru:587
        send_resolved: true
```

`ALERT_MODE` in `.env` only determines which channel the wizard/sed populates
— you can append additional configs by hand.

---

## Routing by severity (advanced)

Default routing:
- **critical** → `receiver: default`, `repeat_interval: 15m`
- **warning**  → `receiver: default`, `repeat_interval: 4h`

For "critical to phone, warning to email", edit `alertmanager.yml`:

```yaml
receivers:
  - name: oncall-phone
    webhook_configs: [{ url: 'https://pagerduty.com/...' }]
  - name: email-only
    email_configs: [...]

route:
  receiver: email-only
  routes:
    - match: { severity: critical }
      receiver: oncall-phone
```

---

## Rate limiting

12 rules in `alert_rules.yml`, default `group_interval: 10s` +
`repeat_interval: 1h` (critical: 15m, warning: 4h). Under sustained
degradation the same alert notifies at most once per window — safe for
Telegram (API limits), email (SMTP quotas), webhook (rate-limit on Slack).

If you want different cadence, edit `route.repeat_interval` in
`alertmanager.yml`.

---

## Testing a channel

Fire a synthetic alert to confirm the pipe is live:

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
docker exec agmind-alertmanager sh -c "cat > /tmp/test.json <<JSON
[{
  \"labels\":{\"alertname\":\"TestChannel\",\"severity\":\"warning\",\"name\":\"agmind-test\"},
  \"annotations\":{\"summary\":\"Test\",\"description\":\"Channel pipe check\"},
  \"startsAt\":\"$NOW\",
  \"endsAt\":\"2099-01-01T00:00:00Z\"
}]
JSON
wget -qO- --post-file=/tmp/test.json --header='Content-Type: application/json' \
  http://localhost:9093/api/v2/alerts"
# Wait ~15 seconds (group_wait: 10s) and check your channel
```

If nothing arrives within 30s, check:
1. `sudo agmind logs alertmanager --tail 50` — look for `notify failed` or `level=ERROR`
2. Channel credentials / URL correct in `.env`
3. Firewall from stack to channel (especially email — SMTP port often blocked)
4. `sudo docker exec agmind-alertmanager amtool check-config /etc/alertmanager/alertmanager.yml`
