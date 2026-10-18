#!/usr/bin/env bash
# Run on a blank replica: stream, restore and attach a primary backup using GTID.
set -Eeuo pipefail
usage(){ echo 'Usage: sudo ./initialize-replication.sh --source-host IP --ssh-key FILE --replace-empty-replica-data'; }
source_host=''; ssh_key=''; replace=false
while (($#)); do case "$1" in --source-host) source_host=${2:?}; shift 2;; --ssh-key) ssh_key=${2:?}; shift 2;; --replace-empty-replica-data) replace=true; shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac; done
[[ $EUID -eq 0 && -n $source_host && -r $ssh_key && $replace == true ]] || { usage >&2; exit 2; }
command -v mariadb-backup >/dev/null; command -v mbstream >/dev/null; command -v ssh >/dev/null
systemctl is-active --quiet mariadb
[[ $(mariadb --protocol=socket -Nse 'SELECT @@read_only') == ON ]] || { echo 'This host is not a read-only replica.' >&2; exit 1; }
[[ -z $(mariadb --protocol=socket -Nse 'SHOW ALL SLAVES STATUS') ]] || { echo 'Replication is already configured.' >&2; exit 1; }
[[ -z $(mariadb --protocol=socket -Nse "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','information_schema','performance_schema','sys')") ]] || { echo 'Refusing to replace a replica containing user schemas.' >&2; exit 1; }
replica_ip=$(ip route get "$source_host" | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1);exit}}')
[[ -n $replica_ip ]] || { echo 'Could not determine this replica source IP.' >&2; exit 1; }
read -r -s -p 'Replication password: ' password; echo; [[ -n $password ]] || exit 2
work=$(mktemp -d /var/tmp/mariadb-seed.XXXXXX); trap 'rm -rf "$work"' EXIT
ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes "mariadb-repl@$source_host" backup-stream | mbstream -x -C "$work"
mariadb-backup --prepare --target-dir="$work"
gtid=$(awk 'NF>=3 {print $3; exit}' "$work"/mariadb_backup_binlog_info "$work"/xtrabackup_binlog_info 2>/dev/null)
[[ $gtid =~ ^[0-9]+-[0-9]+-[0-9]+(,[0-9]+-[0-9]+-[0-9]+)*$ ]] || { echo 'Backup did not contain a valid GTID position.' >&2; exit 1; }
printf '%s\n%s\n' "$replica_ip" "$password" | ssh -i "$ssh_key" -o BatchMode=yes -o IdentitiesOnly=yes "mariadb-repl@$source_host" create-replication-user
systemctl stop mariadb
find /var/lib/mariadb -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
mariadb-backup --copy-back --target-dir="$work"
chown -R mysql:mysql /var/lib/mariadb
systemctl start mariadb
p=${password//\'/\'\'}
mariadb --protocol=socket <<SQL
SET GLOBAL gtid_slave_pos='$gtid';
CHANGE MASTER TO MASTER_HOST='$source_host', MASTER_PORT=3306, MASTER_USER='replicator', MASTER_PASSWORD='$p', MASTER_USE_GTID=slave_pos;
START REPLICA;
SQL
mariadb --protocol=socket -e 'SHOW REPLICA STATUS\G' | egrep 'Slave_IO_Running:|Slave_SQL_Running:|Last_IO_Error:|Last_SQL_Error:'
