# Restoring etcd on VMware TKG Kubernetes cluster

A Kubernetes cluster could fail when the backend etcd cluster fails. Sometime we need to perform [Disaster Recovery](https://etcd.io/docs/v3.5/op-guide/recovery/) to etcd clusters back to work. This repo provides a script for automating the Disaster Recovery process for etcd clusters provisioned in [VMware Tanzu Kubernetes Grid](https://docs.vmware.com/en/VMware-Tanzu-Kubernetes-Grid/index.html) (TKG) clusters.

A k8s cluster operator can use this script to restore etcd from etcd snapshot backup. If there is no snapshot backup available, the script supports retrieving snapshot db files from each etcd node as candidates to restore.


## How to use it? 

### 1. Download the scripts on a jumphost where you can SSH to etcd nodes.
- `restore_etcd_tkg.sh`
- `detect_etcd_manifest_path.sh` (optinal, if you want `restore_etcd_tkg.sh` detect etcd pod manifest location)

### 2. Set up IPs of the etcd nodes (k8s control plane nodes) in `ETCD_NODES`.

For example,
```
$ kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}'
10.192.194.209
10.192.194.47
10.192.192.46

$ export ETCD_NODES="10.192.194.209 10.192.194.47 10.192.192.46"
```

### 3. Determine etcd data dir from etcd pod manifest, which is provided to flag `-d, --data-dir` of the script.

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
In this example, hostPath `/var/lib/etcd` is mounted at mountPath `/var/lib/etcd-container` for the etcd job in container to store data. The script should restore etcd snapshot to `/var/lib/etcd` on each etcd node. Hence we specify `-d /var/lib/etcd` when executing the script.

### 4. Determine value for other flags per the script help message.

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

## Script execution demos

### Demo 1

Restore a 3-node etcd cluster with a snapshot `snapshot-db` taken via `etcdctl snapshot save ...`.

https://user-images.githubusercontent.com/30960774/198977842-fcc0b396-9a1b-4bf1-9dba-391676f4e916.mp4

### Demo 2

Restore a 3-node etcd cluster with `--debug` flag. We retrieve snapshot db files from etcd nodes for restoring.

https://user-images.githubusercontent.com/30960774/198977884-5bf93372-82b7-493b-8b05-8754dc517a24.mp4


## Artifacts generated from script execution

Each execution of the script generates

- a local work directory `/tmp/restore-etcd-workdir.timestamp.xyz` on the jumphost where this script is executed to store
  - snapshot files, etcd manifests, etcdctl/etcdutl CLIs retrieved from etcd nodes;
  - generated scripts for restoring etcd data, stopping etcd, and restarting etcd on each etcd node.

- a remote work directory `/home/$SSH_USER/restore-etcd-workdir.timestamp.xyz` on each etcd node to store
  - snapshot file;
  - scripts for restoring etcd data, stopping etcd, and restarting etcd (copied from jumphost) and the logs of executing them;
  - etcd pod manifest temporarily moved from kubelet static pod manifests directory (for stopping etcd pod);
  - etcd data dir restored from snapshot;
  - etcd data dir backup which is taken before swapping in the data restored from snapshot.

### Artifacts generated in [Demo 2](https://github.com/chenweienn/restoring-etcd/edit/main/README.md#demo-2)

```
## on jumphost

ubuntu@jumphost:~$ ls -lh /tmp/restore-etcd-workdir.2022-10-31T09-33-18.ZU4c/
total 58M
-rw-r--r-- 1 kubo kubo  13M Oct 31 09:33 db-from-10.192.192.46
-rw-r--r-- 1 kubo kubo  13M Oct 31 09:33 db-from-10.192.194.209
-rw-r--r-- 1 kubo kubo  13M Oct 31 09:33 db-from-10.192.194.47
-rw-r--r-- 1 kubo kubo 2.6K Oct 31 09:33 etcd-10.192.192.46.yaml
-rw-r--r-- 1 kubo kubo 2.8K Oct 31 09:33 etcd-10.192.194.209.yaml
-rw-r--r-- 1 kubo kubo 2.8K Oct 31 09:33 etcd-10.192.194.47.yaml
-rwxr-xr-x 1 kubo kubo  22M Oct 31 09:33 etcdutl
-rw-rw-r-- 1 kubo kubo  692 Oct 31 09:33 restart_etcd_restored.sh
-rw-rw-r-- 1 kubo kubo  843 Oct 31 09:33 restore_etcd_data_10.192.192.46.sh
-rw-rw-r-- 1 kubo kubo  844 Oct 31 09:33 restore_etcd_data_10.192.194.209.sh
-rw-rw-r-- 1 kubo kubo  843 Oct 31 09:33 restore_etcd_data_10.192.194.47.sh
-rw-rw-r-- 1 kubo kubo  508 Oct 31 09:33 stop_etcd.sh

## on each etcd node

capv@etcd-cluster-control-plane-k6l86:~$ ls -lh /home/capv/restore-etcd-workdir.2022-10-31T09-33-18.ZU4c/
total 13M
-rw-r--r-- 1 capv capv  13M Oct 31 09:33 db-from-10.192.192.46
-rwxrwxr-x 1 capv capv 1.9K Oct 31 09:33 detect_etcd_manifest_path.sh
drwxr-xr-x 3 root root 4.0K Oct 31 09:34 etcd-datadir-backup
drwx------ 3 root root 4.0K Oct 31 09:34 etcd-datadir-restored
-rw------- 1 root root 2.6K Oct 18 05:33 etcd.yaml
-rw-rw-r-- 1 capv capv  605 Oct 31 09:34 restart_etcd_restored_10.192.192.46.log
-rwxrwxr-x 1 capv capv  692 Oct 31 09:33 restart_etcd_restored.sh
-rw-rw-r-- 1 capv capv 3.6K Oct 31 09:34 restore_etcd_data_10.192.192.46.log
-rwxrwxr-x 1 capv capv  843 Oct 31 09:33 restore_etcd_data_10.192.192.46.sh
-rw-rw-r-- 1 capv capv  372 Oct 31 09:34 stop_etcd_10.192.192.46.log
-rwxrwxr-x 1 capv capv  508 Oct 31 09:33 stop_etcd.sh
```

## Contribute

Contributions are always welcome!

Feel free to open issues & send PR.

## License

Copyright © [2022 VMware, Inc. or its affiliates](https://vmware.com/).

This project is licensed under the [Apache Software License version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
