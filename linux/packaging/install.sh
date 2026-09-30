#!/bin/sh
# Adds Dokku Console to the application launcher.
#
# The app runs from this folder, wherever it is. Move the folder to where you
# want to keep it first, then run:
#
#   ./install.sh              add a launcher entry and icons for this folder
#   ./install.sh --uninstall  remove them again; the folder itself stays
#
# Run it again after moving the folder or unpacking a new version over it.
# As root it registers the app for every user, under /usr/local/share;
# otherwise for the current user, under ~/.local/share (or $XDG_DATA_HOME).

set -eu

app_id=com.iamvivekkaushik.dokku_console
here=$(cd "$(dirname "$0")" && pwd -P)

if [ "$(id -u)" -eq 0 ]; then
  data=/usr/local/share
else
  data=${XDG_DATA_HOME:-$HOME/.local/share}
fi
entry=$data/applications/$app_id.desktop
icons=$data/icons/hicolor

# Launchers notice the change by themselves; the caches only make it quicker.
refresh() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database -q "$data/applications" 2>/dev/null || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1 && [ -f "$icons/index.theme" ]; then
    gtk-update-icon-cache -q -t -f "$icons" 2>/dev/null || true
  fi
}

# An Exec value has rules of its own: a path with a space or a shell character
# has to be double-quoted, with ", `, $ and \ escaped twice over because the
# whole value is also unescaped once as a string. A % would have to become %%,
# which GLib then fails to find as a program, so install_entry refuses those.
exec_arg() {
  case $1 in
    *[!A-Za-z0-9_./:@,+=-]*)
      printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\\\\\/g' -e 's/["`$]/\\\\&/g')" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The bundle carries Flutter and the plugins, but GTK 3, libsecret and jsoncpp
# come from the system. Better to say so now than to fail silently later.
check_libraries() {
  command -v ldd >/dev/null 2>&1 || return 0
  missing=$(ldd "$here/dokku_console" "$here"/lib/*_plugin.so 2>/dev/null |
    awk '/=> not found/ && $1 != "libflutter_linux_gtk.so" { print $1 }' | sort -u)
  [ -n "$missing" ] || return 0
  echo "Warning: the app will not start until these system libraries are installed:" >&2
  printf '  %s\n' $missing >&2
  echo "On Debian or Ubuntu they come from libgtk-3-0, libsecret-1-0 and the libjsoncpp package." >&2
}

install_entry() {
  if [ ! -x "$here/dokku_console" ]; then
    echo "install.sh: $here/dokku_console is missing. Run this script from the unpacked release." >&2
    exit 1
  fi
  case $here in
    *%* | *'
'*)
      echo "install.sh: launchers cannot start a program from a folder whose path has a % or a line break in it. Move this folder somewhere else first." >&2
      exit 1
      ;;
  esac
  exe=$here/dokku_console
  mkdir -p "$data/applications"
  # The shipped entry, with Exec and TryExec pointing at this folder.
  while IFS= read -r line || [ -n "$line" ]; do
    case $line in
      Exec=*) printf 'Exec=%s\n' "$(exec_arg "$exe")" ;;
      TryExec=*) printf 'TryExec=%s\n' "$(printf '%s' "$exe" | sed 's/\\/\\\\/g')" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$here/share/applications/$app_id.desktop" >"$entry"
  for png in "$here"/share/icons/hicolor/*/apps/"$app_id".png; do
    size=${png#"$here/share/icons/hicolor/"}
    size=${size%%/*}
    mkdir -p "$icons/$size/apps"
    cp "$png" "$icons/$size/apps/$app_id.png"
  done
  refresh
  check_libraries
  echo "Dokku Console is in the launcher now, running from $here."
  echo "Keep this folder where it is. After moving or updating it, run install.sh again."
  echo "To take it out of the launcher: $here/install.sh --uninstall"
}

uninstall_entry() {
  rm -f "$entry" "$icons"/*/apps/"$app_id".png
  refresh
  echo "Dokku Console is out of the launcher. The app is still in $here; delete that folder to remove it."
}

case ${1:-} in
  '') install_entry ;;
  --uninstall | -u) uninstall_entry ;;
  -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    echo "usage: $0 [--uninstall]" >&2
    exit 2
    ;;
esac
