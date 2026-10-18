#!/usr/bin/env bash
# One-time replication actions. Run only after install-mariadb.sh and after the replica was seeded.
set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  cat <<'EOF'
Usage:
  sudo ./initialize-replication.sh source --repl-user NAME --replica-host HOST [--replica-host HOST ...]
  sudo ./initialize-replication.sh replica --source-host HOST --repl-user NAME --seed-confirmed

The command prompts for the replication password; it is not accepted on the command line.
Run "source" once on the active writer, then seed each replica from a consistent backup
of that writer before running "replica" on it. This script refuses an already-configured replica.
EOF
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
action=$1; shift
repl_user=""; source_host=""; seed_confirmed=false; replica_hosts=()
while (($#)); do
  case "$1" in
    --repl-user) repl_user=${2:?}; shift 2;; --source-host) source_host=${2:?}; shift 2;;
    --replica-host) replica_hosts+=("${2:?}"); shift 2;; --seed-confirmed) seed_confirmed=true; shift;;
    -h|--help) usage; exit 0;; *) echo "Unknown argument: $1" >&2; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
[[ $action == source || $action == replica ]] || { usage >&2; exit 2; }
[[ $repl_user =~ ^[A-Za-z0-9_]{1,32}$ ]] || { echo "Use an alphanumeric/underscore replication user name." >&2; exit 2; }
command -v mariadb >/dev/null || { echo "MariaDB client is not installed; run the installer first." >&2; exit 1; }
systemctl is-active --quiet mariadb || { echo "MariaDB is not running; run the installer first." >&2; exit 1; }

read -r -s -p "Replication password: " repl_password; echo
[[ -n $repl_password ]] || { echo "Empty passwords are not allowed." >&2; exit 2; }
# SQL string literal escaping; the value never appears in arguments, files, or logs.
sql_password=${repl_password//\'/\'\'}

if [[ $action == source ]]; then
  ((${#replica_hosts[@]})) || { echo "Give one or more --replica-host values." >&2; exit 2; }
  sql=""
  for host in "${replica_hosts[@]}"; do
    safe_host=${host//\'/\'\'}
    sql+="CREATE USER '${repl_user}'@'${safe_host}' IDENTIFIED BY '${sql_password}'; GRANT REPLICATION SLAVE ON *.* TO '${repl_user}'@'${safe_host}'; "
  done
  mariadb --protocol=socket -e "$sql"
  echo "Replication user created. Seed replicas before configuring them."
  exit 0
fi

[[ -n $source_host ]] || { echo "--source-host is required for a replica." >&2; exit 2; }
[[ $seed_confirmed == true ]] || { echo "Refusing: restore a consistent primary backup first, then pass --seed-confirmed." >&2; exit 1; }
[[ -z $(mariadb --protocol=socket -Nse "SHOW ALL SLAVES STATUS") ]] || { echo "Refusing: replication is already configured on this server." >&2; exit 1; }
safe_source=${source_host//\'/\'\'}
mariadb --protocol=socket -e "CHANGE MASTER TO MASTER_HOST='${safe_source}', MASTER_PORT=3306, MASTER_USER='${repl_user}', MASTER_PASSWORD='${sql_password}', MASTER_USE_GTID=slave_pos; START REPLICA;"
mariadb --protocol=socket -e "SHOW REPLICA STATUS\\G" | egrep 'Slave_IO_Running:|Slave_SQL_Running:|Last_IO_Error:|Last_SQL_Error:'
echo "Replica configuration submitted. Both running fields must be Yes before it is healthy."
