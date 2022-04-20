# Recovering etcd in TKG

## usage

```
Usage:
  restore_etcd_tkg.sh [-s|--snapshot-files <filename>] -d|--data-dir <output dir> -n|--etcd-nodes <node> <node> ... -k|--ssh-key <SSH key> -u|--ssh-user <SSH user> [--skip-hash-check] [-h|--help]

Flags:
      -d, --data-dir string                Absolute path to etcd data directory in master nodes
      -h, --help                           Print usage
      -k, --ssh-key string                 SSH key to access each etcd nodei ($SSH_KEY)
      -n, --etcd-nodes []string            Hostname or IP of each etcd node in the cluster ($ETCD_NODES)
      -u, --ssh-user string                SSH user to access each etcd node ($SSH_USER)
      -s, --snapshot-file string           Etcd snapshot "db" file
          --skip-hash-check                Ignore snapshot integrity hash value (required if copied from data directory)
          --debug                          Print debug level log

Examples:
      # Restore the etcd snapshot snapshot.db to dir /var/lib/etcddisk/etcd on each etcd node
      export ETCD_NODES="10.0.0.3 10.0.0.4 10.0.0.5" SSH_USER=capi SSH_KEY=/home/bob/capi.key
      restore_etcd_tkg.sh -s snapshot.db -d /var/lib/etcddisk/etcd

      # Restore the snapshot file-db copied from etcd data directory
      restore_etcd_tkg.sh -s file-db -d /var/lib/etcddisk/etcd --skip-hash-check

      # When --snapshot-file is missing, take snapshot db from each etcd node data-dir; interactively you select one to restore
      restore_etcd_tkg.sh -d /etcddisk/etcd --skip-hash-check
```
