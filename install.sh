#!/usr/bin/env bash
# vm-mint-install - interaktive Ersteinrichtung frischer Debian-/Ubuntu-VMs.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/hyydroo/vm-mint-install/main/install.sh)"
#
# Alles steckt in dieser einen Datei. Temporäre Dateien liegen in einem Arbeitsordner, der am Ende
# gelöscht wird; eine heruntergeladene Kopie des Skripts löscht sich auf Wunsch selbst.
#
# Optionen:  --yes             alle Fragen mit dem Standard beantworten (für Automatisierung)
#            --skip=a,b        Module überspringen: base, prompt, ssh, ansible, docker, updates
#            --dry-run         nur anzeigen, was passieren würde (ändert nichts, braucht kein root)
#            --version, --help
# Umgebungsvariablen (vor allem mit --yes): ADMIN_GITHUB_USER, ADMIN_PUBKEY, NEW_HOSTNAME, TZ_NAME,
#            ANSIBLE_PUBKEY, DOCKER_USER

set -Eeuo pipefail

SCRIPT_VERSION="1.0.0"

# --- Einstellungen ---------------------------------------------------------------------------------
# Öffentlicher Schlüssel des Ansible-Servers (Orchestrator). Öffentliche Schlüssel sind unkritisch.
ANSIBLE_PUBKEY="${ANSIBLE_PUBKEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPJcGlcb3egfpMnbTus5mbUMpjXCVk57EcVE4FFVWDJP ansible@orchestrator}"
# Zeilen mit diesem Kommentar werden aus authorized_keys des Ansible-Benutzers entfernt (alter Schlüssel).
OLD_ANSIBLE_KEY_MARKER="ansible@svc-hy-ansible"
ANSIBLE_USER="ansible"
DEFAULT_TZ="Europe/Berlin"

# --- Zustand ---------------------------------------------------------------------------------------
ASSUME_YES=0
DRY_RUN=0
SKIP=","
SUMMARY=()
ADMIN_KEY_INSTALLED=0
WORK=""
SELF_FILE=""
SELF_DELETE=0

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""
fi

# --- Ausgabe ---------------------------------------------------------------------------------------
step() { printf '\n%s== %s ==%s\n' "$C_BOLD$C_CYAN" "$1" "$C_RESET"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
die()  { printf '%s✗ %s%s\n' "$C_RED" "$1" "$C_RESET" >&2; exit 1; }
done_note() { SUMMARY+=("$1"); }

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'; }

# --- Eingaben --------------------------------------------------------------------------------------
# ask_yn "Frage" y|n   -> Rückgabe 0 = ja
ask_yn() {
  local text="$1" def="$2" hint reply
  [[ $def == y ]] && hint="J/n" || hint="j/N"
  if ((ASSUME_YES)); then [[ $def == y ]]; return; fi
  while true; do
    read -r -p "$(printf '  %s?%s %s [%s] ' "$C_CYAN" "$C_RESET" "$text" "$hint")" reply </dev/tty || reply=""
    case "${reply,,}" in
      "") [[ $def == y ]]; return ;;
      j|ja|y|yes) return 0 ;;
      n|nein|no) return 1 ;;
    esac
  done
}

# ask_text "Frage" "Standard"  -> Antwort auf stdout
ask_text() {
  local text="$1" def="${2:-}" reply
  if ((ASSUME_YES)); then printf '%s' "$def"; return; fi
  read -r -p "$(printf '  %s?%s %s%s ' "$C_CYAN" "$C_RESET" "$text" "${def:+ [$def]}")" reply </dev/tty || reply=""
  printf '%s' "${reply:-$def}"
}

skipped() { [[ $SKIP == *",$1,"* ]]; }

# --- Hilfsfunktionen -------------------------------------------------------------------------------
# Führt einen Befehl aus (oder zeigt ihn nur an bei --dry-run).
run() {
  if ((DRY_RUN)); then printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"; return 0; fi
  "$@"
}

apt_install() {
  if ((DRY_RUN)); then info "[dry-run] apt install $*"; return 0; fi
  env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >/dev/null
}

ensure_keygen() { command -v ssh-keygen >/dev/null 2>&1 || apt_install openssh-client; }

valid_pubkey() {
  local f="$WORK/key.$$" rc
  printf '%s\n' "$1" >"$f"
  ssh-keygen -l -f "$f" >/dev/null 2>&1 && rc=0 || rc=1
  rm -f "$f"
  return "$rc"
}

key_blob() { awk '{print $2}' <<<"$1"; }

# Trägt einen Schlüssel ein, ohne andere Schlüssel zu verlieren. Zeilen mit $3 (Kommentar eines alten
# Schlüssels) und dieselbe Schlüsselzeile werden vorher entfernt, dadurch wird ein alter Schlüssel ersetzt.
install_key() {
  local user="$1" key="$2" old_marker="${3:-}" home group file tmp blob
  if ((DRY_RUN)); then info "[dry-run] Schlüssel für $user eintragen${old_marker:+, alten ($old_marker) entfernen}"; return 0; fi
  home="$(getent passwd "$user" | cut -d: -f6)"
  group="$(id -gn "$user")"
  file="$home/.ssh/authorized_keys"
  install -d -m 700 -o "$user" -g "$group" "$home/.ssh"
  tmp="$(mktemp -p "$WORK")"
  blob="$(key_blob "$key")"
  if [[ -f $file ]]; then cp -- "$file" "$tmp"; else : >"$tmp"; fi
  grep -vF -- "$blob" "$tmp" >"$tmp.a" || true
  if [[ -n $old_marker ]]; then grep -vF -- "$old_marker" "$tmp.a" >"$tmp.new" || true; else cp -- "$tmp.a" "$tmp.new"; fi
  printf '%s\n' "$key" >>"$tmp.new"
  install -m 600 -o "$user" -g "$group" "$tmp.new" "$file"
  rm -f "$tmp" "$tmp.a" "$tmp.new"
}

# Block mit Markierung in eine Datei schreiben (ersetzt einen früheren Block derselben Art).
put_block() {
  local file="$1" name="$2" content="$3" tmp
  local start="# >>> vm-mint-install $name >>>" end="# <<< vm-mint-install $name <<<"
  if ((DRY_RUN)); then info "[dry-run] Block '$name' in $file schreiben"; return 0; fi
  [[ -f $file ]] || touch "$file"
  tmp="$(mktemp -p "$WORK")"
  awk -v s="$start" -v e="$end" '$0==s{skip=1} !skip{print} $0==e{skip=0}' "$file" >"$tmp"
  printf '%s\n%s\n%s\n' "$start" "$content" "$end" >>"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# --- Modul: Basis ----------------------------------------------------------------------------------
mod_base() {
  step "Basis: Pakete, Zeitzone, Hostname"
  run apt-get update -qq
  if ask_yn "Systempakete aktualisieren (apt upgrade)?" y; then
    if ((DRY_RUN)); then info "[dry-run] apt upgrade"; else env DEBIAN_FRONTEND=noninteractive apt-get -y -qq upgrade >/dev/null; fi
    ok "System aktualisiert"
  fi
  apt_install sudo curl wget git vim htop ca-certificates gnupg python3 openssh-client openssh-server
  ok "Basispakete installiert (inkl. sudo und python3 für Ansible)"
  done_note "Basispakete: sudo curl wget git vim htop python3 openssh"

  local tz; tz="$(ask_text "Zeitzone" "${TZ_NAME:-$DEFAULT_TZ}")"
  if [[ -n $tz ]]; then
    if run timedatectl set-timezone "$tz" 2>/dev/null; then ok "Zeitzone: $tz"; done_note "Zeitzone $tz"; else warn "Zeitzone '$tz' nicht gesetzt"; fi
  fi

  local current new; current="$(hostname 2>/dev/null || echo vm)"
  new="${NEW_HOSTNAME:-}"
  [[ -z $new ]] && new="$(ask_text "Hostname (Enter = '$current' behalten)" "")"
  if [[ -n $new && $new != "$current" ]]; then
    if [[ $new =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
      run hostnamectl set-hostname "$new"
      if ((!DRY_RUN)); then
        if grep -q '^127\.0\.1\.1' /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$new/" /etc/hosts; else printf '127.0.1.1\t%s\n' "$new" >>/etc/hosts; fi
      fi
      ok "Hostname: $new"; done_note "Hostname $new"
    else
      warn "Ungültiger Hostname (nur a-z, 0-9 und -), nicht geändert"
    fi
  fi

  if [[ "$(systemd-detect-virt 2>/dev/null || true)" =~ ^(kvm|qemu)$ ]] && ask_yn "QEMU Guest Agent installieren (Proxmox)?" y; then
    apt_install qemu-guest-agent
    run systemctl enable --now qemu-guest-agent 2>/dev/null || warn "Guest Agent installiert, startet erst mit aktiviertem Agent in der VM-Hardware"
    ok "QEMU Guest Agent"; done_note "QEMU Guest Agent"
  fi
}

# --- Modul: Prompt ---------------------------------------------------------------------------------
# Der Prompt-Block, wörtlich (Heredoc mit Anführungszeichen, keine Maskierung nötig).
prompt_block() {
  cat <<'EOF'
if [ -n "${PS1:-}" ]; then
  PS1='\n\[\e[94m\]\u\[\e[97m\]@\[\e[35m\]\h \n\[\e[36m\]\t \[\e[33m\]\w\[\e[0m\] \$ '
fi
EOF
}

mod_prompt() {
  step "Bash-Prompt"
  ask_yn "Farbigen Prompt (Benutzer@Host, Uhrzeit, Pfad) setzen?" y || return 0
  local block f
  block="$(prompt_block)"
  for f in /etc/bash.bashrc /root/.bashrc; do
    if ((!DRY_RUN)) && [[ -f $f ]]; then
      # Zeile des alten Skripts (export PS1=...) entfernen
      { grep -vF 'export PS1="\n\[\e[94m\]' "$f" || true; } >"$WORK/rc"
      cat "$WORK/rc" >"$f"
    fi
    put_block "$f" prompt "$block"
  done
  ok "Prompt gesetzt (wirkt ab der nächsten Anmeldung)"; done_note "Eigener Bash-Prompt"
}

# --- Modul: SSH ------------------------------------------------------------------------------------
fetch_github_keys() { curl -fsSL --max-time 15 "https://github.com/$1.keys" 2>/dev/null || true; }

mod_ssh() {
  step "SSH: Admin-Schlüssel und Absicherung"
  ensure_keygen
  local keys="" choice user
  if [[ -n ${ADMIN_PUBKEY:-} ]]; then
    keys="$ADMIN_PUBKEY"
  elif [[ -n ${ADMIN_GITHUB_USER:-} ]]; then
    keys="$(fetch_github_keys "$ADMIN_GITHUB_USER")"
  elif ((!ASSUME_YES)); then
    info "Wie soll dein Admin-Schlüssel für root auf diese VM kommen?"
    info "  1) von GitHub laden (https://github.com/<benutzer>.keys)"
    info "  2) Public Key einfügen"
    info "  3) überspringen"
    choice="$(ask_text "Auswahl" "1")"
    case "$choice" in
      1) user="$(ask_text "GitHub-Benutzername" "hyydroo")"; keys="$(fetch_github_keys "$user")"
         [[ -z $keys ]] && warn "Keine Schlüssel bei GitHub für '$user' gefunden" ;;
      2) keys="$(ask_text "Public Key (eine Zeile, ssh-ed25519 ...)" "")" ;;
      *) : ;;
    esac
  fi

  local count=0 line
  while IFS= read -r line; do
    [[ -z $line ]] && continue
    if valid_pubkey "$line"; then
      install_key root "$line"
      count=$((count + 1))
    else
      warn "Ungültige Schlüsselzeile übersprungen"
    fi
  done <<<"$keys"
  if ((count > 0)); then
    ADMIN_KEY_INSTALLED=1
    ok "$count Admin-Schlüssel für root eingetragen (bestehende bleiben erhalten)"
    done_note "Admin-Schlüssel für root ($count)"
  else
    warn "Kein Admin-Schlüssel eingetragen, SSH-Absicherung wird deshalb übersprungen"
    return 0
  fi

  local pw_off=n root_key=y
  if ask_yn "Passwort-Anmeldung per SSH abschalten (nur Schlüssel)?" y; then pw_off=y; fi
  if ! ask_yn "root nur mit Schlüssel anmelden lassen (kein Passwort für root)?" y; then root_key=n; fi
  local conf="/etc/ssh/sshd_config.d/01-vm-mint.conf"
  if ((DRY_RUN)); then
    info "[dry-run] $conf schreiben (Passwort aus: $pw_off, root nur Key: $root_key), sshd neu laden"
  else
    install -d -m 755 /etc/ssh/sshd_config.d
    grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    {
      echo "# von vm-mint-install; die erste Angabe gewinnt, deshalb Dateiname 01-"
      if [[ $pw_off == y ]]; then echo "PasswordAuthentication no"; fi
      if [[ $root_key == y ]]; then echo "PermitRootLogin prohibit-password"; else echo "PermitRootLogin yes"; fi
    } >"$conf"
    if sshd -t 2>/dev/null; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || warn "sshd konnte nicht neu geladen werden"
      ok "sshd abgesichert ($conf)"
    else
      rm -f "$conf"
      warn "sshd-Konfiguration ungültig, Änderung zurückgenommen"
      return 0
    fi
  fi
  done_note "sshd: Passwort-Login aus=$pw_off, root nur Key=$root_key"
  warn "Teste die Key-Anmeldung in einem zweiten Terminal, bevor du diese Sitzung schließt."
}

# --- Modul: Ansible-Benutzer -----------------------------------------------------------------------
mod_ansible() {
  step "Ansible-Benutzer"
  ask_yn "Benutzer '$ANSIBLE_USER' mit Schlüssel und sudo einrichten?" y || return 0
  ensure_keygen
  valid_pubkey "$ANSIBLE_PUBKEY" || die "ANSIBLE_PUBKEY ist kein gültiger öffentlicher Schlüssel"
  apt_install python3 sudo
  if ((DRY_RUN)); then
    info "[dry-run] Benutzer $ANSIBLE_USER anlegen, neuen Schlüssel eintragen, alten ($OLD_ANSIBLE_KEY_MARKER) entfernen, sudoers"
  else
    id "$ANSIBLE_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ANSIBLE_USER"
    install_key "$ANSIBLE_USER" "$ANSIBLE_PUBKEY" "$OLD_ANSIBLE_KEY_MARKER"
    local tmp="$WORK/sudoers"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ANSIBLE_USER" >"$tmp"
    visudo -cf "$tmp" >/dev/null || die "sudoers-Datei ungültig"
    install -m 440 "$tmp" "/etc/sudoers.d/$ANSIBLE_USER"
  fi
  ok "Benutzer $ANSIBLE_USER bereit, alter Schlüssel ersetzt, sudo ohne Passwort"
  done_note "Ansible-Benutzer mit neuem Schlüssel (ed25519), alter Schlüssel entfernt"
}

# --- Modul: Docker ---------------------------------------------------------------------------------
mod_docker() {
  step "Docker"
  ask_yn "Docker (offizielles Repository) mit Compose-Plugin installieren?" y || return 0
  local os_id="" codename="" like=""
  if ((DRY_RUN)); then
    info "[dry-run] Docker-Repository einrichten"
  else
    [[ -f /etc/os-release ]] || die "/etc/os-release fehlt"
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
    codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    if [[ $os_id != debian && $os_id != ubuntu ]]; then
      if [[ $like == *ubuntu* ]]; then os_id=ubuntu; codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$codename}")"
      elif [[ $like == *debian* ]]; then os_id=debian
      else die "Nur Debian und Ubuntu werden unterstützt (gefunden: $os_id)"; fi
    fi
    [[ -n $codename ]] || die "Codename des Systems nicht erkannt"
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.sources
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$os_id/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/$os_id
Suites: $codename
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -qq
  fi
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run systemctl enable --now docker

  if ((!DRY_RUN)) && [[ ! -f /etc/docker/daemon.json ]] && ask_yn "Docker-Logs begrenzen (10 MB, 3 Dateien pro Container)?" y; then
    install -d -m 755 /etc/docker
    printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' >/etc/docker/daemon.json
    systemctl restart docker
    ok "Log-Rotation aktiv"
  fi

  local duser="${DOCKER_USER:-${SUDO_USER:-}}"
  [[ -z $duser ]] && duser="$(ask_text "Benutzer für die Gruppe 'docker' (leer = keiner)" "")"
  if [[ -n $duser && $duser != root ]] && id "$duser" >/dev/null 2>&1; then
    run usermod -aG docker "$duser"
    ok "$duser ist in der Gruppe docker (neu anmelden)"
  fi
  ok "Docker installiert"
  done_note "Docker CE mit Compose-Plugin"
}

# --- Modul: automatische Sicherheitsupdates --------------------------------------------------------
mod_updates() {
  step "Automatische Sicherheitsupdates"
  ask_yn "Sicherheitsupdates automatisch installieren (unattended-upgrades)?" y || return 0
  apt_install unattended-upgrades
  if ((!DRY_RUN)); then
    printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >/etc/apt/apt.conf.d/20auto-upgrades
  fi
  ok "Sicherheitsupdates aktiv (kein automatischer Neustart)"; done_note "unattended-upgrades"
}

# --- Aufräumen -------------------------------------------------------------------------------------
cleanup() {
  local rc=$?
  if [[ -n $WORK ]]; then rm -rf "$WORK" 2>/dev/null || true; WORK=""; fi
  if ((SELF_DELETE)) && [[ -n $SELF_FILE ]]; then rm -f -- "$SELF_FILE" 2>/dev/null || true; SELF_FILE=""; fi
  return "$rc"
}
on_error() { printf '%s✗ Abbruch in Zeile %s (Befehl: %s)%s\n' "$C_RED" "$1" "$2" "$C_RESET" >&2; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

# --- Hauptprogramm ---------------------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --skip=*) SKIP=",${arg#--skip=}," ;;
      --version|-V) printf '%s
' "$SCRIPT_VERSION"; exit 0 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unbekannte Option: $arg (siehe --help)" ;;
    esac
  done

  WORK="$(mktemp -d /tmp/vm-mint.XXXXXX)"
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n $src && -f $src && $src != /dev/* && $src != /proc/* ]]; then SELF_FILE="$(readlink -f -- "$src")"; fi

  printf '%s\n  vm-mint-install %s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
  if ((DRY_RUN)); then
    warn "Trockenlauf: es wird nichts verändert."
  else
    [[ $EUID -eq 0 ]] || die "Bitte als root ausführen (su - oder sudo -i)."
    { [[ -r /etc/os-release ]] && grep -qiE 'debian|ubuntu' /etc/os-release; } || die "Nur Debian und Ubuntu werden unterstützt."
    if ((!ASSUME_YES)) && [[ ! -r /dev/tty ]]; then die "Kein Terminal für die Fragen. Mit --yes ohne Fragen ausführen."; fi
    export DEBIAN_FRONTEND=noninteractive
    info "System: $(. /etc/os-release && echo "${PRETTY_NAME:-unbekannt}")"
  fi

  # if-Form, damit "set -e" auch innerhalb der Module wirkt
  if ! skipped base; then mod_base; fi
  if ! skipped prompt; then mod_prompt; fi
  if ! skipped ssh; then mod_ssh; fi
  if ! skipped ansible; then mod_ansible; fi
  if ! skipped docker; then mod_docker; fi
  if ! skipped updates; then mod_updates; fi

  step "Aufräumen"
  if ((!DRY_RUN)); then
    apt-get -y -qq autoremove >/dev/null 2>&1 || true
    apt-get -qq clean || true
  fi
  ok "Paket-Cache geleert, Arbeitsordner wird gelöscht"
  if [[ -n $SELF_FILE ]]; then
    if ((DRY_RUN)); then
      info "[dry-run] Skript $SELF_FILE würde auf Wunsch gelöscht"
    elif [[ -d "$(dirname "$SELF_FILE")/.git" ]]; then
      info "Skript liegt in einem Git-Ordner und bleibt erhalten ($SELF_FILE)."
    elif ask_yn "Dieses Skript ($SELF_FILE) jetzt von der VM löschen?" y; then
      SELF_DELETE=1; ok "Skript wird beim Beenden gelöscht"
    fi
  else
    ok "Es liegt keine Skriptdatei auf der VM (direkt aus dem Netz gestartet)"
  fi

  step "Zusammenfassung"
  local item
  for item in "${SUMMARY[@]}"; do ok "$item"; done
  if ((ADMIN_KEY_INSTALLED)); then info "Anmelden: ssh root@<VM> mit deinem Admin-Schlüssel."; fi
  info "Ansible/Orchestrator erreicht die VM als '$ANSIBLE_USER' mit dem Schlüssel '${ANSIBLE_PUBKEY##* }'."

  if ((!DRY_RUN)) && ask_yn "VM jetzt neu starten?" n; then
    info "Neustart ..."
    cleanup
    reboot
  fi
}

main "$@"
