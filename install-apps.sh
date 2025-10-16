#!/usr/bin/env bash

set -euo pipefail

# =========================
# Instalador DEV + LAZER Linux (Ubuntu/Debian, Fedora, Arch)
# =========================

INSTALL_DOCKER=1
INSTALL_DEV=1
INSTALL_LEISURE=1

for arg in "$@"; do
  case "$arg" in
    --no-docker) INSTALL_DOCKER=0 ;;
    --dev-only) INSTALL_LEISURE=0 ;;
    --leisure-only) INSTALL_DEV=0 ;;
    *) echo "Opção desconhecida: $arg"; exit 1 ;;
  esac
done

need_sudo() { [ "$EUID" -ne 0 ]; }
run_sudo() { if need_sudo; then sudo "$@"; else "$@"; fi }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Detectar gerenciador
PKG=""
if command_exists apt; then
  PKG="apt"
elif command_exists dnf; then
  PKG="dnf"
elif command_exists pacman; then
  PKG="pacman"
else
  echo "❌ Distro não suportada."; exit 1
fi
echo "➡️  Detectado gerenciador: $PKG"

# Pacotes base
case "$PKG" in
  apt)
    run_sudo apt update -y
    run_sudo apt install -y \
      git curl wget ca-certificates unzip zip tar \
      software-properties-common \
      build-essential \
      python3 python3-pip python3-venv
    ;;
  dnf)
    run_sudo dnf -y update
    run_sudo dnf -y groupinstall "Development Tools"
    run_sudo dnf -y install \
      git curl wget ca-certificates unzip zip tar \
      python3 python3-pip
    ;;
  pacman)
    run_sudo pacman -Sy --noconfirm
    run_sudo pacman -S --noconfirm --needed \
      git curl wget ca-certificates unzip zip tar \
      base-devel \
      python python-pip
    ;;
esac

# =========================
# Remoções solicitadas
# =========================

# 1) LibreOffice
echo "🧹 Removendo LibreOffice..."
case "$PKG" in
  apt)
    run_sudo apt remove -y --purge libreoffice* || true
    run_sudo apt autoremove -y || true
    ;;
  dnf)
    run_sudo dnf -y remove libreoffice\* || true
    ;;
  pacman)
    run_sudo pacman -Rns --noconfirm libreoffice-fresh libreoffice-still || true
    ;;
esac

# 2) Weather, Calendar, Contacts, Geary, Seahorse (pacotes e flatpaks)
echo "🧹 Removendo Weather, Calendar, Contacts, Geary e Seahorse (pacotes e flatpaks)..."

# Tentar remover versões Flatpak (ignora erros se não instaladas)
if command_exists flatpak; then
  run_sudo flatpak uninstall -y --noninteractive --delete-data \
    org.gnome.Weather \
    org.gnome.Calendar \
    org.gnome.Contacts \
    org.gnome.Geary \
    org.gnome.seahorse \
    org.gnome.Seahorse || true
fi

# Remover pacotes nativos
case "$PKG" in
  apt)
    run_sudo apt remove -y --purge \
      gnome-weather gnome-calendar gnome-contacts geary seahorse || true
    run_sudo apt autoremove -y || true
    ;;
  dnf)
    run_sudo dnf -y remove \
      gnome-weather gnome-calendar gnome-contacts geary seahorse || true
    ;;
  pacman)
    run_sudo pacman -Rns --noconfirm \
      gnome-weather gnome-calendar gnome-contacts geary seahorse || true
    ;;
esac

# pipx
if ! command_exists pipx; then
  python3 -m pip install --user pipx >/dev/null 2>&1 || true
  python3 -m pipx ensurepath || true
fi

# Flatpak + Flathub
install_flatpak_and_flathub() {
  if ! command_exists flatpak; then
    case "$PKG" in
      apt) run_sudo apt install -y flatpak ;;
      dnf) run_sudo dnf -y install flatpak ;;
      pacman) run_sudo pacman -S --noconfirm --needed flatpak ;;
    esac
  fi
  if ! flatpak remote-list | grep -qi flathub; then
    run_sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi
}
install_flatpak_and_flathub

# Docker (com docker-cli)
install_docker() {
  echo "🐳 Instalando Docker + Docker CLI..."
  case "$PKG" in
    apt)
      run_sudo apt install -y docker.io docker-buildx-plugin docker-compose-plugin docker-cli
      ;;
    dnf)
      run_sudo dnf -y install docker docker-buildx docker-compose docker-cli
      ;;
    pacman)
      run_sudo pacman -S --noconfirm --needed docker docker-compose docker-cli
      ;;
  esac
  run_sudo systemctl enable --now docker || true
  if getent group docker >/dev/null 2>&1; then
    run_sudo usermod -aG docker "$USER" || true
  else
    run_sudo groupadd docker || true
    run_sudo usermod -aG docker "$USER" || true
    run_sudo systemctl restart docker || true
  fi
  echo "✅ Docker instalado. Faça logoff/login."
}

# Listas Flatpak
DEV_APPS=(
  "com.visualstudio.code"            # VsCode
  "com.getpostman.Postman"           # Postman
  "com.jetbrains.DataGrip"           # DataGrip
  "com.jetbrains.PhpStorm"           # PhpStorm
  "com.jetbrains.PyCharm-Community"  # PyCharm
  "com.usebottles.bottles"           # Bottles
  "com.discordapp.Discord"           # Discord
  "org.mozilla.firefox"              # Firefox Developer
  "org.remmina.Remmina"              # Remmina
  "org.onlyoffice.desktopeditors"    # ONLYOFFICE (substitui LibreOffice)
  "org.qbittorrent.qBittorrent"      # qBittorrent
  "io.github.shiftey.Desktop"        # GitHub Desktop
  "org.filezillaproject.Filezilla"   # FileZilla 
)

LEISURE_APPS=(
  "com.github.tchx84.Flatseal"       # Flatseal
  "com.spotify.Client"               # Spotify
  "com.valvesoftware.Steam"          # Steam
  "net.lutris.Lutris"                # Lutris
  "com.github.Matoking.protontricks" # Protontricks
  "com.vysp3r.ProtonPlus"            # ProtonPlus
  "com.heroicgameslauncher.hgl"      # Heroic Games Launcher
  "com.obsproject.Studio"            # OBS
  "org.videolan.VLC"                 # VLC
  "com.calibre_ebook.calibre"        # Calibre
)

install_flatpak_apps() {
  local -n arr=$1
  for app in "${arr[@]}"; do
    if flatpak list --app | awk '{print $1}' | grep -qx "$app"; then
      echo "• $app já instalado."
    else
      echo "⬇️  Instalando $app..."
      run_sudo flatpak install -y flathub "$app"
    fi
  done
}

install_chrome_repo() {
  if [ "$PKG" = "apt" ]; then
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | run_sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | run_sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
    run_sudo apt update
    run_sudo apt install -y google-chrome-stable
  elif [ "$PKG" = "dnf" ]; then
    run_sudo dnf -y install fedora-workstation-repositories
    run_sudo dnf config-manager --set-enabled google-chrome
    run_sudo dnf -y install google-chrome-stable
  elif [ "$PKG" = "pacman" ]; then
    echo "⚠️ No Arch, instale o Chrome via AUR: yay -S google-chrome"
  fi
}

install_hydra_launcher() {
  echo "⬇️  Instalando Hydra Launcher..."
  TMP_DIR=$(mktemp -d)
  cd "$TMP_DIR"

  case "$PKG" in
    apt)
      wget -q https://github.com/hydralauncher/hydra/releases/download/v3.6.3/hydralauncher_3.6.3_amd64.deb -O hydra-launcher.deb
      run_sudo apt install -y ./hydra-launcher.deb
      ;;
    dnf)
      wget -q https://github.com/hydralauncher/hydra/releases/download/v3.6.3/hydralauncher-3.6.3.x86_64.rpm -O hydra-launcher.rpm
      run_sudo dnf install -y ./hydra-launcher.rpm
      ;;
    pacman)
      wget -q https://github.com/hydralauncher/hydra/releases/download/v3.6.3/hydralauncher-3.6.3.AppImage -O hydra-launcher.AppImage
      chmod +x hydra-launcher.AppImage
      run_sudo mv hydra-launcher.AppImage /usr/local/bin/hydra-launcher
      ;;
  esac

  cd - >/dev/null
  rm -rf "$TMP_DIR"
  echo "✅ Hydra Launcher instalado!"
}

install_cli_extras() {
  if ! command_exists zsh; then
    case "$PKG" in
      apt) run_sudo apt install -y zsh ;;
      dnf) run_sudo dnf -y install zsh ;;
      pacman) run_sudo pacman -S --noconfirm --needed zsh ;;
    esac
  fi
  if ! command_exists fzf; then
    case "$PKG" in
      apt) run_sudo apt install -y fzf ;;
      dnf) run_sudo dnf -y install fzf ;;
      pacman) run_sudo pacman -S --noconfirm --needed fzf ;;
    esac
  fi
  if ! command_exists bat && [ "$PKG" = "apt" ]; then
    run_sudo apt install -y bat ripgrep
    if ! command_exists bat && command_exists batcat; then
      run_sudo update-alternatives --install /usr/local/bin/bat bat /usr/bin/batcat 1 || true
    fi
  elif ! command_exists bat && [ "$PKG" = "dnf" ]; then
    run_sudo dnf -y install bat ripgrep
  elif ! command_exists bat && [ "$PKG" = "pacman" ]; then
    run_sudo pacman -S --noconfirm --needed bat ripgrep
  fi
}

echo "🚀 Iniciando instalação..."
install_cli_extras

if [ "$INSTALL_DEV" -eq 1 ]; then
  echo "🛠 Instalando DEV..."
  install_flatpak_apps DEV_APPS
fi

if [ "$INSTALL_LEISURE" -eq 1 ]; then
  echo "🎮 Instalando LAZER..."
  install_flatpak_apps LEISURE_APPS
  install_hydra_launcher
fi

install_chrome_repo

if [ "$INSTALL_DOCKER" -eq 1 ]; then
  install_docker
fi

echo "✅ Instalação concluída! Apps GNOME (Weather/Calendar/Contacts/Geary/Seahorse) e LibreOffice removidos."