# Restoring etcd in TKG


A k8s cluster operator can use script to restore etcd from etcd snapshot backup. If there is no snapshot backup available, the script supports retrieving snapshot db files from each etcd node as candidates to restore.

Each execution of the script generates

- a local work directory `/tmp/restore-etcd-workdir.timestamp.xyz` on the jumphost where this script is executed to store
  - snapshot files, etcd manifests, etcdctl/etcdutl CLIs retrieved from etcd nodes;
  - generated scripts for restoring etcd data, stopping etcd, and restarting etcd on each etcd node.

- a remote work directory `/home/$SSH_USER/restore-etcd-workdir.timestamp.xyz` on each etcd node to store
  - snapshot file;
  - scripts for restoring etcd data, stopping etcd, and restarting etcd (copied from jumphost) and the logs of executing them;
  - etcd pod manifest temporarily moved from kubelet static pod manifests directory (for stopping etcd pod);
  - etcd datadir restored from snapshot;
  - etcd datadir backup which is taken before swapping in the data restored from snapshot.


## Procedure to restore etcd 

1. Download the scripts on a jumphost where you can SSH to etcd nodes.
- `restore_etcd_tkg.sh`
- `detect_etcd_manifest_path.sh` (optinal, if you want `restore_etcd_tkg.sh` detect etcd pod manifest location)

2. Find IPs of the etcd nodes (k8s control plane nodes).
For example,
```
$ kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
10.192.194.209
10.192.194.47
10.192.192.46

$ export ETCD_NODES="10.192.194.209 10.192.194.47 10.192.192.46"
```

3. Determine etcd data dir from the etcd pod manifest.
Example etcd pod manifest:
```
...
spec:
  containers:
  - command:
    - etcd
    - --advertise-client-urls=https://10.192.194.2:2379
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,....
    - --client-cert-auth=true
    - --data-dir=/var/lib/etcd-container
    ...
    volumeMounts:
    - mountPath: /var/lib/etcd-container
      name: etcd-data
    ...
  volumes:
  - hostPath:
      path: /var/lib/etcd
      type: DirectoryOrCreate
    name: etcd-data
  ...
status: {}
```
We see hostPath `/var/lib/etcd` is mounted with mountPath `/var/lib/etcd-container` for the etcd job to store data. We should restore etcd snapshot to `/var/lib/etcd` on each etcd node. Hence we specify `-d /var/lib/etcd` when executing the script.

4. Refer to help 

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



