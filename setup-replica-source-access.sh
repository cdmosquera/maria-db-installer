#!/usr/bin/env bash
# Run once on the primary for each replica public key.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
[[ $# -eq 4 && $1 == --replica-ip && $3 == --public-key-file ]] || { echo 'Usage: sudo ./setup-replica-source-access.sh --replica-ip IP --public-key-file FILE' >&2; exit 2; }
ip=$2; key_file=$4
[[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ && -r $key_file ]] || { echo 'Invalid IP or unreadable public-key file.' >&2; exit 2; }
id mariadb-repl &>/dev/null || useradd --system --create-home --home-dir /var/lib/mariadb-repl --shell /bin/bash mariadb-repl
install -d -o mariadb-repl -g mariadb-repl -m 700 /var/lib/mariadb-repl/.ssh
key=$(<"$key_file")
grep -Fqx "$key" /var/lib/mariadb-repl/.ssh/keys 2>/dev/null || printf 'from="%s",restrict,command="/usr/local/sbin/mariadb-replication-source-gateway" %s\n' "$ip" "$key" >>/var/lib/mariadb-repl/.ssh/keys
chown mariadb-repl:mariadb-repl /var/lib/mariadb-repl/.ssh/keys; chmod 600 /var/lib/mariadb-repl/.ssh/keys
install -m 644 /dev/null /etc/ssh/sshd_config.d/mariadb-repl.conf
printf 'Match User mariadb-repl\n    AuthorizedKeysFile /var/lib/mariadb-repl/.ssh/keys\n' >/etc/ssh/sshd_config.d/mariadb-repl.conf
cat >/usr/local/sbin/mariadb-replication-source-gateway <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
peer=${SSH_CONNECTION%% *}
case "${SSH_ORIGINAL_COMMAND:-}" in backup-stream|create-replication-user) exec sudo -n /usr/local/sbin/mariadb-replication-source-root "$SSH_ORIGINAL_COMMAND" "$peer";; *) exit 126;; esac
EOF
cat >/usr/local/sbin/mariadb-replication-source-root <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
action=${1:-}; peer=${2:-}
[[ $peer =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || exit 2
case "$action" in
backup-stream)
  [[ $(/usr/bin/mariadb --protocol=socket -Nse "SELECT @@read_only = 0 AND @@log_bin AND @@gtid_strict_mode") == 1 ]] || { echo 'Source is not a writable GTID/binlog primary.' >&2; exit 1; }
  d=$(mktemp -d /var/tmp/mariadb-repl.XXXXXX); trap 'rm -rf "$d"' EXIT
  /usr/bin/mariadb-backup --backup --stream=xbstream --target-dir="$d" --user=root
  ;;
create-replication-user)
  IFS= read -r ip; IFS= read -r password
  [[ $ip == "$peer" && -n $password ]] || exit 2
  p=${password//\'/\'\'}
  /usr/bin/mariadb --protocol=socket <<SQL
CREATE USER IF NOT EXISTS 'replicator'@'$ip' IDENTIFIED BY '$p';
ALTER USER 'replicator'@'$ip' IDENTIFIED BY '$p';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'$ip';
SQL
  ;;
*) exit 2;; esac
EOF
chmod 755 /usr/local/sbin/mariadb-replication-source-{gateway,root}
sudoers_tmp=$(mktemp)
printf 'mariadb-repl ALL=(root) NOPASSWD: /usr/local/sbin/mariadb-replication-source-root *\n' >"$sudoers_tmp"
visudo -cf "$sudoers_tmp"
install -m 440 "$sudoers_tmp" /etc/sudoers.d/mariadb-repl
rm -f "$sudoers_tmp"
sshd -t && systemctl reload ssh
echo "Primary access configured for $ip."
