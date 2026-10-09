# vm-mint-install

Interaktive Ersteinrichtung für frische **Debian**- und **Ubuntu**-VMs. Ein einziges Skript, ein Befehl, nach dem
Durchlauf bleibt nichts davon auf der VM zurück.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hyydroo/vm-mint-install/main/install.sh)"
```

Als `root` ausführen (`su -` oder `sudo -i`). Das Skript fragt Schritt für Schritt, jede Frage hat einen sinnvollen
Standard (Enter = Ja bzw. der angezeigte Wert).

## Was es einrichtet

| Modul | Was passiert |
|---|---|
| **base** | `apt update`/`upgrade`, Basispakete (`sudo curl wget git vim htop python3 openssh`), Zeitzone (Standard `Europe/Berlin`), Hostname, QEMU Guest Agent (nur auf KVM/Proxmox) |
| **prompt** | Farbiger Bash-Prompt (Benutzer@Host, Uhrzeit, Pfad) für alle Benutzer und root, als markierter Block in `/etc/bash.bashrc` und `/root/.bashrc` (läuft beliebig oft, ersetzt sich selbst) |
| **ssh** | Admin-Schlüssel für root von GitHub (`github.com/<benutzer>.keys`) oder eingefügt, optional Passwort-Login aus und root nur mit Schlüssel. Konfiguration als Drop-in `/etc/ssh/sshd_config.d/01-vm-mint.conf`, vor dem Laden mit `sshd -t` geprüft |
| **ansible** | Benutzer `ansible` mit Python 3, sudo ohne Passwort und dem **neuen** Ansible-Schlüssel (ed25519). Der alte Schlüssel (`ansible@svc-hy-ansible`) wird entfernt, andere Schlüssel in `authorized_keys` bleiben erhalten |
| **docker** | Docker CE aus dem offiziellen Repository mit Compose- und Buildx-Plugin, optional Log-Rotation (10 MB, 3 Dateien) und Benutzer in der Gruppe `docker` |
| **updates** | Automatische Sicherheitsupdates (`unattended-upgrades`, ohne automatischen Neustart) |

## Keine Überreste

- Das Skript ist **eine Datei** und läuft direkt aus dem Netz, es wird nichts heruntergeladen und abgelegt.
- Der Arbeitsordner in `/tmp` wird am Ende (auch bei einem Fehler) gelöscht, der Paket-Cache geleert.
- Wurde das Skript als Datei gestartet, bietet es am Ende an, sich selbst zu löschen (nicht in einem Git-Ordner).
- Das Einzige, was bleibt, sind die gewünschten Einstellungen und Pakete.

## Optionen

```text
--yes          alle Fragen mit dem Standard beantworten (für viele VMs ohne Rückfragen)
--skip=a,b     Module überspringen: base, prompt, ssh, ansible, docker, updates
--dry-run      nur anzeigen, was passieren würde (ändert nichts, braucht kein root)
--version, --help
```

Umgebungsvariablen (vor allem mit `--yes`):

| Variable | Bedeutung |
|---|---|
| `ADMIN_GITHUB_USER` | GitHub-Benutzer, dessen öffentliche Schlüssel für root eingetragen werden |
| `ADMIN_PUBKEY` | Alternativ ein einzelner Public Key (eine Zeile) |
| `NEW_HOSTNAME` | Hostname der VM |
| `TZ_NAME` | Zeitzone, Standard `Europe/Berlin` |
| `ANSIBLE_PUBKEY` | Überschreibt den eingebauten Ansible-Schlüssel |
| `DOCKER_USER` | Benutzer für die Gruppe `docker` |

Beispiel ohne Rückfragen:

```bash
ADMIN_GITHUB_USER=meinbenutzer NEW_HOSTNAME=srv-test-01 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/hyydroo/vm-mint-install/main/install.sh)" -- --yes
```

## Den Ansible-Schlüssel wechseln

Der öffentliche Schlüssel steht oben in `install.sh` (`ANSIBLE_PUBKEY`), der Kommentar des alten Schlüssels in
`OLD_ANSIBLE_KEY_MARKER`. Beide anpassen, das Modul `ansible` auf bestehenden VMs erneut laufen lassen
(`--skip=base,prompt,ssh,docker,updates`): Der alte Schlüssel verschwindet, der neue wird eingetragen. Der private
Schlüssel gehört nur auf den Ansible-Server und nie in dieses Repository.

## Hinweise zur Sicherheit

- Der Benutzer `ansible` bekommt `NOPASSWD:ALL` in `/etc/sudoers.d/ansible`. Das ist für Ansible üblich, setzt aber
  voraus, dass der private Schlüssel gut geschützt ist.
- Die Passwort-Anmeldung per SSH wird nur abgeschaltet, wenn mindestens ein Admin-Schlüssel eingetragen wurde.
  **Teste die Schlüssel-Anmeldung in einem zweiten Terminal, bevor du die Sitzung schließt.**
- Öffentliche Schlüssel in diesem Repository sind unkritisch. Private Schlüssel und Passwörter gehören nie hinein.

## Entwicklung

`bash -n install.sh` und `shellcheck install.sh` laufen in der CI. Mit `--dry-run` lässt sich der Ablauf ohne root und
ohne Änderungen durchspielen.

Lizenz: MIT
