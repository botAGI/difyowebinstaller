# Authelia SSO (Phase 47)

AGmind поставляется с подготовленной инфраструктурой под Authelia 4.38 для single-sign-on поверх всех web-UI: Dify, Grafana, Open WebUI, Portainer. **По умолчанию отключено** — включается вручную после install через procedure ниже.

## ⚠️ Требование: HTTPS

Authelia **4.38 hardened** — отказывается стартовать с `http://` в `authelia_url` / `default_redirection_url`. Это значит:

- **VPS profile (Caddy, Let's Encrypt)** — работает из коробки. Caddy на `agmind-caddy` ветке автоматически делает TLS.
- **LAN profile (nginx, HTTP)** — **не работает без TLS**. Варианты:
  1. Сгенерировать self-signed cert (`mkcert`/`step-ca`) и поднять HTTPS в nginx
  2. Использовать Caddy в LAN-режиме (internal PKI, `tls internal`)
  3. Downgrade до Authelia 4.37 — не рекомендуется (end-of-life, security fixes stop)

Инфраструктура (configs, секреты, nginx маркеры) заложена на все сценарии. Но **живой запуск Authelia на чистом HTTP-LAN деплое закроется с ошибкой** до настройки TLS.

Ниже инструкции работают только при наличии TLS (https://agmind.example.com). Для чистого LAN-HTTP — сначала подними TLS.

## Архитектурные ограничения

| Сервис | Способ интеграции | Примечания |
|---|---|---|
| **Grafana** | ✅ Trusted header (`GF_AUTH_PROXY_ENABLED=true`) | Полноценный SSO, групповая роль |
| **Open WebUI** | ✅ Trusted header (`WEBUI_AUTH_TRUSTED_EMAIL_HEADER=Remote-Email`) | Создаёт пользователя на лету |
| **Portainer** | ⚠️ Только OIDC (Authelia можно включить как OIDC provider) | Нет trusted-header режима. Оставить own auth или настроить Authelia→OIDC→Portainer |
| **Dify 1.x** | ❌ Только gate-mode | В OSS Dify нет trusted-header SSO. Authelia может защитить `/install` и общую страницу; внутри Dify — свой логин и session. Enterprise-только: OIDC native |

**Итого:** реальное покрытие SSO сейчас = Grafana + Open WebUI. Dify получает **доп. слой auth-gate** (защита от неавторизованного доступа к админ-URL), но user'ы всё ещё логинятся в Dify отдельно. Enterprise-фича (полный SSO в Dify) — отдельная платная лицензия.

## Стек

- Контейнер `agmind-authelia` под profile `authelia` (по умолчанию выключен)
- File-backend users (`templates/authelia/users_database.yml.template`) — argon2id hashes
- SQLite storage (`/config/db.sqlite3`)
- Filesystem notifier (reset/2fa ссылки пишутся в `/config/notification.txt`, заменить на SMTP в prod)

## Active LDAP/AD integration

Switch `authentication_backend.file` на `ldap:` блок в `templates/authelia/configuration.yml.template`:

```yaml
authentication_backend:
  ldap:
    implementation: activedirectory
    address: ldaps://dc.corp.local:636
    base_dn: DC=corp,DC=local
    user: CN=authelia,OU=Service,DC=corp,DC=local
    password: ${LDAP_PASSWORD}
    users_filter: "(&({username_attribute}={input})(objectCategory=person)(objectClass=user))"
    groups_filter: "(&(member={dn})(objectClass=group))"
```

Users из `users_database.yml` перестанут действовать — все логины пойдут против AD.

## Как включить (manual steps, single LAN profile)

### 1. Сгенерировать хэш пароля admin

```bash
docker run --rm authelia/authelia:4.38 \
  authelia crypto hash generate argon2 --password 'YOUR_STRONG_PASSWORD'
# копируй $argon2id$... хэш
```

### 2. Создать `users_database.yml`

```yaml
# /opt/agmind/docker/authelia/users_database.yml
users:
  admin:
    displayname: "AGmind Admin"
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."  # от шага 1
    email: admin@agmind.local
    groups:
      - admins
```

### 3. Генерация `configuration.yml`

При первом install.sh файл уже сгенерирован с секретами из `.env` (`AUTHELIA_JWT_SECRET`, `AUTHELIA_SESSION_SECRET`, `AUTHELIA_STORAGE_KEY`). Проверь `/opt/agmind/docker/authelia/configuration.yml` — все `__AUTHELIA_*__` должны быть заменены. Если не сгенерирован, запусти:

```bash
sudo envsubst < /opt/agmind/templates/authelia/configuration.yml.template \
  > /opt/agmind/docker/authelia/configuration.yml
```

### 4. Активировать маркеры `#__AUTHELIA__` в nginx.conf

```bash
sudo sed -i 's|#__AUTHELIA__||g' /opt/agmind/docker/nginx/nginx.conf
sudo docker exec agmind-nginx nginx -t  # должен быть OK
```

### 5. Добавить Authelia в COMPOSE_PROFILES

```bash
sudo sed -i 's|^COMPOSE_PROFILES=\(.*\)$|COMPOSE_PROFILES=\1,authelia|' /opt/agmind/docker/.env
cd /opt/agmind/docker && sudo docker compose up -d authelia
```

### 6. Grafana trusted-header

```bash
sudo bash -c "cat >> /opt/agmind/docker/.env" <<EOF
GF_AUTH_PROXY_ENABLED=true
GF_AUTH_PROXY_HEADER_NAME=Remote-User
GF_AUTH_PROXY_HEADER_PROPERTY=username
GF_AUTH_PROXY_AUTO_SIGN_UP=true
GF_AUTH_PROXY_HEADERS=Email:Remote-Email Name:Remote-Name Groups:Remote-Groups
GF_AUTH_PROXY_WHITELIST=172.16.0.0/12
EOF
cd /opt/agmind/docker && sudo docker compose up -d grafana
```

### 7. Open WebUI trusted-header

```bash
sudo bash -c "cat >> /opt/agmind/docker/.env" <<EOF
WEBUI_AUTH_TRUSTED_EMAIL_HEADER=Remote-Email
WEBUI_AUTH_TRUSTED_NAME_HEADER=Remote-Name
EOF
cd /opt/agmind/docker && sudo docker compose up -d openwebui
```

### 8. Reload nginx + test

```bash
sudo docker exec agmind-nginx nginx -s reload
curl -I http://agmind-dify.local   # → 302 Redirect to /authelia login page
```

## Caddy (VPS profile, agmind-caddy branch)

На VPS `agmind-caddy` — Caddyfile с `forward_auth` вместо `auth_request`. Endpoint другой:

```caddyfile
example.com {
    forward_auth authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
    }
    reverse_proxy grafana:3000
}
```

Детали — в agmind-caddy ветке, `templates/Caddyfile.template`.

## Troubleshooting

| Симптом | Причина | Фикс |
|---|---|---|
| 502 при открытии agmind-dify.local | Authelia не стартовала (healthcheck fail) | `sudo agmind logs authelia` → смотри ошибку config |
| Login работает, но 401 на всех pages | Cookie domain не совпадает с hostname | `session.cookies[0].domain` в configuration.yml = хост без портов |
| Grafana говорит "invalid proxy auth" | Whitelist не включает IP nginx в compose network | Проверь `docker network inspect docker_agmind-backend`, добавь подсеть в `GF_AUTH_PROXY_WHITELIST` |
| Reset password — никуда не пришло | Notifier = filesystem | Читай `/opt/agmind/docker/authelia/notification.txt`; для prod замени на SMTP |

## Откат

```bash
# 1. Убрать authelia из profiles
sudo sed -i 's|,authelia||' /opt/agmind/docker/.env
# 2. Закомментить обратно nginx.conf — проще всего восстановить из backup:
sudo cp /opt/agmind/docker/nginx/nginx.conf.bak.phase36.* /opt/agmind/docker/nginx/nginx.conf  # последний backup
sudo docker exec agmind-nginx nginx -s reload
# 3. Stop Authelia
sudo docker compose stop authelia
```
