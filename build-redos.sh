#!/bin/bash
# RedOS V.1 - script de build (Debian 12 / Ubuntu, en root)
# Usage : sudo ./build-redos.sh   ->  produit redos-v1.iso
#
# Fonctionnement :
#  1. Tu demarres l'ISO : session de demarrage avec l'installateur (Calamares)
#  2. Calamares : partitionnement, nom d'utilisateur, mot de passe (chiffre) -> INSTALLATION SUR DISQUE
#  3. Au 1er demarrage du systeme installe : RedOS te demande l'usage (cybersecurite / pro)
#  4. Ecran de connexion (mot de passe), puis bureau avec souris et icones
set -e
apt-get update && apt-get install -y live-build
mkdir -p redos-build && cd redos-build
lb clean --purge 2>/dev/null || true

lb config \
  --distribution bookworm \
  --archive-areas "main contrib non-free-firmware" \
  --binary-images iso-hybrid \
  --iso-volume "RedOS V.1" \
  --iso-application "RedOS V.1" \
  --iso-publisher "RedOS" \
  --bootappend-live "boot=live components quiet"

C=config
mkdir -p $C/package-lists $C/hooks/normal
mkdir -p $C/includes.chroot/usr/local/{sbin,bin} $C/includes.chroot/etc/{skel/Desktop,systemd/system,xdg/autostart}

# ---------- Paquets (TOUS installes, quel que soit le profil choisi) ----------
cat > $C/package-lists/redos.list.chroot <<'EOF'
xfce4 xfce4-terminal lightdm lightdm-gtk-greeter network-manager-gnome
whiptail openssl sudo policykit-1
calamares calamares-settings-debian
grub-efi-amd64 grub-efi-amd64-bin grub-pc-bin os-prober
libreoffice-writer libreoffice-calc libreoffice-impress libreoffice-l10n-fr
geany mousepad galculator osmo gnome-clocks thunar firefox-esr
dosbox wireshark nmap tor torbrowser-launcher macchanger
imagemagick fonts-dejavu-core
EOF

# ---------- Assistant de 1er demarrage (systeme INSTALLE uniquement) ----------
cat > $C/includes.chroot/usr/local/sbin/redos-setup <<'EOF'
#!/bin/bash
# Le compte (nom + mot de passe SHA-512) est deja cree par l'installateur.
ask() { whiptail --title "RedOS V.1" "$@" 3>&1 1>&2 2>&3; }
U=$(getent passwd | awk -F: '$3>=1000 && $3<60000 && $1!="user" {print $1; exit}')
whiptail --title "RedOS V.1" --msgbox "Bienvenue ${U} !\nDerniere etape : choisir l'usage du systeme." 10 56
MODE=$(ask --menu "Quelle utilisation ?" 15 66 2 \
  cyber "Cybersecurite (aucune trace de logs sur l'OS)" \
  pro   "Professionnel (Word, Excel, PowerPoint equivalents)") || MODE=pro
echo "$MODE" > /etc/redos-mode

if [ "$MODE" = cyber ]; then
  # Aucune trace : pas de journal, pas de rsyslog, /var/log en RAM (persistant au reboot), pas d'historique shell
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nStorage=none\nForwardToSyslog=no\n' > /etc/systemd/journald.conf.d/redos.conf
  systemctl mask rsyslog.service 2>/dev/null
  grep -q '/var/log tmpfs' /etc/fstab || echo 'tmpfs /var/log tmpfs size=64m,mode=0755 0 0' >> /etc/fstab
  mount -t tmpfs -o size=64m,mode=0755 tmpfs /var/log 2>/dev/null
  echo 'unset HISTFILE; set +o history' > /etc/profile.d/redos-nohist.sh
  [ -n "$U" ] && ln -sf /dev/null "/home/$U/.bash_history"
  systemctl restart systemd-journald
fi
mkdir -p /var/lib/redos && touch /var/lib/redos/configured
EOF

cat > $C/includes.chroot/etc/systemd/system/redos-setup.service <<'EOF'
[Unit]
Description=RedOS first boot setup (installed system only)
ConditionPathExists=!/var/lib/redos/configured
ConditionKernelCommandLine=!boot=live
Before=display-manager.service
After=systemd-user-sessions.service

[Service]
Type=oneshot
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
ExecStart=/usr/local/sbin/redos-setup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# ---------- Lance l'installateur dans la session de demarrage (jamais sur le systeme installe) ----------
cat > $C/includes.chroot/usr/local/bin/redos-live-installer <<'EOF'
#!/bin/bash
grep -q boot=live /proc/cmdline || exit 0
exec sudo -E calamares
EOF
cat > $C/includes.chroot/etc/xdg/autostart/redos-installer.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Installer RedOS
Exec=/usr/local/bin/redos-live-installer
EOF

# ---------- Fond d'ecran RedOS applique une fois a la 1re connexion ----------
cat > $C/includes.chroot/usr/local/bin/redos-wallpaper <<'EOF'
#!/bin/bash
F="$HOME/.config/redos-wallpaper-done"
[ -f "$F" ] && exit 0
sleep 3
for p in $(xfconf-query -c xfce4-desktop -l | grep last-image); do
  xfconf-query -c xfce4-desktop -p "$p" -s /usr/share/backgrounds/redos.png
done
mkdir -p "$(dirname "$F")" && touch "$F"
EOF
cat > $C/includes.chroot/etc/xdg/autostart/redos-wallpaper.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=RedOS wallpaper
Exec=/usr/local/bin/redos-wallpaper
EOF

# ---------- Lanceur .COM DOS ----------
cat > $C/includes.chroot/usr/local/bin/redos-com <<'EOF'
#!/bin/bash
# Usage : redos-com programme.COM   (sans argument : ouvre DOSBox)
if [ -z "$1" ]; then exec dosbox; fi
F=$(readlink -f "$1"); D=$(dirname "$F"); N=$(basename "$F")
exec dosbox -c "mount c '$D'" -c "c:" -c "$N"
EOF

# ---------- Commande terminal `redos` ----------
cat > $C/includes.chroot/usr/local/bin/redos <<'EOF'
#!/bin/bash
case "$1" in
  apps) printf '%s\n' "Word (writer)" "Excel (calc)" "PowerPoint (impress)" "Code (geany)" "Calculatrice" "Calendrier / Agenda (osmo)" "Heure (gnome-clocks)" "Bloc-notes (mousepad)" "Fichiers (thunar)" "Google (firefox)" "DOS (.COM)" "Wireshark / Tor / nmap" ;;
  mode) cat /etc/redos-mode ;;
  version|"") echo "RedOS V.1" ;;
  *) echo "Usage: redos [apps|mode|version]" ;;
esac
EOF

# ---------- Icones du bureau (copiees pour chaque nouvel utilisateur) ----------
mk() { # nom, commande, icone
cat > "$C/includes.chroot/etc/skel/Desktop/$1.desktop" <<EOT
[Desktop Entry]
Type=Application
Name=$1
Exec=$2
Icon=$3
Terminal=false
EOT
}
mk "Word"        "libreoffice --writer"  libreoffice-writer
mk "Excel"       "libreoffice --calc"    libreoffice-calc
mk "PowerPoint"  "libreoffice --impress" libreoffice-impress
mk "Code"        "geany"                 geany
mk "Calculatrice" "galculator"           galculator
mk "Calendrier"  "osmo"                  osmo
mk "Agenda"      "osmo"                  osmo
mk "Heure"       "gnome-clocks"          org.gnome.clocks
mk "Bloc-notes"  "mousepad"              org.xfce.mousepad
mk "Fichiers"    "thunar"                system-file-manager
mk "Google"      "firefox-esr https://www.google.com" firefox-esr
mk "Terminal"    "xfce4-terminal"        utilities-terminal
mk "DOS"         "redos-com"             dosbox
mk "Wireshark"   "wireshark"             wireshark
mk "Tor"         "torbrowser-launcher"   torbrowser

cat > $C/hooks/normal/9000-redos.hook.chroot <<'EOF'
#!/bin/bash
chmod +x /usr/local/sbin/redos-setup /usr/local/bin/redos* /etc/skel/Desktop/*.desktop
systemctl enable redos-setup.service
echo "RedOS V.1" > /etc/redos-release

# ===== Branding : RedOS apparait comme ton propre OS =====
# Identite systeme (visible dans neofetch, "A propos", etc.)
cat > /usr/lib/os-release <<'OSR'
PRETTY_NAME="RedOS V.1"
NAME="RedOS"
VERSION_ID="1"
VERSION="1 (Debian base)"
ID=redos
ID_LIKE=debian
HOME_URL="https://redos.local"
OSR
echo "RedOS V.1 \n \l" > /etc/issue
echo "RedOS V.1" > /etc/issue.net
echo "Bienvenue sur RedOS V.1" > /etc/motd
echo "redos" > /etc/hostname
# Menu de demarrage GRUB du systeme installe
grep -q GRUB_DISTRIBUTOR /etc/default/grub 2>/dev/null \
  && sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="RedOS"/' /etc/default/grub \
  || echo 'GRUB_DISTRIBUTOR="RedOS"' >> /etc/default/grub
# Installateur : remplace "Debian" par "RedOS" dans les textes
sed -i 's/Debian GNU\/Linux/RedOS/g; s/Debian/RedOS/g' /usr/share/calamares/branding/*/branding.desc 2>/dev/null || true
# Fond d'ecran rouge + nom, utilise aussi par l'ecran de connexion
mkdir -p /usr/share/backgrounds /etc/lightdm/lightdm-gtk-greeter.conf.d
convert -size 1920x1080 gradient:'#8b0000-#160000' -gravity center \
  -font DejaVu-Sans-Bold -fill white -pointsize 120 -annotate 0 "RedOS" \
  -pointsize 36 -annotate +0+110 "V.1" /usr/share/backgrounds/redos.png
printf '[greeter]\nbackground=/usr/share/backgrounds/redos.png\n' > /etc/lightdm/lightdm-gtk-greeter.conf.d/redos.conf
EOF
chmod +x $C/hooks/normal/9000-redos.hook.chroot

lb build
mv live-image-*.iso ../redos-v1.iso
cat <<'EOT'
ISO prete : redos-v1.iso
Test avec un vrai disque virtuel (l'installation y sera persistante) :
  qemu-img create -f qcow2 redos-disk.qcow2 20G
  qemu-system-x86_64 -enable-kvm -m 4G -cdrom redos-v1.iso -hda redos-disk.qcow2 -boot d
Apres installation, redemarre SANS le -cdrom :
  qemu-system-x86_64 -enable-kvm -m 4G -hda redos-disk.qcow2
EOT
