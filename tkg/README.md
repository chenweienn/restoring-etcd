# Recovering etcd in TKG

## usage

```
$ ./restore_etcd_tkg.sh --help
Usage:
  restore_etcd_tkg.sh -d <etcd-data-dir> [-s <etcd-snapshot-file>] [-m <etcd-pod-manifest>] -n <node1> <node2> ... -k <SSH key> -u <SSH user> [--skip-hash-check] [--help] [--debug]

Flags:
      -d, --data-dir string                Absolute path to etcd data directory on etcd nodes
      -m, --manifest-path string           Absolute path to etcd pod manifest on etcd nodes ($ETCD_MANIFEST_PATH)
      -u, --ssh-user string                SSH user to access each etcd node ($SSH_USER)
      -k, --ssh-key string                 SSH key to access each etcd node ($SSH_KEY)
      -n, --etcd-nodes []string            Hostname or IP of each etcd node in the cluster ($ETCD_NODES)
      -s, --snapshot-file string           Etcd snapshot "db" file
          --skip-hash-check                Ignore snapshot integrity hash value (required if the db file is copied from data directory)
      -h, --help                           Print usage
          --debug                          Print debug level log

       If both flag and environment variable are set, the value supplied to flag takes preference. For exmaple, when both "--ssh-key key1" and "SSH_KEY=key2" are set, key1 is used.

Examples:
      # Restore the etcd snapshot snapshot.db to dir /var/lib/etcddisk/etcd on each etcd node. The file "snapshot.db" is generated via "etcdctl snapshot save <filename> ...".
      export ETCD_NODES="10.0.0.3 10.0.0.4 10.0.0.5" ETCD_MANIFEST_PATH=/etc/kubernetes/manifests/etcd.yaml SSH_USER=capi SSH_KEY=capi-ssh-key
      ./restore_etcd_tkg.sh -s snapshot.db -d /var/lib/etcddisk/etcd

      # Restore the etcd snapshot db file copied from etcd data directory on some etcd node.
      export ETCD_NODES="10.0.0.3 10.0.0.4 10.0.0.5" ETCD_MANIFEST_PATH=/etc/kubernetes/manifests/etcd.yaml SSH_USER=capi SSH_KEY=capi-ssh-key
      ./restore_etcd_tkg.sh -s db-file -d /var/lib/etcddisk/etcd --skip-hash-check

      # When --snapshot-file is not set, the script will copy snapshot db files from each etcd node. Interactively you will be asked to select one to restore.
      export ETCD_NODES="10.0.0.3 10.0.0.4 10.0.0.5" ETCD_MANIFEST_PATH=/etc/kubernetes/manifests/etcd.yaml SSH_USER=capi SSH_KEY=capi-ssh-key
      ./restore_etcd_tkg.sh -d /etcddisk/etcd --skip-hash-check

      # When --manifest-path or ETCD_MANIFEST_PATH is not set, the script will look for etcd pod manifest in static pod manifest directory per kubelet configuraiton.
      export ETCD_NODES="10.0.0.3 10.0.0.4 10.0.0.5" SSH_USER=capi SSH_KEY=capi-ssh-key
      ./restore_etcd_tkg.sh -d /etcddisk/etcd --skip-hash-check 
```

### Demo 1:

Restore a 3-node etcd cluster with a snapshot `snapshot-db` taken via `etcdctl snapshot save ...`.


https://user-images.githubusercontent.com/30960774/198950519-1d5d5481-e96e-4fc5-8f73-419bd7a64ae4.mp4


### Demo 2:

Restore a 3-node etcd cluster with `--debug` flag. We retrieve snapshot db files from etcd nodes for restoring.


https://user-images.githubusercontent.com/30960774/198950544-3c42fba1-4e2c-48d2-9835-7eeaf41c3399.mp4



