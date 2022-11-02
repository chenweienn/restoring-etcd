#!/bin/bash

set -uo pipefail
# set -e
# set -x

SCRIPT_NAME=$(basename $0)

usage() {
   echo "Usage:"
   echo "  $SCRIPT_NAME -d <etcd-data-dir> [-s <etcd-snapshot-file>] [-m <etcd-pod-manifest>] -n <node1> <node2> ... -k <SSH key> -u <SSH user> [--skip-hash-check] [--help] [--debug]"
   echo ""
   echo "Flags:"
   echo "      -d, --data-dir string                Absolute path to etcd data directory on etcd nodes"
   echo "      -m, --manifest-path string           Absolute path to etcd pod manifest on etcd nodes (\$ETCD_MANIFEST_PATH)"
   echo "      -u, --ssh-user string                SSH user to access each etcd node (\$SSH_USER)"
   echo "      -k, --ssh-key string                 SSH key to access each etcd node (\$SSH_KEY)"
   echo "      -n, --etcd-nodes []string            Hostname or IP of each etcd node in the cluster (\$ETCD_NODES)"
   echo "      -s, --snapshot-file string           Etcd snapshot \"db\" file"
   echo "          --skip-hash-check                Ignore snapshot integrity hash value (required if the db file is copied from data directory)"
   echo "      -h, --help                           Print usage"
   echo "          --debug                          Print debug level log"
   echo ""
   echo "       If both flag and environment variable are set, the value supplied to flag takes preference. For exmaple, when both \"--ssh-key key1\" and \"SSH_KEY=key2\" are set, key1 is used."
   echo ""
   echo "Examples:"
   echo "      # Restore the etcd snapshot snapshot.db to dir /var/lib/etcddisk/etcd on each etcd node. The file \"snapshot.db\" is generated via \"etcdctl snapshot save <filename> ...\"."
   echo "      export ETCD_NODES=\"10.0.0.3 10.0.0.4 10.0.0.5\" ETCD_MANIFEST_PATH=/etc/kubernetes/manifests/etcd.yaml SSH_USER=capi SSH_KEY=capi-ssh-key"
   echo "      ./$(basename $0) -s snapshot.db -d /var/lib/etcddisk/etcd"
   echo ""
   echo "      # Restore the etcd snapshot db file copied from etcd data directory on some etcd node."
   echo "      export ETCD_NODES=\"10.0.0.3 10.0.0.4 10.0.0.5\" ETCD_MANIFEST_PATH=/etc/kubernetes/manifests/etcd.yaml SSH_USER=capi SSH_KEY=capi-ssh-key"
   echo "      ./$(basename $0) -s db-file -d /var/lib/etcddisk/etcd --skip-hash-check"
   echo ""
   echo "      # When --snapshot-file is not set, the script will copy snapshot db files from each etcd node. Interactively you will be asked to select one to restore."
   echo "      export ETCD_NODES=\"10.0.0.3 10.0.0.4 10.0.0.5\" ETCD_MANIFEST_PATH=/etc/kubernetes/manifests/etcd.yaml SSH_USER=capi SSH_KEY=capi-ssh-key"
   echo "      ./$(basename $0) -d /etcddisk/etcd --skip-hash-check"
   echo ""
   echo "      # When --manifest-path or ETCD_MANIFEST_PATH is not set, the script will look for etcd pod manifest in static pod manifest directory per kubelet configuraiton."
   echo "      export ETCD_NODES=\"10.0.0.3 10.0.0.4 10.0.0.5\" SSH_USER=capi SSH_KEY=capi-ssh-key"
   echo "      ./$(basename $0) -d /etcddisk/etcd --skip-hash-check"
   echo ""
   exit 0
}

DEBUG=false

# when --snapshot-file is missing
PULL_SNAPSHOT_FROM_ETCD_NODES=true

SKIP_HASH_CHECK=false

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]
do
  case $1 in
      -h|--help)
          usage
          ;;
      -d|--data-dir)
	  # verify if it is an absolute path
          if [[ ${2:-} =~ ^\/.*$ ]]; then
            DATA_DIR=$2
            shift; shift
          else
            echo -e "Error: the provided absolute path to etcd data directory \"${2:-}\" is invalid\n"
            usage
	  fi
          ;;
      -m|--manifest-path)
	  # verify if it is an absolute path
          if [[ ${2:-} =~ ^\/.*$ ]]; then
            ETCD_MANIFEST_PATH=$2
            shift; shift
          else
            echo -e "Error: the provided absolute path to etcd pod manifest \"${2:-}\" is invalid\n"
            usage
	  fi
          ;;
      -k|--ssh-key)
          if [ -n ${2:-} ] && [ -f ${2:-} ]; then
            SSH_KEY=$2
	    shift; shift
	  else
            echo -e "Error: the provided SSH key \"${2:-}\" is invalid\n"
	    usage
	  fi
	  ;;
      -u|--ssh-user)
	  if [ -n ${2:-} ]; then
	    SSH_USER=$2
	    shift; shift
	  else
	    echo -e "Error: please provide an SSH user via --ssh-user (\$SSH_USER)\n"
	    usage
	  fi
	  ;;
      --skip-hash-check)
	  SKIP_HASH_CHECK=true
	  shift
	  ;;
      -s|--snapshot-file)
	  PULL_SNAPSHOT_FROM_ETCD_NODES=false
	  if [ -f "${2:-}" ]; then
            SNAPSHOT_FILE=$2
	    shift; shift
	  else
	    echo -e "Error: the provided snapshot file \"${2:-}\" does not exist\n"
	    usage
	  fi
	  ;;
      -n|--etcd-nodes)
	  shift
	  ;;
      --debug)
	  DEBUG=true
	  shift
	  ;;
      -*)
	  echo -e "Error: unreconganized flag $1\n"
	  usage
	  ;;
      *)
          POSITIONAL_ARGS+=("$1") # save positional args
          shift
          ;;
  esac
done

# now either array POSITIONAL_ARGS (from --etcd-nodes) or string $ETCD_NODES should contain the list of etcd nodes "<node> <node> ..."
# copy nodes into an array ETCD_NODES_ARRAY (values from cli option --etcd-nodes take precedence)

ETCD_NODES_ARRAY=()
for node in ${POSITIONAL_ARGS[@]}; do
  ETCD_NODES_ARRAY+=($node)
done
if [ ${#ETCD_NODES_ARRAY[@]} -eq 0 ]; then
  for node in ${ETCD_NODES:-}; do
    ETCD_NODES_ARRAY+=("$node")
  done
fi
    
if [ ${#ETCD_NODES_ARRAY[@]} -eq 0 ]; then
  echo "Error: please provide one or more etcd nodes via --etcd-nodes (\$ETCD_NODES)"
  echo ""
  usage
fi

# check ETCD_MANIFEST_PATH
#if [ -z "${ETCD_MANIFEST_PATH:-}" ]; then
#  echo "Error: please provide etcd pod manifest path via --manifest-path (\$ETCD_MANIFEST_PATH)"
#  echo ""
#  usage
#fi

# check SSH_KEY and SSH_USER
if [ -z ${SSH_KEY:-} ] || [ -z ${SSH_USER:-} ]; then
  echo "Error: please provide both --ssh-key (\$SSH_KEY) and --ssh-user (\$SSH_USER)"
  echo ""
  usage
fi

# PULL_SNAPSHOT_FROM_ETCD_NODES is set true only when snapshot file is not provided via --snapshot-file
if $PULL_SNAPSHOT_FROM_ETCD_NODES; then
    SKIP_HASH_CHECK=true
fi

# a local directory under /tmp to store 
#   (1) snapshot files, etcd manifests, etcdctl/etcdutl CLIs retrieved from etcd nodes;
#   (2) restore script for each etcd node generated by this script.
WORKDIR="$(mktemp -d -p /tmp -t restore-etcd-workdir.$(date -u +%Y-%m-%dT%H-%M-%S).XXXX)"

# WORKDIR and REMOTE_WORKDIR contains same timestamp, which makes troubleshooting easier
# a remote directory is created on each etcd node to store
#   (1) snapshot file;
#   (2) the generated restore script to be executed on etcd node.
#   (3) etcd manifest temporarily moved from ETCD_MANIFEST_PATH, for stopping etcd pod
#   (4) etcd datadir backup 
REMOTE_WORKDIR="/home/$SSH_USER/$(basename $WORKDIR)"

check_etcd_node_connectivity() {
    if $DEBUG; then
	echo "[debug] Checking SSH connectivity with each etcd node..."
    fi
    ETCD_NODES_CONN=()
    ETCD_CONN_ISSUE=false
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY $SSH_USER@${node} "exit" > /dev/null); then
	    ETCD_NODES_CONN[$i]="Connected"
	    if $DEBUG; then
	        echo "[debug] - node ${ETCD_NODES_ARRAY[$i]}: ${ETCD_NODES_CONN[$i]}"
	    fi
	else
            ETCD_CONN_ISSUE=true
            ETCD_NODES_CONN[$i]="Connection timed out after 10 seconds"
	    echo "[error] - node ${ETCD_NODES_ARRAY[$i]}: ${ETCD_NODES_CONN[$i]}"
	fi
    done

    if $ETCD_CONN_ISSUE; then
	echo "[error] Please resolve etcd nodes connectivity issue."
	exit 1
    else
	echo "[info]  Passed etcd nodes connectivity check."
    fi
}

create_remote_workdir() {
    echo "[info]  Creating remote work dir on each etcd node ..."

    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "if [ ! -d $REMOTE_WORKDIR ]; then sudo mkdir -p $REMOTE_WORKDIR; sudo chmod a+wx $REMOTE_WORKDIR; fi"); then
	    if $DEBUG; then
		echo "[debug] - node $node: created remote work dir $REMOTE_WORKDIR"
	    fi
	else
            echo "[error] Failed to create remote work dir $REMOTE_WORKDIR on node $node. Exit."
	    exit 1
	fi
    done
    echo "[info]  Created remote work dir $REMOTE_WORKDIR on each etcd node."
}

DETECT_ETCD_MANIFEST_SCRIPT="detect_etcd_manifest_path.sh"

detect_etcd_manifest_path() {
    echo "[info]  Detecting etcd pod manifest path on each etcd node as --manifest-path (\$ETCD_MANIFEST_PATH) is not set ..."

    if [ ! -x ./$DETECT_ETCD_MANIFEST_SCRIPT ]; then
        echo "[error] The script $DETECT_ETCD_MANIFEST_SCRIPT is not found under $PWD or it is not executable. Make sure you have download it from https://github.com/chenweienn/recovering-etcd and make it executable. Exit."
        exit 1
    fi

    # an array to store detected etcd manifest path from each etcd node
    DETECTED_ETCD_MANIFEST_PATH=()

    ETCD_MANIFEST_PATH_MISMATCH=false

    # send script "detect_etcd_manifest_path.sh" to each etcd node
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (scp -q -o StrictHostKeyChecking=no -i $SSH_KEY ./$DETECT_ETCD_MANIFEST_SCRIPT $SSH_USER@${node}:$REMOTE_WORKDIR/$DETECT_ETCD_MANIFEST_SCRIPT) \
           && (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo chmod +x $REMOTE_WORKDIR/$DETECT_ETCD_MANIFEST_SCRIPT"); then
            if $DEBUG; then
                echo "[debug] - sent script $DETECT_ETCD_MANIFEST_SCRIPT to node $node"
            fi
        else
            echo "[error] Failed to send script $DETECT_ETCD_MANIFEST_SCRIPT to node $node. Exit."
            exit 1
	fi	
    done

    for i in ${!ETCD_NODES_ARRAY[@]}; do
        node=${ETCD_NODES_ARRAY[$i]}
        DETECTED_ETCD_MANIFEST_PATH[$i]=$(ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo $REMOTE_WORKDIR/$DETECT_ETCD_MANIFEST_SCRIPT")
        if [ -n "${DETECTED_ETCD_MANIFEST_PATH[$i]}" ]; then
            if $DEBUG; then
                echo "[debug] - node $node: found etcd manifest at ${DETECTED_ETCD_MANIFEST_PATH[$i]}"
            fi
            if [ -z "${ETCD_MANIFEST_PATH:-}" ]; then
                ETCD_MANIFEST_PATH=${DETECTED_ETCD_MANIFEST_PATH[$i]}
            elif [ "$ETCD_MANIFEST_PATH" != "${DETECTED_ETCD_MANIFEST_PATH[$i]}" ]; then
                ETCD_MANIFEST_PATH_MISMATCH=true
            fi 
        else
            echo "[error] - node $node: etcd manifest not found. To troubleshoot, you can run \"$REMOTE_WORKDIR/$DETECT_ETCD_MANIFEST_SCRIPT --debug\" on this node. Exit."
            exit 1
        fi
    done

    if $ETCD_MANIFEST_PATH_MISMATCH; then
        echo "[error]  Detected inconsistent etcd pod manifest path on different etcd nodes. Please get help from your support team. Exit."
        exit 1
    else
        echo "[info]  Detected consistent etcd pod manifest at $ETCD_MANIFEST_PATH on each etcd node."
    fi
}

get_etcd_manifest_check_version() {
    if [ -z "${ETCD_MANIFEST_PATH:-}" ]; then
	detect_etcd_manifest_path
    fi

    if $DEBUG; then
	echo "[debug] Copying etcd manifest from each node..."
    fi

    # to-do: check kubelet flag --pod-manifest-path and key staticPodPath in KubeletConfiguration; the flag --pod-manifest-path takes precedence
    # ETCD_MANIFEST_PATH="/etc/kubernetes/manifests/etcd.yaml"

    # an array to store retrieved etcd manifest path "$WORKDIR/etcd-$node.yaml" for each node
    ETCD_MANIFEST=()

    # an array to store detected etcd version of each node
    ETCD_IMG_TAG=()

    # set true if it fails to pull etcd manifest from any node
    ETCD_MANIFEST_NOTFOUND=false

    ETCD_VERSION_MISMATCH=false
    ETCD_IMG_TAG_NON_EMPTY=""

    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo cp $ETCD_MANIFEST_PATH /tmp/etcd.yaml; sudo chmod a+r /tmp/etcd.yaml") \
            && (scp -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node}:/tmp/etcd.yaml $WORKDIR/etcd-$node.yaml) \
	    && [ -f "$WORKDIR/etcd-$node.yaml" ]; then
	        ETCD_MANIFEST[$i]="$WORKDIR/etcd-$node.yaml"
                ETCD_IMG_TAG[$i]=$(cat ${ETCD_MANIFEST[$i]} | grep "image:" | awk -F':' '{print $NF}')
	fi

	if [ ! -f "${ETCD_MANIFEST[$i]:-}" ]; then
	    ETCD_MANIFEST_NOTFOUND=true
	    echo "[error] - node $node: missing $ETCD_MANIFEST_PATH."
	elif [ -z "${ETCD_IMG_TAG[$i]:-}" ]; then
	    echo "[error] - node $node: saved etcd manifest as ${ETCD_MANIFEST[$i]}, but failed to detect image tag."
	else
            if [ -z "$ETCD_IMG_TAG_NON_EMPTY" ]; then
		ETCD_IMG_TAG_NON_EMPTY=${ETCD_IMG_TAG[$i]}
	    fi
            if $DEBUG; then
		echo "[debug] - node $node: etcd image tag ${ETCD_IMG_TAG[$i]} in etcd manifest."
	    fi
	fi
    done

    if $ETCD_MANIFEST_NOTFOUND; then
	echo "[error] etcd manifest is missing in some node(s). Exit."
	exit 1
    fi

    # although pulled etcd manifest from each node successfully, we are not able to detect etcd image tag (version info) from any node
    if [ -z "$ETCD_IMG_TAG_NON_EMPTY" ]; then
        echo "[error] failed to detect image tag from etcd manifests. Exit."
        exit 1
    fi

    for i in ${!ETCD_NODES_ARRAY[@]}; do
	if [ "${ETCD_IMG_TAG[$i]}" != "$ETCD_IMG_TAG_NON_EMPTY" ]; then
            ETCD_VERSION_MISMATCH=true
	    break
	fi
    done
    
    if $ETCD_VERSION_MISMATCH ; then
	echo "[error] Detected etcd version mismatch across the ${#ETCD_NODES_ARRAY[@]}-node etcd cluster:"
	for i in ${!ETCD_NODES_ARRAY[@]}; do
             echo "[info]  - node ${ETCD_NODES_ARRAY[$i]}: etcd image tag ${ETCD_IMG_TAG[$i]} in etcd manifest."
	done
	echo "[error] You may be in the middle of cluster upgrade. Please get help from your support team. Exit."
	exit 1
    fi

    # image tag v3.5.0_vmware.7 maps to version 3.5.0
    ETCD_VERSION=$(echo $ETCD_IMG_TAG_NON_EMPTY | grep -o -E "[0-9]+\.[0-9]+\.[0-9]+")

    # from etcd version 3.5.0, etcdutl is introduced
    if [ $ETCD_VERSION = $(echo -e "$ETCD_VERSION\n3.5.0" | sort -n | tail -n 1) ]; then
	ETCD_CLI_FOR_RESTORE=etcdutl
    else
	ETCD_CLI_FOR_RESTORE=etcdctl
    fi

    echo "[info]  Passed etcd version check. Detected same image tag $ETCD_IMG_TAG_NON_EMPTY in etcd manifest from all etcd nodes."
    echo "[info]  Etcd manifests are saved into $WORKDIR/."
}

get_etcdctl_from_etcd_node() {
    # scp compatible etcdctl or etcdutl cli from etcd node to the jumpbox where you run this script
    ETCD_CLI_VERSION=""
    for node in ${ETCD_NODES_ARRAY[@]}; do
	ETCD_CLI_FROM_NODE=${node}
        if [ -z "${ETCD_CLI_VERSION}" ]; then
	    ETCD_CLI_VERSION=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY $SSH_USER@${node} "sudo cp \$(sudo find /var/lib/containerd/ -name $ETCD_CLI_FOR_RESTORE | grep "bin\/$ETCD_CLI_FOR_RESTORE" | head -n 1) /tmp/$ETCD_CLI_FOR_RESTORE; sudo chmod a+r /tmp/$ETCD_CLI_FOR_RESTORE; sudo /tmp/$ETCD_CLI_FOR_RESTORE version" 2>&1 | grep -i "$ETCD_CLI_FOR_RESTORE version" | cut -d' ' -f3)
	    if [ $ETCD_CLI_VERSION = ${ETCD_VERSION} ] && (scp -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node}:/tmp/$ETCD_CLI_FOR_RESTORE $WORKDIR/$ETCD_CLI_FOR_RESTORE) && [ -f "$WORKDIR/$ETCD_CLI_FOR_RESTORE" ]; then
		chmod +x $WORKDIR/$ETCD_CLI_FOR_RESTORE
	        break
	    fi
	fi
    done

    # logging
    if [ -x $WORKDIR/$ETCD_CLI_FOR_RESTORE ]; then 
	echo "[info]  Copied $ETCD_CLI_FOR_RESTORE cli (version ${ETCD_CLI_VERSION}) from node ${ETCD_CLI_FROM_NODE} to $WORKDIR/$ETCD_CLI_FOR_RESTORE"
    else
        echo "[error] Failed to find compatible $ETCD_CLI_FOR_RESTORE cli from any etcd nodes."
	exit 1
    fi
}

select_snapshot_from_etcd_node() {
    echo "[info]  Flag --snapshot-file is not set."
    while true; do
	read -t 10 -p "Do you want me to get snapshot files from etcd nodes? [Y/N]: " answer
	case $answer in
	    Y|y)
		break
	       	;;
	    N|n)
	        echo "Bye."
		exit
		;;
	    *)
	        echo "Pleaes enter Y or N."
		;;
	esac
    done
    
    echo "[info]  Getting snapshot db files $DATA_DIR/member/snap/db from etcd nodes ..."
    ETCD_SNAPSHOT_FILE=()
    SNAPSHOT_NOT_FOUND=true
    for i in ${!ETCD_NODES_ARRAY[@]}; do
        node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo cp $DATA_DIR/member/snap/db /tmp/db; sudo chmod a+r /tmp/db") \
            && (scp -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node}:/tmp/db $WORKDIR/db-from-$node) \
            && [ -f $WORKDIR/db-from-$node ]; then
                ETCD_SNAPSHOT_FILE[$i]=$WORKDIR/db-from-$node
                SNAPSHOT_NOT_FOUND=false
               
                echo "[info]  - node $node: saved snapshot into $WORKDIR/db-from-$node"
        else
                echo "[info]  - node $node: failed to get snapshot"
        fi
    done

    if $SNAPSHOT_NOT_FOUND ; then
        echo "[error]  Failed to get snapshot db files from etcd nodes. If you have any backup snapshot from this etcd cluster, try --snapshot-file flag ($SCRIPT_NAME --help)"
        exit 1
    fi

    echo "[info]  Checking snapshot db files status ..."
    echo ""
    for i in ${!ETCD_NODES_ARRAY[@]}; do
        if [ -f "${ETCD_SNAPSHOT_FILE[$i]}" ]; then
            echo  "[info]  - node ${ETCD_NODES_ARRAY[$i]} snapshot status"
	    echo  "[info]  - cmd: $ETCD_CLI_FOR_RESTORE snapshot status ${ETCD_SNAPSHOT_FILE[$i]} -w table"
            $WORKDIR/$ETCD_CLI_FOR_RESTORE snapshot status ${ETCD_SNAPSHOT_FILE[$i]} -w table
            echo ""
        fi
    done

    while true; do
        read -t 20 -p "To restore etcd, select the retrieved snapshot file from nodes [ $(for i in ${!ETCD_NODES_ARRAY[@]}; do if [ $i -eq 0 ]; then echo -n "${ETCD_NODES_ARRAY[$i]}"; else echo -n ", ${ETCD_NODES_ARRAY[$i]}"; fi; done) ]: " answer
	# read -t 10 -p "To restore the clsuter, I want to use the retrieved snapshot from node ['${ETCD_NODES_ARRAY[@]}']: " answer
        for i in ${!ETCD_NODES_ARRAY[@]}; do
	    if [ "$answer" = "${ETCD_NODES_ARRAY[$i]}" ]; then
		SNAPSHOT_FILE=${ETCD_SNAPSHOT_FILE[$i]}
		echo ""
		return
	    fi
	done
	echo "Please enter a valid node, e.g., ${ETCD_NODES_ARRAY[0]} (or CTRL+C to abort restore)."
    done
}


restore_etcd() {
    echo "[info]  Generating scripts for restoring etcd snapshot data on each etcd node ..."

    # the arrays to store etcd config flags parsed from etcd manifests
    ETCD_name=()
    ETCD_init_adv_peer_urls=()
    ETCD_init_cluster_token=()
    # if set, --initial-cluster-token value should be consistent across nodes
    ETCD_INIT_CLUSTER_TOKEN=""

    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	ETCD_name[$i]=$(cat ${ETCD_MANIFEST[$i]} | grep "\-\-name=" | cut -d'=' -f2)
	ETCD_init_adv_peer_urls[$i]=$(cat ${ETCD_MANIFEST[$i]} | grep "\-\-initial-advertise-peer-urls=" | cut -d'=' -f2)
        ETCD_init_cluster_token[$i]=$(cat ${ETCD_MANIFEST[$i]} | grep "\-\-initial-cluster-token=" | cut -d'=' -f2)
	if [ -z ${ETCD_name[$i]} ] || [ -z ${ETCD_init_adv_peer_urls[$i]} ]; then
            echo "[error] fail to parse out etcd flags for node $node:"
	    echo "[error] - manifest stored at ${ETCD_MANIFEST[$i]}"
	    echo "[error] - --name=${ETCD_name[$i]}"
	    echo "[error] - --initial-advertise-peer-urls=${ETCD_init_adv_peer_urls[$i]}"
	    echo "[error] Abort."
	    exit 1
	fi

	# record a non-empty --initial-cluster-token value if set for any etcd nodes
        if [ -z "$ETCD_INIT_CLUSTER_TOKEN" ] && [ -n "${ETCD_init_cluster_token[$i]}" ]; then
	    ETCD_INIT_CLUSTER_TOKEN="${ETCD_init_cluster_token[$i]}"
        fi
    done

    # check if --initial-cluster-token is set with different value from etcd nodes
    ETCD_INIT_CLUSTER_TOKEN_MISMATCH=false

    if [ -n "$ETCD_INIT_CLUSTER_TOKEN" ]; then
	for i in ${!ETCD_NODES_ARRAY[@]}; do
            if [ "$ETCD_INIT_CLUSTER_TOKEN" != "${ETCD_init_cluster_token[$i]}" ]; then
		ETCD_INIT_CLUSTER_TOKEN_MISMATCH=true
		break
	    fi
	done
	if $ETCD_INIT_CLUSTER_TOKEN_MISMATCH; then
	    echo "[error] Detected inconsistent --initial-cluster-token from etcd pod manifests. Please review the retrieved etcd manifests at $WORKDIR. Abort."
	    exit 1
	fi
    fi

    # Same value from etcd config flags --name and --initial-advertise-peer-urls would be used for command "etcdctl snapshot restore".
    # But the value of --initial-cluster is usually not synchronized across etcd nodes, because new node joining the cluster via 
    # Runtime Reconfiguration (which is the strategy used when cluster-api/kubeadm bootstraps control plane cluster or conducts rolling
    # update on cluster) will have a longer --initial-cluster value than existing nodes.
    # Hence, we have to construct ETCD_INIT_CLUSTER from ETCD_name and ETCD_init_adv_peer_urls
    ETCD_INIT_CLUSTER=""

    for i in ${!ETCD_NODES_ARRAY[@]}; do
	if [ -z "$ETCD_INIT_CLUSTER" ]; then
            ETCD_INIT_CLUSTER="${ETCD_name[$i]}=${ETCD_init_adv_peer_urls[$i]}"
	else
            ETCD_INIT_CLUSTER+=",${ETCD_name[$i]}=${ETCD_init_adv_peer_urls[$i]}"
        fi
    done

    SKIP_HASH_CHECK_FLAG=""
    if $SKIP_HASH_CHECK; then
	SKIP_HASH_CHECK_FLAG="--skip-hash-check"
    fi

    ETCD_INIT_CLUSTER_TOKEN_FLAG=""
    if [ -n "$ETCD_INIT_CLUSTER_TOKEN" ]; then
	ETCD_INIT_CLUSTER_TOKEN_FLAG="--initial-cluster-token '$ETCD_INIT_CLUSTER_TOKEN'"
    fi

    RESTORE_SCRIPT=()

    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
        echo "[info]  - generating script for restoring snapshot data on node $node ..."
	cat > $WORKDIR/restore_etcd_data_$node.sh << EOF
#!/bin/bash
set -euo pipefail
set -x

name=${ETCD_name[$i]}
initCluster=$ETCD_INIT_CLUSTER
initAdvPeerUrls=${ETCD_init_adv_peer_urls[$i]}

# prepare etcdctl/etcdutl cli
cp \$(find /var/lib/containerd/ -name $ETCD_CLI_FOR_RESTORE | grep "bin/$ETCD_CLI_FOR_RESTORE" | head -n 1) /usr/local/bin/   

ETCDCTL_API=3 $ETCD_CLI_FOR_RESTORE snapshot restore $REMOTE_WORKDIR/$(basename $SNAPSHOT_FILE) \\
    --data-dir $REMOTE_WORKDIR/etcd-datadir-restored \\
    --name \${name} \\
    --initial-cluster \${initCluster} $ETCD_INIT_CLUSTER_TOKEN_FLAG \\
    --initial-advertise-peer-urls \${initAdvPeerUrls} $SKIP_HASH_CHECK_FLAG

if [ \$? -eq 0 ]; then
    echo "RESTORE SUCCESS"
fi
EOF

        RESTORE_SCRIPT[$i]=$WORKDIR/restore_etcd_data_$node.sh
    done

    STOP_SCRIPT="$WORKDIR/stop_etcd.sh"

    echo "[info]  - generating script for stopping etcd pod ..."
    cat > $STOP_SCRIPT << EOF
#!/bin/bash
set -euo pipefail
set -x

ETCD_MANIFEST="$ETCD_MANIFEST_PATH"

# stop etcd pod by moving away the pod manifest
if [ -f \${ETCD_MANIFEST} ]; then
  mv \${ETCD_MANIFEST} $REMOTE_WORKDIR/etcd.yaml
  sleep 3
fi

ETCD_STOPPED=false

# wait for 3 x 5 = 15s for etcd to stop
for i in \$(seq 5); do
    if [ -n "\$(pidof etcd)" ]; then
	kill \$(pidof etcd)
    else
        break
    fi
done

if [ -z "\$(pidof etcd)" ]; then
    echo "ETCD STOPPED"
fi
EOF

    RESTART_SCRIPT="$WORKDIR/restart_etcd_restored.sh"

    echo "[info]  - generating script for restarting etcd with restored data ..."
    cat > $RESTART_SCRIPT << EOF
#!/bin/bash
set -euo pipefail
set -x

dataDir="$DATA_DIR"
ETCD_MANIFEST="$ETCD_MANIFEST_PATH"

# replace the old etcd data dir with the restored data
if [ -d "\${dataDir}" ]; then
    mkdir $REMOTE_WORKDIR/etcd-datadir-backup
    mv \${dataDir}/* -t $REMOTE_WORKDIR/etcd-datadir-backup
fi
cp -pR $REMOTE_WORKDIR/etcd-datadir-restored/* \${dataDir}/

# start etcd pod by restoring the pod manifest
cp -p $REMOTE_WORKDIR/etcd.yaml \${ETCD_MANIFEST} 

if [ -f \${ETCD_MANIFEST} ]; then
    echo "ETCD RESTARTING"
fi
EOF
    
    echo "[info]  Sending remote scripts and snapshot file to each etcd node ..."
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (scp -q -o StrictHostKeyChecking=no -i $SSH_KEY $SNAPSHOT_FILE ${RESTORE_SCRIPT[$i]} $RESTART_SCRIPT $STOP_SCRIPT $SSH_USER@${node}:$REMOTE_WORKDIR/) \
		&& (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo chmod +x $REMOTE_WORKDIR/$(basename ${RESTORE_SCRIPT[$i]}) $REMOTE_WORKDIR/$(basename $STOP_SCRIPT) $REMOTE_WORKDIR/$(basename $RESTART_SCRIPT)"); then
	    if $DEBUG; then
		    echo "[debug] - sent scripts $(basename ${RESTORE_SCRIPT[$i]}), $(basename $STOP_SCRIPT), $(basename $RESTART_SCRIPT) and snapshot file $SNAPSHOT_FILE to node $node"
	    fi
	else
            echo "[error] Failed to send remote scripts and snapshot file to node $node. Exit."
	    exit 1
	fi
    done
    echo "[info]  Sent remote scripts and snapshot file to each etcd node."

    echo ""
    echo "[final confirm]  ETCD version: $ETCD_VERSION"
    echo "[final confirm]  Snapshot file to restore: $SNAPSHOT_FILE"
    echo "[final confirm]"
    echo "[final confirm]  Please review \"$ETCD_CLI_FOR_RESTORE snapshot restore\" command flags for each node in the ${#ETCD_NODES_ARRAY[@]}-node etcd cluster:"
    for i in ${!ETCD_NODES_ARRAY[@]}; do 
        echo "[final confirm]  ##  node ${ETCD_NODES_ARRAY[$i]}:"
	echo "[final confirm]      --name ${ETCD_name[$i]}"
	echo "[final confirm]      --initial-cluster $ETCD_INIT_CLUSTER"
	echo "[final confirm]      --initial-advertise-peer-urls ${ETCD_init_adv_peer_urls[$i]}"
        if [ -n "$ETCD_INIT_CLUSTER_TOKEN" ]; then
	    echo "[final confirm]      $ETCD_INIT_CLUSTER_TOKEN_FLAG"
	fi
	if $SKIP_HASH_CHECK; then
	    echo "[final confirm]      $SKIP_HASH_CHECK_FLAG"
	fi
	echo "[final confirm]"
    done

    echo ""
    while true; do
	read -t 30 -p "Confirm restore [Y/N]: " answer
	case $answer in
	    Y|y)
		break
	       	;;
	    N|n)
	        echo "Stop restore. Bye."
		exit 1
		;;
	    *)
	        echo "Pleaes enter Y or N."
		;;
	esac
    done
	    
    echo "[info]  Executing remote restore script ..."
    RESTORE_DATA_FAIL=false
    # NODE_RESTORED=0
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo $REMOTE_WORKDIR/$(basename ${RESTORE_SCRIPT[$i]}) 2>&1 | tee $REMOTE_WORKDIR/restore_etcd_data_$node.log" | grep "RESTORE SUCCESS" > /dev/null); then
	    # (( NODE_RESTORED++ ))
	    echo "[info]  - node $node: restored snapshot to $REMOTE_WORKDIR/etcd-datadir-restored successfully"
	else
	    RESTORE_DATA_FAIL=true
            echo "[error] - node $node: failed to restore snapshot to $REMOTE_WORKDIR/etcd-datadir-restored"
	fi
    done

    if $RESTORE_DATA_FAIL; then
        echo "[error] Faile to restore snapshot to $REMOTE_WORKDIR/etcd-datadir-restored on some nodes. To troubleshoot, please check the following on each etcd node."
	echo "[error]  - snapshot file: $REMOTE_WORKDIR/$(basename $SNAPSHOT_FILE)"
	echo "[error]  - script for restoring snapshot data: $REMOTE_WORKDIR/restore_etcd_data_<NODE>.sh"
	echo "[error]  - log of the restore script: $REMOTE_WORKDIR/restore_etcd_data_<NODE>.log"
	echo "[error]  - the restored etcd data: $REMOTE_WORKDIR/etcd-datadir-restored"
	exit 1
    else
	echo "[info]  Successfully restored snapshot to $REMOTE_WORKDIR/etcd-datadir-restored on each etcd nodes."
    fi

    echo "[info]  Executing remote stop script ..."
    ALL_ETCD_STOPPED=true
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo $REMOTE_WORKDIR/$(basename $STOP_SCRIPT) 2>&1 | tee $REMOTE_WORKDIR/stop_etcd_$node.log" | grep "ETCD STOPPED" > /dev/null); then
            echo "[info]  etcd is stopped on node $node ..."
	else
	    ALL_ETCD_STOPPED=false
	    echo "[error] failed to stop etcd on node $node"
	fi
    done

    if $ALL_ETCD_STOPPED; then
	echo "[info]  etcd is stopped on each node."
    else
	echo "[error] Failed to stop etcd on some etcd nodes. To troubleshoot, please check the following on each etcd node."
	echo "[error]  - snapshot file: $REMOTE_WORKDIR/$(basename $SNAPSHOT_FILE)"
	echo "[error]  - script for restoring snapshot data: $REMOTE_WORKDIR/restore_etcd_data_<NODE>.sh"
	echo "[error]  - log of the restore script: $REMOTE_WORKDIR/restore_etcd_data_<NODE>.log"
	echo "[error]  - the restored etcd data: $REMOTE_WORKDIR/etcd-datadir-restored"
	echo "[error]  - script for stopping etcd: $REMOTE_WORKDIR/$(basename $STOP_SCRIPT)"
	echo "[error]  - log of the stop script: $REMOTE_WORKDIR/stop_etcd_<NODE>.log"
	exit 1
    fi

    echo "[info]  Executing remote restart script ..."
    ALL_ETCD_STARTING=true
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo $REMOTE_WORKDIR/$(basename $RESTART_SCRIPT) 2>&1 | tee $REMOTE_WORKDIR/restart_etcd_restored_$node.log" | grep "ETCD RESTARTING" > /dev/null); then
            echo "[info]  etcd is restarting with restored data on node $node ..."
	else
	    ALL_ETCD_STARTING=false
	    echo "[error] failed to restart etcd with restored data on node $node"
	fi
    done

    if $ALL_ETCD_STARTING; then
	echo "[info]  This etcd restore procedure completes successfully. Please run \"etcdctl -w table endpoint --cluster status\" for cluster health check."
    else
	echo "[error] Failed to restart etcd with restored data on some etcd nodes. To troubleshoot, please check the following on each etcd node."
	echo "[error]  - snapshot file: $REMOTE_WORKDIR/$(basename $SNAPSHOT_FILE)"
	echo "[error]  - script for restoring snapshot data: $REMOTE_WORKDIR/restore_etcd_data_<NODE>.sh"
	echo "[error]  - log of the restore script: $REMOTE_WORKDIR/restore_etcd_data_<NODE>.log"
	echo "[error]  - the restored etcd data: $REMOTE_WORKDIR/etcd-datadir-restored"
	echo "[error]  - script for stopping etcd: $REMOTE_WORKDIR/$(basename $STOP_SCRIPT)"
	echo "[error]  - log of the stop script: $REMOTE_WORKDIR/stop_etcd_<NODE>.log"
	echo "[error]  - script for restarting etcd with restored snapshot data: $REMOTE_WORKDIR/$(basename $RESTART_SCRIPT)"
	echo "[error]  - log of the restart script: $REMOTE_WORKDIR/restart_etcd_restored_<NODE>.log"
	echo "[error]  - the etcd data dir backup as prior the restore attempt: $REMOTE_WORKDIR/etcd-datadir-backup"
	exit 1
    fi
}

main() {
    echo ""
    echo "[info]  Start restoring the ${#ETCD_NODES_ARRAY[@]}-node etcd cluster consisting with nodes:"
    for node in ${ETCD_NODES_ARRAY[@]}; do 
        echo "[info]  - ${node}"
    done

    # make sure we can SSH to each etcd node
    check_etcd_node_connectivity

    # create remote workdir on each etcd node
    create_remote_workdir

    # fetch etcd manifest from each node and check if etcd uses same image version across the cluster
    get_etcd_manifest_check_version

    # get etcdctl/etcdutl cli from etcd node, which is required to print snapshot status
    get_etcdctl_from_etcd_node

    if $PULL_SNAPSHOT_FROM_ETCD_NODES; then
	select_snapshot_from_etcd_node
    else
        echo "[info]  Checking snapshot db file ${SNAPSHOT_FILE} status ..."
        echo ""
        echo "[info]  cmd: $ETCD_CLI_FOR_RESTORE snapshot status ${SNAPSHOT_FILE} -w table"
        $WORKDIR/$ETCD_CLI_FOR_RESTORE snapshot status "${SNAPSHOT_FILE}" -w table
        echo ""
    fi

    if $DEBUG; then
        echo "[debug] SSH key:              $SSH_KEY"
        echo "[debug] SSH user:             $SSH_USER"
        echo "[debug] etcd data dir:        $DATA_DIR"
	echo "[debug] etcd pod manifest:    $ETCD_MANIFEST_PATH"
        echo "[debug] snapshot file:        \"${SNAPSHOT_FILE:-}\""
        echo "[debug] etcd nodes:           \"${ETCD_NODES_ARRAY[@]}\""
        echo -n "[debug] SKIP_HASH_CHECK:      "
        if $SKIP_HASH_CHECK; then echo "true"; else echo "false"; fi
        echo -n "[debug] PULL_SNAPSHOT_FROM_ETCD_NODES: "
        if $PULL_SNAPSHOT_FROM_ETCD_NODES; then echo "true"; else echo "false"; fi
	echo "[debug] work directory:       $WORKDIR"
    fi

    # restore
    restore_etcd

    exit 0
}

main
