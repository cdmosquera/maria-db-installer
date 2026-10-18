# MariaDB three-node installer

This is a MariaDB-only installer for Ubuntu 26.04 LTS servers in a three-node design: one primary and two read-only replicas. It does not create Azure resources, configure firewalls, use Terraform/Ansible, use Galera, or bootstrap a Galera cluster.

## Design

All three nodes have GTID and binary logs enabled. One server is installed with the `primary` role and is the only writer. The other two servers are installed with the `replica` role and start with `read_only=ON`. This is classic asynchronous replication, not a multi-writer topology.

Fresh installation and replication initialization are intentionally separate:

1. MariaDB stores its data in Ubuntu's standard `/var/lib/mysql` location on the OS disk. Size the OS disk for the database, binary logs, relay logs, operating-system overhead, and local backup staging if used. No separate database disk or mount is required.
2. Assign a distinct numeric server ID to every host. Example: `101` for the primary; `201` and `202` for the read-only replicas.
3. Install each host once. The script refuses to proceed if its managed configuration or target data directory already exists, so reruns cannot overwrite database data.
4. On the primary, run the `source` action and create a consistent backup. Restore that backup onto each read-only replica before running the `replica` action. Backup/restore is purposefully outside this installer.

The scripts use the OS distribution's MariaDB package. Pin or replace that package source externally if a specific MariaDB release is required.

## mysqld configuration

During installation, the script generates the live server configuration at `/etc/mysql/mysqld-topology.cnf`, populated with its default role-specific settings and the supplied server ID, listener address, and port. It then appends this line to Ubuntu's package-managed main configuration (`/etc/mysql/mariadb.cnf`, falling back to `/etc/mysql/my.cnf` only when needed):

```ini
!include /etc/mysql/mysqld-topology.cnf
```

The generated server configuration remains separate from Ubuntu's package-managed configuration fragments. It deliberately retains the package-managed default `datadir` of `/var/lib/mysql` on the OS disk. The installer refuses to replace an existing generated config, so edit it deliberately after installation.

The included 4-vCPU / 16-GiB profile assigns a 9-GiB InnoDB buffer pool to the primary and 10 GiB to each report replica. It bounds in-memory internal temporary tables at 32 MiB per session, caps connections at 100, retains primary binary logs for 14 days, and configures two parallel replication workers per replica. Replica lag is accepted; the settings are intended to ensure eventual catch-up while preserving CPU capacity for reports. Slow-query logging is disabled until a production baseline establishes an appropriate threshold.

## Optional NVMe temporary workspace

If a separate NVMe filesystem is mounted persistently, enable it only after MariaDB installation:

```bash
sudo ./enable-nvme-tempdir.sh --mount /mnt/nvme
```

This creates `/mnt/nvme/mariadb-tmp`, generates `/etc/mysql/mysqld-nvme-temp.cnf`, and adds a second `!include` line to `/etc/mysql/my.cnf`. It sets `tmpdir`, `slave_load_tmpdir`, and the InnoDB temporary tablespace path. It does not move permanent data from `/var/lib/mysql`. The mount must be available before MariaDB starts and must persist across reboots.

## Examples

On the primary:

```bash
sudo ./install-mariadb.sh --role primary --server-id 101
```

On a read-only replica:

```bash
sudo ./install-mariadb.sh --role replica --server-id 201
```

On the primary, after its installation:

```bash
sudo ./initialize-replication.sh source --repl-user replication --replica-host 10.0.2.21 --replica-host 10.0.2.22
```

After restoring a consistent backup on each replica:

```bash
sudo ./initialize-replication.sh replica --source-host 10.0.1.11 --repl-user replication --seed-confirmed
```

Use real private IP addresses or resolvable host names in `--replica-host`; `skip_name_resolve` makes IP addresses the simpler choice. Avoid `%` as a replica host because it grants replication access from anywhere.

## Important operating constraints

- This is asynchronous GTID replication. It can lose transactions that have not reached a replica if the active writer fails; it is not a substitute for a synchronous quorum.
- Permit TCP/3306 only between these database hosts at the network boundary. The installer does not alter host firewalls.
- The OS disk must have capacity for the database and seven days of binary logs (the configured default). Configure backup, monitoring, and alerting outside this script.
- To rebuild a node, explicitly decommission it, stop MariaDB, remove or archive its data deliberately, and then run the fresh installer. This installer does not perform those destructive steps.
