#!/usr/bin/env bash
set -euo pipefail

### Config padrão
TEXTDOMAIN=virtualhost

action="${1:-}"    # create | delete | -h/--h/--help
domain="${2:-}"    # ex: meusite.local
rootDir="${3:-}"   # ex: /var/www/meusite.local  (se vazio, usa /var/www/<domain>)

email="${EMAIL:-webmaster@localhost}"
sitesEnable='/etc/apache2/sites-enabled/'
sitesAvailable='/etc/apache2/sites-available/'
userDir='/var/www/'
owner="${SUDO_USER:-${USER:-}}"

print_usage() {
  cat <<'EOF'
Uso:
  sudo ./vhost-config.sh create <dominio> [docroot] [flags]
  sudo ./vhost-config.sh delete <dominio> [docroot]
  sudo ./vhost-config.sh --h | -h | --help

Parâmetros:
  <dominio>  Domínio do vhost (ex.: meusite.local)
  [docroot]  Caminho do DocumentRoot. Se omitido, usa /var/www/<dominio>
             Se fornecer caminho relativo, ele será prefixado por /var/www/

Flags (opcionais):
  --signed              Tenta emitir certificado Let's Encrypt (webroot). Padrão: autoassinado
  --ssl-redirect        Adiciona redirecionamento 80 -> 443
  --php[=VERSAO]        Força backend PHP-FPM por versão (socket)
                        Aceita tokens: php56/5.6/56, php70/7.0/70, ..., php84/8.4/84
                        Exemplos: --php=8.2  |  --php php83
  -h, --h, --help       Mostra esta ajuda e sai

Variáveis de ambiente:
  EMAIL                 E-mail do administrador/Let's Encrypt (padrão: webmaster@localhost)

Exemplos:
  # Criar vhost com autoassinado (padrão), docroot padrão /var/www/meusite.local
  sudo ./vhost-config.sh create meusite.local

  # Criar vhost forçando PHP 8.2 via socket e com redirect 80->443
  sudo ./vhost-config.sh create meusite.local /var/www/meusite --php=8.2 --ssl-redirect

  # Criar vhost tentando Let's Encrypt (cai para autoassinado se falhar)
  sudo ./vhost-config.sh create meusite.local --signed

  # Remover vhost (pergunta se deseja excluir o diretório)
  sudo ./vhost-config.sh delete meusite.local
EOF
}

# ajuda como 1º argumento
case "${action:-}" in
  -h|--h|--help|help)
    print_usage
    exit 0
    ;;
esac

# Consome os 3 posicionais; flags começam a partir daqui
shift 3 || true

# Flags opcionais
force_selfsigned=true   # padrão: true
no_redirect=true        # padrão: true
php_token=""            # ex: php74, php83, 8.2, 82

while (( "$#" )); do
  case "${1:-}" in
    --signed) force_selfsigned=false; shift;;
    --ssl-redirect) no_redirect=false; shift;;
    --php=*) php_token="${1#*=}"; shift;;
    --php)   php_token="${2:-}"; shift 2;;
    -h|--h|--help) print_usage; exit 0;;
    *) shift;;
  esac
done

sitesAvailabledomain=""
letsencrypt_live="/etc/letsencrypt/live"

die(){ echo >&2 "$*"; exit 1; }

reload_apache(){
  if command -v systemctl >/dev/null 2>&1; then
    apachectl configtest
    systemctl reload apache2
  else
    apache2ctl -t
    /etc/init.d/apache2 reload
  fi
}

a2site_enable(){ a2ensite "${domain}.conf" >/dev/null; }
a2site_disable(){ a2dissite "${domain}.conf" >/dev/null; }

ensure_httpd_mods(){
  a2enmod ssl >/dev/null || true
  a2enmod rewrite >/dev/null || true
  a2enmod proxy >/dev/null || true
  a2enmod proxy_fcgi >/dev/null || true
  a2enmod setenvif >/dev/null || true
}

have_certbot(){ command -v certbot >/dev/null 2>&1; }
have_openssl(){ command -v openssl >/dev/null 2>&1; }

# Normaliza tokens como php74/74/7.4/8.2/php82 -> "7.4" / "8.2"
map_php_token(){
  local t="${1,,}"
  case "${t}" in
    php56|5.6|56) echo "5.6" ;;
    php70|7.0|70) echo "7.0" ;;
    php71|7.1|71) echo "7.1" ;;
    php72|7.2|72) echo "7.2" ;;
    php73|7.3|73) echo "7.3" ;;
    php74|7.4|74) echo "7.4" ;;
    php80|8.0|80) echo "8.0" ;;
    php81|8.1|81) echo "8.1" ;;
    php82|8.2|82) echo "8.2" ;;
    php83|8.3|83) echo "8.3" ;;
    php84|8.4|84) echo "8.4" ;;
    *) echo "" ;;
  esac
}

# Descobre o backend do PHP-FPM (socket preferencial, senão TCP 127.0.0.1:9000)
detect_php_backend(){
  local ver_sock="" sock="" tcp="127.0.0.1:9000"
  if [[ -n "${php_token}" ]]; then
    ver_sock="$(map_php_token "${php_token}")"
    [[ -z "${ver_sock}" ]] && die "Versão PHP inválida em --php=${php_token}"
    sock="/run/php/php${ver_sock}-fpm.sock"
    [[ -S "${sock}" ]] || die "Socket do PHP-FPM não encontrado: ${sock} (garanta que php${ver_sock}-fpm está instalado/rodando)"
    echo "unix:${sock}"
    return 0
  fi
  local found
  found="$(ls -1 /run/php/php*-fpm.sock 2>/dev/null | sort -V | tail -n1 || true)"
  if [[ -n "${found}" && -S "${found}" ]]; then
    echo "unix:${found}"
  else
    echo "tcp:${tcp}"
  fi
}

# validações iniciais
[ "$(id -u)" -eq 0 ] || die "Use sudo/root para executar."
[[ "${action}" =~ ^(create|delete)$ ]] || { print_usage; die "Ação inválida. Use: create ou delete."; }

while [[ -z "${domain}" ]]; do
  read -r -p "Informe o domínio (ex: meusite.local): " domain
done

# Aceita domínios com pontos e hífens
if ! [[ "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; then
  die "Domínio inválido: ${domain}"
fi

# rootDir padrão preservando pontos
if [[ -z "${rootDir}" ]]; then
  rootDir="${userDir}${domain}"
fi
# se for caminho absoluto, não prefixa /var/www
if [[ "${rootDir}" =~ ^/ ]]; then
  : # mantém como está
else
  rootDir="${userDir}${rootDir}"
fi

sitesAvailabledomain="${sitesAvailable}${domain}.conf"

if [[ "${action}" == "create" ]]; then
  # evita sobrescrever vhost
  if [[ -e "${sitesAvailabledomain}" ]]; then
    die "O vhost ${domain} já existe em ${sitesAvailabledomain}"
  fi

  # cria docroot
  if [[ ! -d "${rootDir}" ]]; then
    mkdir -p "${rootDir}"
    chmod 755 "${rootDir}"
    echo "<?php echo phpinfo(); ?>" > "${rootDir}/phpinfo.php" || die "Falha ao criar phpinfo.php"
  fi

  # habilita módulos necessários
  ensure_httpd_mods

  # descobre backend do PHP-FPM
  php_backend="$(detect_php_backend)"  # unix:/run/php/php8.2-fpm.sock  OU  tcp:127.0.0.1:9000

  # bloco FilesMatch para PHP-FPM
  php_handler_block=""
  if [[ "${php_backend}" == unix:* ]]; then
    php_sock="${php_backend#unix:}"
    php_handler_block=$(cat <<EOF
    <FilesMatch "\\.php$">
        SetHandler "proxy:unix:${php_sock}|fcgi://localhost/"
    </FilesMatch>
EOF
)
  else
    php_tcp="${php_backend#tcp:}"
    php_handler_block=$(cat <<EOF
    <FilesMatch "\\.php$">
        SetHandler "proxy:fcgi://${php_tcp}"
    </FilesMatch>
EOF
)
  fi

  # vhost :80 (com opção de redirect → 443)
  redirect_block=""
  if ! ${no_redirect}; then
    redirect_block="Redirect permanent / https://${domain}/"
  fi

  vhost80="<VirtualHost *:80>
    ServerAdmin ${email}
    ServerName ${domain}
    ServerAlias ${domain}
    DocumentRoot ${rootDir}
    DirectoryIndex index.php index.html
    <Directory ${rootDir}>
        Options Indexes FollowSymLinks MultiViews
        AllowOverride all
        Require all granted
    </Directory>
    ${php_handler_block}
    ${redirect_block}
    ErrorLog /var/log/apache2/${domain}-error.log
    LogLevel warn
    CustomLog /var/log/apache2/${domain}-access.log combined
</VirtualHost>
"

  # grava inicialmente só o :80 (sem SSL) para habilitar o desafio webroot
  echo "${vhost80}" > "${sitesAvailabledomain}"

  # adiciona no /etc/hosts se não existir
  if ! grep -qE "[[:space:]]${domain}([[:space:]]|\$)" /etc/hosts; then
    echo "127.0.0.1    ${domain}" >> /etc/hosts || die "Erro ao escrever em /etc/hosts"
  fi

  # dono da pasta
  if [[ -n "${owner}" ]]; then
    chown -R "${owner}:${owner}" "${rootDir}" || true
  fi

  # habilita :80 e recarrega
  a2site_enable
  reload_apache

  # === CERTIFICADO ===
  fullchain=""
  privkey=""
  if ${force_selfsigned}; then
    pair=$(generate_self_signed)
  else
    pair=$(obtain_letsencrypt "${rootDir}")
    if [[ -z "${pair}" ]]; then
      echo "Não foi possível emitir Let’s Encrypt (domínio interno? fallback: autoassinado)."
      pair=$(generate_self_signed)
    fi
  fi
  fullchain="${pair%%|*}"
  privkey="${pair##*|}"

  # monta vhost :443 com o certificado encontrado/gerado
  vhost443="
<VirtualHost *:443>
    ServerAdmin ${email}
    ServerName ${domain}
    ServerAlias ${domain}
    DocumentRoot ${rootDir}
    DirectoryIndex index.php index.html
    <Directory ${rootDir}>
        Options Indexes FollowSymLinks MultiViews
        AllowOverride all
        Require all granted
    </Directory>
    ErrorLog /var/log/apache2/${domain}-ssl-error.log
    LogLevel warn
    CustomLog /var/log/apache2/${domain}-ssl-access.log combined

    SSLEngine on
    SSLCertificateFile ${fullchain}
    SSLCertificateKeyFile ${privkey}

    ${php_handler_block}
</VirtualHost>
"

  # escreve :80 + :443 (mantendo redirect em :80 se habilitado)
  {
    echo "${vhost80}"
    echo "${vhost443}"
  } > "${sitesAvailabledomain}"

  # recarrega
  reload_apache

  echo "Concluído!"
  echo "HTTP : http://${domain}"
  echo "HTTPS: https://${domain}"
  echo "Docroot: ${rootDir}"
  if [[ "${php_backend}" == unix:* ]]; then
    echo "PHP-FPM (socket): ${php_backend#unix:}"
  else
    echo "PHP-FPM (tcp): ${php_backend#tcp:}"
  fi
  if [[ "${fullchain}" == *"/etc/letsencrypt/"* ]]; then
    echo "Certificado: Let’s Encrypt (webroot)."
  else
    echo "Certificado: autoassinado (OpenSSL)."
  fi

  exit 0
fi

# ===== DELETE =====
if [[ ! -e "${sitesAvailabledomain}" ]]; then
  die "O vhost ${domain} não existe em ${sitesAvailabledomain}"
fi

# remove do /etc/hosts
sed -i.bak "/[[:space:]]${domain}\([[:space:]]\|\$\)/d" /etc/hosts || true

# desabilita e recarrega
a2site_disable
reload_apache

# apaga .conf
rm -f "${sitesAvailabledomain}"

# tenta deletar certificado LE (opcional, silencioso)
if have_certbot; then
  certbot delete --cert-name "${domain}" -n >/dev/null 2>&1 || true
fi

# pergunta sobre diretório
if [[ -d "${rootDir}" ]]; then
  read -r -p "Excluir diretório raiz (${rootDir})? [y/N] " deldir
  if [[ "${deldir,,}" == "y" ]]; then
    rm -rf "${rootDir}"
    echo "Diretório removido."
  else
    echo "Diretório mantido."
  fi
fi

echo "Concluído! VirtualHost ${domain} removido."
