#!/usr/bin/env bash
# authelia.sh — Configure Authelia 2FA (optional, gated by ENABLE_AUTHELIA)
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

INSTALL_DIR="${INSTALL_DIR:-/opt/agmind}"

configure_authelia() {
    if [[ "${ENABLE_AUTHELIA:-false}" != "true" ]]; then
        return 0
    fi

    echo -e "${YELLOW}Настройка Authelia 2FA...${NC}"

    local template_dir="$1"
    local authelia_dir="${INSTALL_DIR}/docker/authelia"
    mkdir -p "$authelia_dir"

    # Copy configuration template
    cp "${template_dir}/authelia/configuration.yml.template" "${authelia_dir}/configuration.yml"

    # Generate argon2 hash for admin password
    local admin_password="${ADMIN_PASSWORD:-}"
    if [[ -z "$admin_password" ]]; then
        admin_password=$(cat "${INSTALL_DIR}/.admin_password" 2>/dev/null || head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 16)
    fi

    local admin_hash
    admin_hash=$(generate_argon2_hash "$admin_password") || {
        echo -e "${RED}Ошибка: не удалось сгенерировать хеш пароля для Authelia${NC}"
        echo -e "${YELLOW}Установите argon2 или Docker для генерации хешей${NC}"
        return 1
    }

    # Copy users database template
    cp "${template_dir}/authelia/users_database.yml.template" "${authelia_dir}/users_database.yml"

    # Generate JWT secret
    local jwt_secret
    jwt_secret=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | head -c 64)

    # Escape user-controlled values for safe sed substitution
    local safe_domain safe_company
    safe_domain=$(printf '%s' "${DOMAIN:-localhost}" | sed 's/[&/|\]/\\&/g')
    safe_company=$(printf '%s' "${COMPANY_NAME:-AGMind}" | sed 's/[&/|\]/\\&/g')

    # Replace placeholders in configuration.yml
    sed -i.bak \
        -e "s|__AUTHELIA_JWT_SECRET__|${jwt_secret}|g" \
        -e "s|__DOMAIN__|${safe_domain}|g" \
        -e "s|__COMPANY_NAME__|${safe_company}|g" \
        "${authelia_dir}/configuration.yml"
    rm -f "${authelia_dir}/configuration.yml.bak"

    # Replace placeholders in users_database.yml
    sed -i.bak \
        -e "s|__AUTHELIA_ADMIN_HASH__|${admin_hash}|g" \
        -e "s|__ADMIN_EMAIL__|${ADMIN_EMAIL:-admin@${DOMAIN:-localhost}}|g" \
        -e "s|__COMPANY_NAME__|${safe_company}|g" \
        "${authelia_dir}/users_database.yml"
    rm -f "${authelia_dir}/users_database.yml.bak"

    # Set restrictive permissions on config files
    chmod 600 "${authelia_dir}/configuration.yml" "${authelia_dir}/users_database.yml"

    # Also update .env with the generated JWT secret
    local env_file="${INSTALL_DIR}/docker/.env"
    if [[ -f "$env_file" ]]; then
        sed -i.bak "s|AUTHELIA_JWT_SECRET=.*|AUTHELIA_JWT_SECRET=${jwt_secret}|" "$env_file"
        rm -f "${env_file}.bak"
    fi

    echo -e "${GREEN}Authelia 2FA настроена: ${authelia_dir}${NC}"
}

generate_argon2_hash() {
    local password="$1"

    # Use docker to generate argon2 hash via authelia container (pass password via stdin)
    if command -v docker &>/dev/null; then
        local hash
        hash=$(echo -n "$password" | docker run --rm -i authelia/authelia:${AUTHELIA_VERSION:-4.38} \
            authelia crypto hash generate argon2 --stdin 2>/dev/null | tail -1) || true
        if [[ -n "$hash" ]]; then
            echo "$hash"
            return 0
        fi
    fi

    # Degraded fallback: use python3 scrypt-based hash if available.
    # NOTE: This produces a scrypt hash, NOT argon2id. It may not work with all
    # Authelia versions. The docker method above is strongly preferred.
    if command -v python3 &>/dev/null; then
        hash=$(AUTHELIA_PW="$password" python3 -c "
import os, hashlib, base64
password = os.environ['AUTHELIA_PW'].encode()
salt = os.urandom(16)
h = hashlib.scrypt(password, salt=salt, n=65536, r=8, p=1, dklen=32)
print(base64.b64encode(salt).decode() + '\$' + base64.b64encode(h).decode())
" 2>/dev/null)
        if [[ -n "$hash" ]]; then
            echo "$hash"
            return 0
        fi
    fi

    # Last resort: placeholder that must be replaced manually
    echo -e "${RED}ВНИМАНИЕ: не удалось сгенерировать argon2 хеш. Замените вручную.${NC}" >&2
    echo '$argon2id$v=19$m=65536,t=3,p=4$PLACEHOLDER_SALT$PLACEHOLDER_HASH'
    return 1
}

create_authelia_user() {
    local email="$1"
    local password="$2"

    if [[ -z "$email" || -z "$password" ]]; then
        echo -e "${RED}Использование: create_authelia_user <email> <password>${NC}"
        return 1
    fi

    local authelia_dir="${INSTALL_DIR}/docker/authelia"
    local users_file="${authelia_dir}/users_database.yml"

    if [[ ! -f "$users_file" ]]; then
        echo -e "${RED}Файл пользователей не найден: ${users_file}${NC}"
        return 1
    fi

    # Derive username from email
    local username
    username=$(echo "$email" | cut -d'@' -f1 | tr '.' '_' | tr '[:upper:]' '[:lower:]')

    # Generate password hash
    local password_hash
    password_hash=$(generate_argon2_hash "$password")

    # Append user to users_database.yml
    printf '  %s:\n    displayname: "%s"\n    password: "%s"\n    email: %s\n    groups:\n      - admins\n      - users\n' \
        "$username" "$username" "$password_hash" "$email" >> "$users_file"

    echo -e "${GREEN}Пользователь ${username} (${email}) добавлен в Authelia${NC}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Этот скрипт предназначен для sourcing из install.sh"
    exit 1
fi
