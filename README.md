# MariaDB three-node installer

This is a MariaDB-only installer for Ubuntu 26.04 LTS servers in a three-node design: one primary and two read-only replicas. It does not create Azure resources, configure firewalls, use Terraform/Ansible, use Galera, or bootstrap a Galera cluster.

## Design

All three nodes have GTID and binary logs enabled. One server is installed with the `primary` role and is the only writer. The other two servers are installed with the `replica` role and start with `read_only=ON`. This is classic asynchronous replication, not a multi-writer topology.

Fresh installation and replication initialization are intentionally separate:

1. MariaDB stores its data in Ubuntu's standard `/var/lib/mariadb` location on the OS disk. Size the OS disk for the database, binary logs, relay logs, operating-system overhead, and local backup staging. No separate database disk or mount is required.
2. Assign a distinct numeric server ID to every host. For this topology, use `101` for the primary, `102` for replica 1, and `103` for replica 2.
3. Install each host once. The installer refuses to proceed if its managed configuration or target data directory already exists, so a normal rerun cannot overwrite database data. If package installation was interrupted after Ubuntu initialized the empty system database but before the installer writes `/etc/mysql/mysqld-topology.cnf`, use `--resume` exactly once. It does not reset, delete, or reinitialize the existing data directory.
4. Create the application schema on the primary before seeding a replica. Replica initialization takes a physical backup of the entire primary MariaDB instance, so it includes every database present on the primary at that point.

The scripts use Ubuntu's MariaDB package. Pin or replace that package source externally if a specific MariaDB release is required.

## mysqld configuration

During installation, the script generates the live server configuration at `/etc/mysql/mysqld-topology.cnf`, populated with its default role-specific settings and the supplied server ID, listener address, and port. It appends this line to Ubuntu's package-managed main configuration (`/etc/mysql/mariadb.cnf`, falling back to `/etc/mysql/my.cnf` only when needed):

```ini
!include /etc/mysql/mysqld-topology.cnf
```

The generated configuration remains separate from Ubuntu's package-managed fragments. It retains the package-managed default `datadir` of `/var/lib/mariadb` on the OS disk. The installer refuses to replace an existing generated config, so edit it deliberately after installation.

The included 4-vCPU / 16-GiB profile assigns a 9-GiB InnoDB buffer pool to the primary and 10 GiB to each report replica. It bounds in-memory internal temporary tables at 32 MiB per session, caps connections at 100, retains primary binary logs for 14 days, and configures two parallel replication workers per replica. Replica lag is accepted; the settings aim for eventual catch-up while retaining CPU capacity for reports. Slow-query logging is disabled until a production baseline establishes an appropriate threshold.

## Optional NVMe temporary workspace

If a separate NVMe filesystem is mounted persistently, enable it only after MariaDB installation:

```bash
sudo ./enable-nvme-tempdir.sh --mount /mnt/nvme
```

This creates `/mnt/nvme/mariadb-tmp`, generates `/etc/mysql/mysqld-nvme-temp.cnf`, and adds a second `!include` line to Ubuntu's main MariaDB configuration. It sets `tmpdir`, `slave_load_tmpdir`, and the InnoDB temporary tablespace path. It does not move permanent data from `/var/lib/mariadb`. The mount must be available before MariaDB starts and must persist across reboots.

## Install the three nodes

Run the installer once on each server. For an interrupted first installation, use `--resume` only as described above.

On node 1, the primary (`172.16.0.5`):

```bash
sudo ./install-mariadb.sh --role primary --server-id 101
```

On node 2, replica 1 (`172.16.0.7`):

```bash
sudo ./install-mariadb.sh --role replica --server-id 102
```

On node 3, replica 2 (`172.16.0.6`):

```bash
sudo ./install-mariadb.sh --role replica --server-id 103
```

## Replica-driven seeding

This is the only supported replication-initialization workflow. Run it after MariaDB is installed on the primary and the blank replica, and after the application schema is created on the primary.

The primary must be reachable from the replica on TCP/22 for the restricted backup connection and TCP/3306 for MariaDB replication. Use private IP addresses: `skip_name_resolve=ON` means DNS names are not used for the replication account.

For existing installations made before this repository included `mariadb-backup`, install the backup utility on both the primary and the replica:

```bash
sudo apt update
sudo apt install -y mariadb-backup
```

### 1. Create a replica-specific backup key

On the new replica, generate a dedicated key. Do not reuse a GitHub or administrator key. This example is for replica 1 (`172.16.0.7`):

```bash
sudo install -d -m 700 /root/.ssh
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519_mariadb_primary -C "mariadb-replica-172.16.0.7"
sudo cat /root/.ssh/id_ed25519_mariadb_primary.pub
```

Copy the one public-key line printed by the final command.

### 2. Authorize the replica on the primary

On the primary, create a file containing only the copied public-key line:

```bash
sudo nano /tmp/replica-1.pub
```

Paste the key, save, and exit. Then authorize replica 1's private IP and key:

```bash
sudo ./setup-replica-source-access.sh --replica-ip 172.16.0.7 --public-key-file /tmp/replica-1.pub
```

The setup creates a restricted `mariadb-repl` operating-system account. The key can only originate from the declared replica IP and can only stream a backup or create that replica's replication account; it cannot open an interactive shell.

### 3. Seed and start the replica

On the new replica, run:

```bash
sudo ./initialize-replication.sh --source-host 172.16.0.5 --ssh-key /root/.ssh/id_ed25519_mariadb_primary --replace-empty-replica-data
```

The script prompts for the password of the dedicated MariaDB `replicator` account. It records the primary's SSH host key automatically the first time it connects, streams a consistent physical backup directly from the primary, restores it, sets the backup's GTID position, and starts replication.

`--replace-empty-replica-data` is intentionally required. The script refuses to run if replication already exists or if the target has user-created schemas. After the backup has been prepared, it stops MariaDB and replaces the replica's empty package-created data directory with the primary backup. Do not rerun it on a successfully initialized replica.

### 4. Verify

On the replica:

```bash
sudo mariadb --protocol=socket -e "SHOW REPLICA STATUS\\G"
```

Both values must be `Yes`:

```text
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
```

Repeat steps 1 through 4 for every future replica, always using a unique server ID, private IP address, and SSH key.

## Important operating constraints

- This is asynchronous GTID replication. It can lose transactions that have not reached a replica if the active writer fails; it is not a substitute for a synchronous quorum.
- Permit TCP/3306 between the primary and replicas, and TCP/22 from each replica to the primary, at the network boundary. The installer does not alter host firewalls.
- The OS disk must have capacity for the database, binary logs, relay logs, and local backup staging. Configure backup, monitoring, and alerting outside this script.
- To rebuild a node, explicitly decommission it, stop MariaDB, remove or archive its data deliberately, and then run the fresh installer. This installer does not perform those destructive steps.
