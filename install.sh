#!/usr/bin/env bash
# vm-mint-install - interaktive Ersteinrichtung frischer Debian-/Ubuntu-VMs.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/hyydroo/vm-mint-install/main/install.sh)"
#
# Alles steckt in dieser einen Datei. Temporäre Dateien liegen in einem Arbeitsordner, der am Ende
# gelöscht wird; eine heruntergeladene Kopie des Skripts löscht sich auf Wunsch selbst.
#
# Optionen:  --yes             alle Fragen mit dem Standard beantworten (für Automatisierung)
#            --only=a,b        nur diese Module ausführen: base, prompt, ssh, ansible, docker, updates
#            --skip=a,b        diese Module überspringen
#            --dry-run         nur anzeigen, was passieren würde (ändert nichts, braucht kein root)
#            --version, --help
# Ohne --only/--skip fragt das Skript am Anfang: alles durchlaufen oder einzelne Punkte wählen.
# Umgebungsvariablen (vor allem mit --yes): ADMIN_GITHUB_USER, ADMIN_PUBKEY, NEW_HOSTNAME, TZ_NAME,
#            ANSIBLE_PUBKEY, ANSIBLE_REPLACE_COMMENT, DOCKER_USER

set -Eeuo pipefail

# Unter "su" (ohne "-") fehlt /usr/sbin im Pfad (useradd, visudo, sshd ...).
export PATH="$PATH:/usr/sbin:/sbin"

SCRIPT_VERSION="1.3.2"

# --- Einstellungen ---------------------------------------------------------------------------------
# Öffentlicher Schlüssel des Ansible-Servers; leer = das Skript fragt im Modul "ansible" danach.
ANSIBLE_PUBKEY="${ANSIBLE_PUBKEY:-}"
# Kommentar eines alten Schlüssels, der aus authorized_keys des Ansible-Benutzers entfernt und durch den neuen
# ersetzt wird (leer = nichts entfernen).
OLD_ANSIBLE_KEY_MARKER="${ANSIBLE_REPLACE_COMMENT:-}"
ANSIBLE_USER="ansible"
DEFAULT_TZ="Europe/Berlin"
# Verschlüsselter persönlicher Block (nur öffentliche Schlüssel), wird mit der versteckten Option geöffnet.
PERSONAL_BLOB="U2FsdGVkX1+NUNHvIHYlC6G0+NrwOYO9GnqfUmqZ+h0Kg8zJlwU5f2MV+/UnaBR7kWutIU15cRoG4UYiPR89YDaqEoN3aLRMZXSa5xvH5HUVSmlbSnrkECbNKu7c2uzPPg2tva5jxVj+SUTXdSsiCXqrg3PRkAEwi8cpO/PAUE8dM2MhZi3QiaViXPrbxCEQXYY5y3vq9eQINBobUBVysDpcnUoyo53CmYgHcbgkQZShaQH5XRq8hyGP4AlQBjsv8YomUL1c9xgDrLSjKAltvGUmbG3YvoyUCOKQtr5L23QdYkJSN2Bzo/pntxp1oltVtoLE7r1W8c9m64ZFp++XVU6c1/m3Dy0FFAQDdco6+nD59z7H42XuLSxeHge5EacYrn/A1schYhQYvo/gBu5oyaPL4RXF6C0dI6GZsXyT1iqid8R66yoKBO8rAPWgIz8aENVxsMAYRr9TbJbCgD1Fi+T4LdENFnAYJpUbP7ADwks/LDQgSg0k4rUmhBrgG8ULA6mEMT1rWU+XyRseT0OgcU22/CHWpKSGuWUQ9vw1o98ZfD0AkF/AoRB69cFxSvNP3FLKbBlYL6FPcvW2kAW3H13B7j3Tp7atKh2TIhDPgFkDrZ9GFdcTknM06CXkBtddo29kw/piM3Bu6r4NLwtgwLWr/o5gx92WapaLzOhmUgwB8JKmA+n7KJbzNTQOtfl9wEjl1J6SfP0oNKJ1oc9CJKQPyS3ayl1Scq0DYJxnGm8pc0dJpgya+uQ1sMcbTjL+GS0Ge5gocaaOu4ysG9z4hQmfUQmbM2hCSg1bfsl70TKwXlcjws4smYayEf70OX7rtaK0/IDftBXQuEGhMPAOxaFlWPTmTNlskJmf1deXib6gSJFEOHqIoD8CxZDHt7fM7OrBGZXmQWSvnNbgYldwhFfEwLhz48asGXRc6lqPWVGt04mKC+I2tYk4hOw3rwPMhwFv4eiummsIHzE0K8SaajAetkQHIBhX+tmAeaJOQgXnOiBKGQbSMMEATfWYn+jZiCohPpuv5430RsrJ3bFEbUnyr1jQL7mf/zCC+QC26cqsQJLA3YAWk7zwZxYDYu9NnKOC3/DzGTKwDDSzJsF16WzloW5iQvs7j2bL9+4dbBzaELC4rYSLh1MtPwiE/uTqRCD/ZtJhynORWAudXdOvVraFTE2Eps3EqNsqGi3khDZwOBt9tVSFz81Kc5JmsrtAFCZX8C7n6+eEGmFU3plwq1JmQV5lm/UYw1Ni2kjNojY="

# --- Zustand ---------------------------------------------------------------------------------------
ASSUME_YES=0
DRY_RUN=0
SKIP=","
ONLY=""
PERSONAL=0
SEAL=0
SELECTION_GIVEN=0
APT_UPDATED=0
MODULE_IDS=(base prompt ssh ansible docker updates)
MODULE_LABELS=(
  "Basis: Pakete, Zeitzone, Hostname"
  "Bash-Prompt"
  "SSH: Admin-Schlüssel für root und Absicherung"
  "Ansible-Benutzer mit Schlüssel"
  "Docker"
  "Automatische Sicherheitsupdates"
)
SUMMARY=()
ADMIN_KEY_INSTALLED=0
ANSIBLE_DONE=0
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

apt_update_once() {
  ((APT_UPDATED)) && return 0
  APT_UPDATED=1
  run apt-get update -qq
}

apt_install() {
  if ((DRY_RUN)); then info "[dry-run] apt install $*"; return 0; fi
  apt_update_once
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

# --- Persönlicher Block (versteckte Optionen --personal / --seal) ----------------------------------
PERSONAL_CIPHER=(openssl enc -aes-256-cbc -pbkdf2 -iter 200000)

# Verschlüsselt Schlüssel mit einem Passwort und gibt den Block zum Eintragen in PERSONAL_BLOB aus.
seal_personal() {
  command -v openssl >/dev/null 2>&1 || die "openssl fehlt"
  local root ansible marker pw pw2 plain default_pub=""
  [[ -r $HOME/.ssh/orchestrator_ed25519.pub ]] && default_pub="$(cat "$HOME/.ssh/orchestrator_ed25519.pub")"
  root="${ROOT_KEY:-$(ask_text "Root-Admin-Schlüssel (Public Key einfügen)" "")}"
  ansible="${ANSIBLE_KEY:-$(ask_text "Ansible-Schlüssel (Public Key)" "$default_pub")}"
  marker="${REPLACE_COMMENT:-$(ask_text "Kommentar des alten Ansible-Schlüssels (wird ersetzt)" "ansible@svc-hy-ansible")}"
  ensure_keygen
  [[ -z $root ]] || valid_pubkey "$root" || die "Root-Schlüssel ist ungültig"
  [[ -z $ansible ]] || valid_pubkey "$ansible" || die "Ansible-Schlüssel ist ungültig"
  read -r -s -p "  Passwort für den Block: " pw </dev/tty; printf '\n'
  read -r -s -p "  Passwort wiederholen:   " pw2 </dev/tty; printf '\n'
  [[ -n $pw && $pw == "$pw2" ]] || die "Passwörter leer oder verschieden"
  plain="$(printf 'ROOT_KEY=%s\nANSIBLE_KEY=%s\nREPLACE_COMMENT=%s\n' "$root" "$ansible" "$marker")"
  printf '\nPERSONAL_BLOB="%s"\n' "$(PW="$pw" "${PERSONAL_CIPHER[@]}" -salt -a -A -pass env:PW <<<"$plain")"
}

# Öffnet den Block mit dem Passwort und setzt ADMIN_PUBKEY, ANSIBLE_PUBKEY und OLD_ANSIBLE_KEY_MARKER.
personal_load() {
  [[ -n $PERSONAL_BLOB ]] || die "In diesem Skript ist kein persönlicher Block hinterlegt."
  command -v openssl >/dev/null 2>&1 || apt_install openssl
  local pw="${PERSONAL_PASS:-}" plain="" try line
  for try in 1 2 3; do
    if [[ -z $pw ]]; then read -r -s -p "  Passwort: " pw </dev/tty; printf '\n'; fi
    if plain="$(PW="$pw" "${PERSONAL_CIPHER[@]}" -d -a -A -pass env:PW <<<"$PERSONAL_BLOB" 2>/dev/null)" && [[ -n $plain ]]; then break; fi
    plain=""; pw=""; warn "Falsches Passwort ($try/3)"
  done
  [[ -n $plain ]] || die "Persönlicher Block konnte nicht geöffnet werden."
  while IFS= read -r line; do
    case "${line%%=*}" in
      ROOT_KEY) ADMIN_PUBKEY="${line#*=}" ;;
      ANSIBLE_KEY) ANSIBLE_PUBKEY="${line#*=}" ;;
      REPLACE_COMMENT) OLD_ANSIBLE_KEY_MARKER="${line#*=}" ;;
    esac
  done <<<"$plain"
  ok "Persönlicher Block geöffnet"
}

# Zeichnet aus den Statuszeilen von apt (stdin) einen Fortschrittsbalken. Format: art:paket:prozent:text
apt_draw_bar() {
  local line kind pkg pct label filled bar rest width=30
  while IFS= read -r line; do
    IFS=: read -r kind pkg pct _ <<<"$line"
    case "$kind" in
      pmconffile|pmerror) printf '\n' ;;   # dpkg fragt gleich nach / meldet einen Fehler: Balkenzeile verlassen
      dlstatus|pmstatus)
        pct="${pct%%.*}"
        [[ $pct =~ ^[0-9]+$ ]] || continue
        if [[ $kind == dlstatus ]]; then label="Download    "; else label="Installation"; fi
        filled=$((pct * width / 100))
        printf -v bar '%*s' "$filled" ''; bar="${bar// /█}"
        printf -v rest '%*s' "$((width - filled))" ''; rest="${rest// /░}"
        printf '\r  %s %s%s%s %3d%%' "$label" "$C_GREEN" "$bar$rest" "$C_RESET" "$pct"
        ;;
    esac
  done
  printf '\r\033[K'
}

# apt-get upgrade mit Fortschrittsbalken. Ein-/Ausgabe bleiben am Terminal, damit dpkg bei geänderten
# Konfigurationsdateien nachfragen kann (Behalten/Ersetzen); der Balken kommt über einen eigenen Deskriptor.
apt_upgrade_progress() {
  local -a opts=(-y -qq)
  local rc=0
  if [[ ! -t 1 || ! -r /dev/tty ]]; then
    info "Systempakete werden aktualisiert ..."
    env DEBIAN_FRONTEND=noninteractive apt-get "${opts[@]}" -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade >/dev/null || rc=$?
  else
    info "Hinweis: Fragt dpkg nach einer geänderten Konfigurationsdatei, hier antworten (N = alte behalten, Standard)."
    env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get "${opts[@]}" -o APT::Status-Fd=3 upgrade 3> >(apt_draw_bar) || rc=$?
    sleep 0.3   # dem Balken-Prozess Zeit zum Aufräumen geben
  fi
  ((rc == 0)) || { warn "apt upgrade meldete Fehler (Code $rc), mache mit den Basispaketen weiter"; return 0; }
}

# --- Modul: Basis ----------------------------------------------------------------------------------
mod_base() {
  step "Basis: Pakete, Zeitzone, Hostname"
  apt_update_once
  if ask_yn "Systempakete aktualisieren (apt upgrade)?" y; then
    if ((DRY_RUN)); then info "[dry-run] apt upgrade"; else apt_upgrade_progress; fi
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
  [[ -x /usr/sbin/sshd ]] || apt_install openssh-server
  local keys="" choice user
  if [[ -n ${ADMIN_PUBKEY:-} ]]; then
    keys="$ADMIN_PUBKEY"
  elif [[ -n ${ADMIN_GITHUB_USER:-} ]]; then
    keys="$(fetch_github_keys "$ADMIN_GITHUB_USER")"
  elif ((!ASSUME_YES)); then
    info "Welcher Schlüssel soll für root auf diese VM?"
    info "  1) von GitHub laden (https://github.com/<benutzer>.keys)"
    info "  2) Public Key einfügen"
    info "  3) überspringen"
    choice="$(ask_text "Auswahl" "1")"
    case "$choice" in
      1) user="$(ask_text "GitHub-Benutzername" "")"
         if [[ -n $user ]]; then keys="$(fetch_github_keys "$user")"; [[ -z $keys ]] && warn "Keine Schlüssel bei GitHub für '$user' gefunden"; fi ;;
      2) keys="$(ask_text "Public Key (eine Zeile, ssh-ed25519 ...)" "")" ;;
      *) : ;;
    esac
  else
    warn "Mit --yes braucht das SSH-Modul ADMIN_PUBKEY oder ADMIN_GITHUB_USER, übersprungen"
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

  local pw_off=n root_key=n
  if ask_yn "Passwort-Anmeldung per SSH abschalten (nur Schlüssel)?" y; then pw_off=y; fi
  if ! ask_yn "root nur mit Schlüssel anmelden lassen (kein Passwort für root)?" n; then root_key=n; else root_key=y; fi
  local conf="/etc/ssh/sshd_config.d/01-vm-mint.conf"
  if ((DRY_RUN)); then
    info "[dry-run] $conf schreiben (Passwort aus: $pw_off, root nur Key: $root_key), sshd neu laden"
  else
    install -d -m 755 /etc/ssh/sshd_config.d
    grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    {
      echo "# von vm-mint-install; die erste Angabe gewinnt, deshalb Dateiname 01-"
      if [[ $pw_off == y ]]; then echo "PasswordAuthentication no"; fi
      if [[ $root_key == y ]]; then
        echo "PermitRootLogin prohibit-password"
      else
        echo "PermitRootLogin yes"
        # Passwort für root bleibt erlaubt, auch wenn es für alle anderen Benutzer abgeschaltet ist
        # (Match-Block muss am Ende der Datei stehen).
        if [[ $pw_off == y ]]; then printf 'Match User root\n    PasswordAuthentication yes\n'; fi
      fi
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
  if [[ -z $ANSIBLE_PUBKEY ]]; then
    if ((ASSUME_YES)); then warn "Mit --yes braucht das Modul ANSIBLE_PUBKEY, übersprungen"; return 0; fi
    ANSIBLE_PUBKEY="$(ask_text "Public Key des Ansible-Servers (Enter = überspringen)" "")"
    [[ -n $ANSIBLE_PUBKEY ]] || { warn "Kein Schlüssel angegeben, Modul übersprungen"; return 0; }
    if [[ -z $OLD_ANSIBLE_KEY_MARKER ]]; then
      OLD_ANSIBLE_KEY_MARKER="$(ask_text "Kommentar eines alten Schlüssels, der ersetzt werden soll (Enter = keiner)" "")"
    fi
  fi
  valid_pubkey "$ANSIBLE_PUBKEY" || die "ANSIBLE_PUBKEY ist kein gültiger öffentlicher Schlüssel"
  apt_install python3 sudo
  if ((DRY_RUN)); then
    info "[dry-run] Benutzer $ANSIBLE_USER anlegen, Schlüssel eintragen${OLD_ANSIBLE_KEY_MARKER:+, Schlüssel mit Kommentar $OLD_ANSIBLE_KEY_MARKER ersetzen}, sudoers"
  else
    id "$ANSIBLE_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ANSIBLE_USER"
    install_key "$ANSIBLE_USER" "$ANSIBLE_PUBKEY" "$OLD_ANSIBLE_KEY_MARKER"
    local tmp="$WORK/sudoers"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ANSIBLE_USER" >"$tmp"
    visudo -cf "$tmp" >/dev/null || die "sudoers-Datei ungültig"
    install -m 440 "$tmp" "/etc/sudoers.d/$ANSIBLE_USER"
  fi
  ok "Benutzer $ANSIBLE_USER bereit, Schlüssel eingetragen, sudo ohne Passwort"
  ANSIBLE_DONE=1
  done_note "Ansible-Benutzer mit Schlüssel (${ANSIBLE_PUBKEY##* })"
}

# --- Modul: Docker ---------------------------------------------------------------------------------
mod_docker() {
  step "Docker"
  ask_yn "Docker (offizielles Repository) mit Compose-Plugin installieren?" n || return 0
  apt_install ca-certificates curl gnupg
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
  local conf="/etc/apt/apt.conf.d/20auto-upgrades"
  # Zweiter Durchlauf: war es von diesem Skript aktiviert, lässt es sich hier wieder abschalten.
  if [[ -f $conf ]] && grep -q "vm-mint-install" "$conf" 2>/dev/null; then
    info "Sicherheitsupdates sind aktiv (von diesem Skript eingerichtet)."
    if ask_yn "Jetzt deaktivieren und entfernen?" n; then
      if ((DRY_RUN)); then
        info "[dry-run] $conf löschen, unattended-upgrades entfernen"
      else
        rm -f "$conf"
        env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq unattended-upgrades >/dev/null
      fi
      ok "Automatische Sicherheitsupdates deaktiviert und entfernt"; done_note "unattended-upgrades entfernt"
    fi
    return 0
  fi
  ask_yn "Sicherheitsupdates automatisch installieren (unattended-upgrades)?" n || return 0
  apt_install unattended-upgrades
  if ((!DRY_RUN)); then
    printf '// von vm-mint-install; rückgängig: Skript erneut mit --only=updates starten\nAPT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >"$conf"
  fi
  ok "Sicherheitsupdates aktiv (kein automatischer Neustart). Rückgängig: Skript erneut starten (Modul updates)"
  done_note "unattended-upgrades"
}

# --- Modulauswahl ----------------------------------------------------------------------------------
module_known() { local id; for id in "${MODULE_IDS[@]}"; do [[ $id == "$1" ]] && return 0; done; return 1; }

# --only=a,b -> alles andere überspringen
apply_only() {
  local id name picked=","
  for name in ${ONLY//,/ }; do
    module_known "$name" || die "Unbekanntes Modul: $name (erlaubt: ${MODULE_IDS[*]})"
    picked+="$name,"
  done
  SKIP=","
  for id in "${MODULE_IDS[@]}"; do [[ $picked == *",$id,"* ]] || SKIP+="$id,"; done
}

# Startmenü: alles oder einzelne Punkte
choose_modules() {
  local reply n i picked=","
  printf '\n%sWas soll eingerichtet werden?%s\n' "$C_BOLD" "$C_RESET"
  info "  1) Alles durchlaufen (empfohlen)"
  info "  2) Einzelne Punkte auswählen"
  reply="$(ask_text "Auswahl" "1")"
  [[ $reply == 2 ]] || return 0
  printf '\n'
  for i in "${!MODULE_IDS[@]}"; do info "  $((i + 1))) ${MODULE_LABELS[$i]}"; done
  reply="$(ask_text "Nummern mit Leerzeichen getrennt (z. B. 1 3 5)" "")"
  for n in ${reply//,/ }; do
    if [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#MODULE_IDS[@]})); then picked+="${MODULE_IDS[$((n - 1))]},"; else warn "Ungültige Nummer übersprungen: $n"; fi
  done
  [[ $picked != "," ]] || die "Nichts ausgewählt."
  SKIP=","
  for i in "${MODULE_IDS[@]}"; do [[ $picked == *",$i,"* ]] || SKIP+="$i,"; done
}

# --- Aufräumen -------------------------------------------------------------------------------------
cleanup() {
  local rc=$?
  if [[ -n $WORK ]]; then rm -rf "$WORK" 2>/dev/null || true; WORK=""; fi
  if ((SELF_DELETE)) && [[ -n $SELF_FILE ]]; then rm -f -- "$SELF_FILE" 2>/dev/null || true; SELF_FILE=""; fi
  return "$rc"
}
on_error() {
  [[ $2 == exit* ]] && return 0 # bewusste Abbrüche über die()
  printf '%s✗ Abbruch in Zeile %s (Befehl: %s)%s\n' "$C_RED" "$1" "$2" "$C_RESET" >&2; }
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

# --- Hauptprogramm ---------------------------------------------------------------------------------
main() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --yes|-y) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --personal) PERSONAL=1 ;;
      --seal) SEAL=1 ;;
      --only=*) ONLY="${arg#--only=}"; SELECTION_GIVEN=1 ;;
      --skip=*) SKIP=",${arg#--skip=},"; SELECTION_GIVEN=1 ;;
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
  if ((SEAL)); then seal_personal; exit 0; fi
  if ((DRY_RUN)); then
    warn "Trockenlauf: es wird nichts verändert."
  else
    [[ $EUID -eq 0 ]] || die "Bitte als root ausführen (su - oder sudo -i)."
    { [[ -r /etc/os-release ]] && grep -qiE 'debian|ubuntu' /etc/os-release; } || die "Nur Debian und Ubuntu werden unterstützt."
    if ((!ASSUME_YES)) && [[ ! -r /dev/tty ]]; then die "Kein Terminal für die Fragen. Mit --yes ohne Fragen ausführen."; fi
    export DEBIAN_FRONTEND=noninteractive
    info "System: $(. /etc/os-release && echo "${PRETTY_NAME:-unbekannt}")"
  fi

  if ((PERSONAL)); then personal_load; fi

  if [[ -n $ONLY ]]; then apply_only; elif ((!SELECTION_GIVEN && !ASSUME_YES)); then choose_modules; fi

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
  if ((ANSIBLE_DONE)); then info "Ansible erreicht die VM als '$ANSIBLE_USER' mit dem Schlüssel '${ANSIBLE_PUBKEY##* }'."; fi

  if ((!DRY_RUN)) && ask_yn "VM jetzt neu starten?" n; then
    info "Neustart ..."
    cleanup
    reboot
  fi
}

main "$@"
