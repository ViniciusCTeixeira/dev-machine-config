#!/usr/bin/env bash
# setup-full-stack.sh
# Apache + MySQL + JRE + Oracle Instant Client + PHP 5.6..8.4 (todas extensões habilitadas) + NVM + Redis

set -euo pipefail

PHP_VERSIONS=("5.6" "7.0" "7.1" "7.2" "7.3" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4")
PHP_EXTS_BASE=(bcmath calendar curl exif gd gmp intl ldap mbstring imap mysql readline shmop soap sockets sqlite3 xml zip xdebug redis oci8)

INSTANT_CLIENT_VERSION="23.5"
INSTANT_CLIENT_DIR="/opt/oracle"
NVM_VERSION="v0.39.7"

log()  { echo -e "\e[1;32m[OK]\e[0m $*"; }
warn() { echo -e "\e[1;33m[AVISO]\e[0m $*"; }
err()  { echo -e "\e[1;31m[ERRO]\e[0m $*" >&2; }

require_root() { [[ $EUID -eq 0 ]] || { err "Execute como root: sudo bash $0"; exit 1; }; }
check_apt()   { command -v apt-get >/dev/null || { err "Script para Ubuntu/Debian (usa apt)."; exit 1; }; }

pkg_available() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}' | grep -vq '(none)'
}

add_ppa_if_needed() {
  if ! grep -Rqs "^deb .*\sondrej/php" /etc/apt/; then
    log "Adicionando PPA ondrej/php…"
    apt-get update -y
    apt-get install -y software-properties-common ca-certificates lsb-release apt-transport-https
    add-apt-repository -y ppa:ondrej/php
  else
    log "PPA ondrej/php já presente."
  fi
}

install_apache_mysql_java() {
  log "Instalando Apache, MySQL e JRE…"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y apache2 mysql-server default-jre unzip wget curl git
  systemctl enable --now apache2
  systemctl enable --now mysql
  log "Apache, MySQL e Java prontos."
}

install_redis() {
  log "Instalando Redis Server (versão estável do repositório)…"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server
  systemctl enable --now redis-server
  log "Redis instalado e em execução na porta padrão 6379."
}

install_instant_client() {
  log "Instalando Oracle Instant Client ${INSTANT_CLIENT_VERSION}…"
  mkdir -p "$INSTANT_CLIENT_DIR"
  cd "$INSTANT_CLIENT_DIR"
  FILES=(
    "instantclient-basic-linux.x64-${INSTANT_CLIENT_VERSION}.0.0dbru.zip"
    "instantclient-sdk-linux.x64-${INSTANT_CLIENT_VERSION}.0.0dbru.zip"
    "instantclient-sqlplus-linux.x64-${INSTANT_CLIENT_VERSION}.0.0dbru.zip"
  )
  BASE_URL="https://download.oracle.com/otn_software/linux/instantclient/${INSTANT_CLIENT_VERSION}000"
  for f in "${FILES[@]}"; do
    wget -q "${BASE_URL}/${f}"
    unzip -o "$f"
    rm -f "$f"
  done
  echo "${INSTANT_CLIENT_DIR}/instantclient_${INSTANT_CLIENT_VERSION}_0" > /etc/ld.so.conf.d/oracle-instantclient.conf
  ldconfig
  log "Instant Client instalado em ${INSTANT_CLIENT_DIR}/instantclient_${INSTANT_CLIENT_VERSION}_0"
}

install_php_versions_and_exts() {
  apt-get update -y
  declare -A REPORT_ENABLED
  declare -A REPORT_SKIPPED

  for ver in "${PHP_VERSIONS[@]}"; do
    major="${ver%%.*}"
    EXTS=("${PHP_EXTS_BASE[@]}")
    PKGS=("php${ver}-fpm" "php${ver}-cli")
    for ext in "${EXTS[@]}"; do
      pkg="php${ver}-${ext}"
      if pkg_available "$pkg"; then
        PKGS+=("$pkg")
      else
        REPORT_SKIPPED["$ver"]+="${ext} "
      fi
    done

    log "Instalando PHP ${ver} e extensões…"
    set +e
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKGS[@]}"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && { warn "Falha PHP ${ver}"; continue; }

    systemctl enable --now "php${ver}-fpm" || true

    enabled_list=""
    for ext in "${EXTS[@]}"; do
      phpenmod -v "$ver" -s ALL "$ext" 2>/dev/null && enabled_list+="$ext "
    done
    REPORT_ENABLED["$ver"]="$enabled_list"
  done

  echo
  echo "================ RESULTADO ================"
  for ver in "${PHP_VERSIONS[@]}"; do
    echo "PHP $ver"
    [[ -n "${REPORT_ENABLED[$ver]:-}" ]] && echo "  ✓ Habilitado: ${REPORT_ENABLED[$ver]}"
    [[ -n "${REPORT_SKIPPED[$ver]:-}" ]] && echo "  ✗ Indisponíveis: ${REPORT_SKIPPED[$ver]}"
  done
  echo "==========================================="
}

install_nvm() {
  log "Instalando NVM ${NVM_VERSION}…"
  export NVM_DIR="/usr/local/nvm"
  mkdir -p "$NVM_DIR"
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
  cat >/etc/profile.d/nvm.sh <<EOF
export NVM_DIR="${NVM_DIR}"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
EOF
  log "NVM instalado. Para usar, abra um novo shell e rode: nvm install --lts"
}

enable_apache_modules() {
  log "Ativando módulos do Apache para PHP-FPM…"
  a2enmod proxy_fcgi setenvif actions alias rewrite >/dev/null
  systemctl restart apache2
}

drop_info_php() {
  echo "<?php phpinfo();" > /var/www/html/info.php
}

final_restart() {
  for ver in "${PHP_VERSIONS[@]}"; do
    systemctl restart "php${ver}-fpm" 2>/dev/null || true
  done
  systemctl restart apache2 || true
  systemctl restart redis-server || true
}

post_notes() {
  cat <<'EOF'

Tudo pronto! 🎉

- Apache + MySQL + JRE instalados
- Oracle Instant Client 23.5 instalado e configurado (ldconfig)
- Redis Server instalado e ativo (porta 6379)
- PHP 5.6, 7.0–7.4, 8.0–8.4 com extensões instaladas e **habilitadas** (CLI e FPM):
  bcmath, calendar, curl, exif, gd, gmp, intl, ldap, mbstring, imap,
  mysql (mysqli/pdo_mysql/mysqlnd), readline, shmop, soap, sockets,
  sqlite3, xml (dom/simplexml/xmlreader/xmlwriter/xsl), zip, xdebug, redis, oci8

Testes:
  • Abra http://SEU_SERVIDOR/info.php
  • Se 'oci8' não aparecer, verifique permissões/variáveis e que o Instant Client está em /etc/ld.so.conf.d (rodamos ldconfig).
  • Teste o Redis: redis-cli ping → deve retornar PONG

Segurança do MySQL:
  sudo mysql_secure_installation
  
Para Node.js: abra um novo shell e rode:
  nvm install --lts
EOF
}

main() {
  require_root
  check_apt
  add_ppa_if_needed
  install_apache_mysql_java
  install_redis
  install_instant_client
  install_php_versions_and_exts
  install_nvm
  enable_apache_modules
  drop_info_php
  final_restart
  post_notes
}

main "$@"
