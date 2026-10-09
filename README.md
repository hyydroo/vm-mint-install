# vm-mint-install

Interaktive Ersteinrichtung für frische **Debian**- und **Ubuntu**-VMs. Ein einziges Skript, ein Befehl, nach dem
Durchlauf bleibt nichts davon auf der VM zurück.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/hyydroo/vm-mint-install/main/install.sh)"
```

Als `root` ausführen (`su -` oder `sudo -i`). Zuerst fragt das Skript, ob es **alles durchlaufen** soll oder ob du
**einzelne Punkte** auswählst (Nummern wie `1 3 5`). Danach geht es Schritt für Schritt; jede Frage hat einen sinnvollen
Standard (Enter = Ja bzw. der angezeigte Wert).

## Was es einrichtet

| Modul | Was passiert |
|---|---|
| **base** | `apt update`/`upgrade`, Basispakete (`sudo curl wget git vim htop python3 openssh`), Zeitzone (Standard `Europe/Berlin`), Hostname, QEMU Guest Agent (nur auf KVM/Proxmox) |
| **prompt** | Farbiger Bash-Prompt (Benutzer@Host, Uhrzeit, Pfad) für alle Benutzer und root, als markierter Block in `/etc/bash.bashrc` und `/root/.bashrc` (läuft beliebig oft, ersetzt sich selbst) |
| **ssh** | Admin-Schlüssel für root von GitHub (`github.com/<benutzer>.keys`) oder eingefügt; optional Passwort-Login aus (Standard Ja) und root nur mit Schlüssel (Standard Nein, root behält also sein Passwort). Konfiguration als Drop-in `/etc/ssh/sshd_config.d/01-vm-mint.conf`, vor dem Laden mit `sshd -t` geprüft |
| **ansible** | Benutzer `ansible` mit Python 3, sudo ohne Passwort und dem Public Key deines Ansible-Servers (wird abgefragt). Optional ersetzt es einen älteren Schlüssel anhand seines Kommentars, andere Schlüssel in `authorized_keys` bleiben erhalten |
| **docker** | Optional, Standard Nein: Docker CE aus dem offiziellen Repository mit Compose- und Buildx-Plugin, optional Log-Rotation (10 MB, 3 Dateien) und Benutzer in der Gruppe `docker` |
| **updates** | Optional (Standard **Nein**): automatische Sicherheitsupdates (`unattended-upgrades`, ohne automatischen Neustart). Ein zweiter Durchlauf mit `--only=updates` bietet an, sie wieder zu deaktivieren |

## Einzelne Module

Jedes Modul läuft auch allein, z. B. nur den Ansible-Benutzer auf einer bestehenden VM: `--only=ansible`. Fehlende Pakete
(`sudo`, `python3`, `openssh`, `curl`) installiert das jeweilige Modul selbst.

## Sicherheitsupdates wieder abschalten

Per Skript: erneut `--only=updates` starten und die Frage „Jetzt deaktivieren und entfernen?“ mit `j` beantworten.
Von Hand:

```bash
rm /etc/apt/apt.conf.d/20auto-upgrades && apt-get purge -y unattended-upgrades
```

## Keine Überreste

- Das Skript ist **eine Datei** und läuft direkt aus dem Netz, es wird nichts heruntergeladen und abgelegt.
- Der Arbeitsordner in `/tmp` wird am Ende (auch bei einem Fehler) gelöscht, der Paket-Cache geleert.
- Wurde das Skript als Datei gestartet, bietet es am Ende an, sich selbst zu löschen (nicht in einem Git-Ordner).
- Das Einzige, was bleibt, sind die gewünschten Einstellungen und Pakete.

## Optionen

```text
--yes          alle Fragen mit dem Standard beantworten (für viele VMs ohne Rückfragen)
--only=a,b     nur diese Module ausführen: base, prompt, ssh, ansible, docker, updates
--skip=a,b     diese Module überspringen (ohne --only/--skip erscheint das Startmenü)
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
| `ANSIBLE_PUBKEY` | Public Key des Ansible-Servers für den Benutzer `ansible` |
| `ANSIBLE_REPLACE_COMMENT` | Kommentar eines älteren Schlüssels, der dabei ersetzt wird |
| `DOCKER_USER` | Benutzer für die Gruppe `docker` |

Beispiel ohne Rückfragen:

```bash
ADMIN_GITHUB_USER=meinbenutzer ANSIBLE_PUBKEY="ssh-ed25519 AAAA... ansible@server" NEW_HOSTNAME=srv-test-01 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/hyydroo/vm-mint-install/main/install.sh)" -- --yes
```

## Den Ansible-Schlüssel wechseln

Das Modul `ansible` fragt nach dem Public Key des Ansible-Servers und nach dem Kommentar eines alten Schlüssels, der
ersetzt werden soll. Ohne Rückfragen: `ANSIBLE_PUBKEY` und `ANSIBLE_REPLACE_COMMENT` setzen. Auf bestehenden VMs reicht
`--only=ansible`. Der private Schlüssel gehört nur auf den Ansible-Server und nie in dieses Repository.

## Hinweise zur Sicherheit

- **Keine Schlüssel im Skript:** Es trägt nur Schlüssel ein, die du angibst (GitHub-Benutzer, eingefügt oder per
  Umgebungsvariable). Mit `--yes` ohne `ADMIN_PUBKEY`/`ADMIN_GITHUB_USER` bzw. `ANSIBLE_PUBKEY` werden die Module SSH und
  Ansible übersprungen, nichts wird stillschweigend eingetragen.
- Der Benutzer `ansible` bekommt `NOPASSWD:ALL` in `/etc/sudoers.d/ansible`. Das ist für Ansible üblich, setzt aber
  voraus, dass der private Schlüssel gut geschützt ist.
- Die Passwort-Anmeldung per SSH wird nur abgeschaltet, wenn mindestens ein Admin-Schlüssel eingetragen wurde.
  **Teste die Schlüssel-Anmeldung in einem zweiten Terminal, bevor du die Sitzung schließt.**
- Öffentliche Schlüssel in diesem Repository sind unkritisch. Private Schlüssel und Passwörter gehören nie hinein.

## Entwicklung

`bash -n install.sh` und `shellcheck install.sh` laufen in der CI. Mit `--dry-run` lässt sich der Ablauf ohne root und
ohne Änderungen durchspielen.

Lizenz: MIT
