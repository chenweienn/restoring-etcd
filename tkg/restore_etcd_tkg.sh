#!/bin/bash

set -uo pipefail
# set -e
# set -x

SCRIPT_NAME=$(basename $0)

usage() {
   echo "Usage:"
   echo "  $SCRIPT_NAME [-s|--snapshot-files <filename>] -d|--data-dir <output dir> -n|--etcd-nodes <node> <node> ... -k|--ssh-key <SSH key> -u|--ssh-user <SSH user> [--skip-hash-check] [-h|--help]"
   echo ""
   echo "Flags:"
   echo "      -d, --data-dir string                Absolute path to etcd data directory in master nodes"
   echo "      -h, --help                           Print usage"
   echo "      -k, --ssh-key string                 SSH key to access each etcd nodei (\$SSH_KEY)"
   echo "      -n, --etcd-nodes []string            Hostname or IP of each etcd node in the cluster (\$ETCD_NODES)"
   echo "      -u, --ssh-user string                SSH user to access each etcd node (\$SSH_USER)"
   echo "      -s, --snapshot-file string           Etcd snapshot \"db\" file"
   echo "          --skip-hash-check                Ignore snapshot integrity hash value (required if copied from data directory)"
   echo "          --debug                          Print debug level log"
   echo ""
   echo "Examples:"
   echo "      # Restore the etcd snapshot snapshot.db to dir /var/lib/etcddisk/etcd on each etcd node"
   echo "      export ETCD_NODES=\"10.0.0.3 10.0.0.4 10.0.0.5\" SSH_USER=capi SSH_KEY=/home/bob/capi.key"
   echo "      $(basename $0) -s snapshot.db -d /var/lib/etcddisk/etcd"
   echo ""
   echo "      # Restore the snapshot file-db copied from etcd data directory"
   echo "      $(basename $0) -s file-db -d /var/lib/etcddisk/etcd --skip-hash-check"
   echo ""
   echo "      # When --snapshot-file is missing, take snapshot db from each etcd node data-dir; interactively you select one to restore"
   echo "      $(basename $0) -d /etcddisk/etcd --skip-hash-check"
   echo ""
   exit 0
}

DEBUG=false
SKIP_HASH_CHECK=false
WORKDIR="$PWD/script-workdir.$(date -u +%y-%m-%dT%H:%M:%S)"
mkdir $WORKDIR

# when --snapshot-file is missing
PULL_SNAPSHOT_FROM_ETCD_NODES=true

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]
do
  case $1 in
      -h|--help)
          usage
          ;;
      -d|--data-dir)
          if [[ ${2:-} =~ ^\/.*$ ]]; then
            DATA_DIR=$2
            shift; shift
          else
            echo "Error: the provided absolute path to etcd data directory \"${2:-}\" is invalid"
            usage
	  fi
          ;;
      -k|--ssh-key)
          if [ -n ${2:-} ] && [ -f ${2:-} ]; then
            SSH_KEY=$2
	    shift; shift
	  else
            echo "Error: the provided SSH key \"${2:-}\" is invalid"
	    usage
	  fi
	  ;;
      -u|--ssh-user)
	  if [ -n ${2:-} ]; then
	    SSH_USER=$2
	    shift; shift
	  else
	    echo "Error: please provide an SSH user to --ssh-user"
	    usage
	  fi
	  ;;
      --skip-hash-check)
	  SKIP_HASH_CHECK=true
	  shift
	  ;;
      -s|--snapshot-file)
	  PULL_SNAPSHOT_FROM_ETCD_NODES=false
	  if [ -f ${2:-""} ]; then
            SNAPSHOT_FILE=$2
	    shift; shift
	  else
	    echo "Error: the provided snapshot \"${2:-}\" is invalid"
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
	  echo "Error: unreconganized flag $1"
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
    for node in $ETCD_NODES; do
            ETCD_NODES_ARRAY+=("$node")
    done
fi
    
if [ ${#ETCD_NODES_ARRAY[@]} -eq 0 ]; then
    echo "Error: please provide one or more etcd nodes via --etcd-nodes (\$ETCD_NODES)"
    usage
fi

# debug
# read -t 10 -p "To restore the clsuter, I want to use the retrieved snapshot from node [ $(for i in ${!ETCD_NODES_ARRAY[@]}; do if [ $i -eq 0 ]; then echo -n "${ETCD_NODES_ARRAY[$i]}"; else echo -n ", ${ETCD_NODES_ARRAY[$i]}"; fi; done) ]: " answer


# check SSH_KEY and SSH_USER
if [ -z ${SSH_KEY:-} ] || [ -z ${SSH_USER:-} ]; then
  echo "Error: please provide both --ssh-key (\$SSH_KEY) and --ssh-user (\$SSH_USER)"
  usage
fi

if $PULL_SNAPSHOT_FROM_ETCD_NODES; then
  SKIP_HASH_CHECK=true
fi

check_etcd_node_connectivity() {
    if $DEBUG; then
	echo "[debug] Checking SSH connectivity with each etcd node..."
    fi
    ETCD_NODES_CONN=()
    ETCD_CONN_ISSUE=false
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i $SSH_KEY $SSH_USER@${node} exit); then
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

get_etcd_manifest_check_version_tkg() {
    if $DEBUG; then
	echo "[debug] Copying etcd manifest from each node..."
    fi

    # to-do: check kubelet flag --pod-manifest-path and key staticPodPath in KubeletConfiguration; the flag --pod-manifest-path takes precedence
    ETCD_MANIFEST_PATH="/etc/kubernetes/manifests/etcd.yaml"

    ETCD_MANIFEST=()
    ETCD_IMG_TAG=()
    ETCD_MANIFEST_NOTFOUND=false
    ETCD_VERSION_MISMATCH=false
    ETCD_IMG_TAG_NON_EMPTY=""
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo cp $ETCD_MANIFEST_PATH /tmp/etcd.yaml; sudo chmod +r /tmp/etcd.yaml") \
            && (scp -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node}:/tmp/etcd.yaml $WORKDIR/etcd-$node.yaml) \
	    && [ -f $WORKDIR/etcd-$node.yaml ]; then
	        ETCD_MANIFEST[$i]="$WORKDIR/etcd-$node.yaml"
                ETCD_IMG_TAG[$i]=$(cat ${ETCD_MANIFEST[$i]} | grep "image:" | cut -d':' -f3)
	fi

	if [ -z ${ETCD_MANIFEST[$i]} ]; then
	    ETCD_MANIFEST_NOTFOUND=true
	    echo "[error] - node $node: missing $ETCD_MANIFEST_PATH."
	elif [ -z ${ETCD_IMG_TAG[$i]} ]; then
	    echo "[error] - node $node: $ETCD_MANIFEST_PATH exists, but failed to parse out etcd version from \"image\" key."
	else
            if [ -z $ETCD_IMG_TAG_NON_EMPTY ]; then
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

    for i in ${!ETCD_NODES_ARRAY[@]}; do
	if [ -n ${ETCD_IMG_TAG[$i]} ] && [ ${ETCD_IMG_TAG[$i]} != $ETCD_IMG_TAG_NON_EMPTY ]; then
            ETCD_VERSION_MISMATCH=true
	    break
	fi
    done
    
    if $ETCD_VERSION_MISMATCH ; then
	echo "[error] Detected etcd version mismatch across the ${#ETCD_NODES_ARRAY[@]}-node etcd cluster:"
	for i in ${!ETCD_NODES_ARRAY[@]}; do
	     if [ -n ${ETCD_IMG_TAG[$i]} ]; then
                 echo "[info]  - node ${ETCD_NODES_ARRAY[$i]}: etcd image tag ${ETCD_IMG_TAG[$i]} in etcd manifest."
	     fi
	done
	echo "[error] You may be in the middle of cluster upgrade. Please get help from your support team. Exit."
	exit 1
    fi

    # image tag v3.5.0_vmware.7 maps to version 3.5.0
    ETCD_VERSION=$(echo $ETCD_IMG_TAG_NON_EMPTY | grep -o -E "[0-9]+\.[0-9]+\.[0-9]+")

    echo "[info]  Passed etcd version check. Detected same image tag $ETCD_IMG_TAG_NON_EMPTY in etcd manifest from all etcd nodes."
    echo "[info]  Etcd manifests are saved into $WORKDIR/."
}

get_etcdctl_from_etcd_node_tkg() {
    # scp compatible etcdctl cli from etcd node to the jumpbox where you run this script
    ETCDCTL_VERSION=""
    for node in ${ETCD_NODES_ARRAY[@]}; do
	ETCDCTL_FROM_NODE=${node}
        if [ -z ${ETCDCTL_VERSION} ]; then
	    ETCDCTL_VERSION=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY $SSH_USER@${node} "sudo cp \$(sudo find /var/lib/containerd/ -name etcdctl | grep "bin\/etcdctl" | head -n 1) /tmp/etcdctl; sudo chmod +r /tmp/etcdctl; sudo /tmp/etcdctl version" 2>&1 | grep -i "etcdctl version" | cut -d' ' -f3)
	    if [ $ETCDCTL_VERSION = ${ETCD_VERSION} ] && (scp -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node}:/tmp/etcdctl $WORKDIR/etcdctl) && [ -f "$WORKDIR/etcdctl" ]; then
		sudo chmod +x $WORKDIR/etcdctl
	        break
	    fi
	fi
    done

    # logging
    if [ -x $WORKDIR/etcdctl ]; then 
	echo "[info]  Copied etcdctl cli (version ${ETCDCTL_VERSION}) from node ${ETCDCTL_FROM_NODE} to $WORKDIR/etcdctl."
    else
        echo "[error] Failed to find compatible etcdctl cli from any etcd nodes."
	exit 1
    fi
}

select_snapshot_from_etcd_nodes_tkg() {
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
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo cp $DATA_DIR/member/snap/db /tmp/db; sudo chmod +r /tmp/db") \
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
        if [ -f ${ETCD_SNAPSHOT_FILE[$i]} ]; then
            echo  "[info]  - node ${ETCD_NODES_ARRAY[$i]} snapshot status"
	    echo  "[info]  - location: ${ETCD_SNAPSHOT_FILE[$i]}"
            $WORKDIR/etcdctl snapshot status ${ETCD_SNAPSHOT_FILE[$i]} -w table
            echo ""
        fi
    done

    while true; do
        read -t 20 -p "To restore the clsuter, I want to use the retrieved snapshot from node [ $(for i in ${!ETCD_NODES_ARRAY[@]}; do if [ $i -eq 0 ]; then echo -n "${ETCD_NODES_ARRAY[$i]}"; else echo -n ", ${ETCD_NODES_ARRAY[$i]}"; fi; done) ]: " answer
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

check_snapshot_status() {
    if [ -z $SNAPSHOT_FILE ]; then
	echo "[error]  Please provide snapshot via flag --snapshot-file ($SCRIPT_NAME --help)."
    fi

    echo "[info]  Checking snapshot db file status ..."
    echo ""
    echo "[info]  snapshot $PWD/$SNAPSHOT_FILE status"
    $WORKDIR/etcdctl snapshot status $SNAPSHOT_FILE -w table
    echo ""
}

restore_etcd_tkg() {
    echo "[info]  Creating remote work dir in each etcd node ..."
    # same timestamp for WORKDIR and REMOTE_WORKDIR
    REMOTE_WORKDIR=/home/$SSH_USER/$(basename $WORKDIR)

    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo mkdir -p $REMOTE_WORKDIR; sudo chown $SSH_USER:$SSH_USER $REMOTE_WORKDIR"); then
	    if $DEBUG; then
		echo "[debug] - node $node: created remote work dir $REMOTE_WORKDIR"
	    fi
	else
            echo "[error] Failed to create remote work dir $REMOTE_WORKDIR in node $node. Exit."
	    exit 1
	fi
    done
    echo "[info]  Created remote work dir $REMOTE_WORKDIR in each etcd node."

    echo "[info]  Generating remote restore script for each etcd node ..."

    ETCD_name=()
    ETCD_init_cluster=()
    ETCD_init_adv_peer_urls=()
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	ETCD_name[$i]=$(cat ${ETCD_MANIFEST[$i]} | grep "\-\-name" | cut -d'=' -f2)
	ETCD_init_cluster[$i]=$(cat ${ETCD_MANIFEST[$i]} | grep "\-\-initial-cluster=" | awk -F'initial-cluster=' '{print $2}')
	ETCD_init_adv_peer_urls[$i]=$(cat ${ETCD_MANIFEST[$i]} | grep "\-\-initial-advertise-peer-urls=" | cut -d'=' -f2)
    done

    # store the longest value of --initial-cluster into ETCD_INIT_CLUSTER
    # do a simple check: the number of nodes (${#ETCD_NODES_ARRAY[@]}) should be equel to the number of members in ETCD_INIT_CLUSTER
    # etcdctl snapshot restore ... would do thorough check
    ETCD_INIT_CLUSTER=""
    ETCD_INIT_CLUSTER_FROM_NODE=""
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	init_cluster=${ETCD_init_cluster[$i]}
	if [ ${#init_cluster} -gt ${#ETCD_INIT_CLUSTER} ]; then
	    ETCD_INIT_CLUSTER=$init_cluster
	    ETCD_INIT_CLUSTER_FROM_NODE=${ETCD_NODES_ARRAY[$i]}
	fi
    done
    IFS="," read -a array_to_count_members <<< "\"$ETCD_INIT_CLUSTER\""
    if [ ${#array_to_count_members[@]} -ne ${#ETCD_NODES_ARRAY[@]} ]; then
	echo "[error] number of members in --initial-cluster in node $ETCD_INIT_CLUSTER_FROM_NODE is ${#array_to_count_members[@]}, which is not equal to the number of etcd nodes ${#ETCD_NODES_ARRAY[@]}."
        exit 1
    fi

    REMOTE_RESTORE_SCRIPT=()
    SKIP_HASH_CHECK_FLAG=""
    if $SKIP_HASH_CHECK; then
	SKIP_HASH_CHECK_FLAG="--skip-hash-check"
    fi
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
        echo "[info]  - generating remote restore script for node $node ..."
	cat > $WORKDIR/etcd-restore-$node.sh << EOF
#!/bin/bash
set -euo pipefail
set -x

name=${ETCD_name[$i]}
initCluster=$ETCD_INIT_CLUSTER
initAdvPeerUrls=${ETCD_init_adv_peer_urls[$i]}
dataDir=$DATA_DIR

# prepare etcdctl cli
cp \$(find /var/lib/containerd/ -name etcdctl | head -n 1) /usr/local/bin/   

ETCD_MANIFEST="/etc/kubernetes/manifests/etcd.yaml"

# stop etcd container by moving away its manifest
if [ -f \${ETCD_MANIFEST} ]; then
  mv \${ETCD_MANIFEST} /etc/kubernetes/
  sleep 5
fi

if [ -n "\$(pidof etcd)" ]; then
  killall etcd
  sleep 5
fi

mv \${dataDir} \${dataDir}-\$(date -u +%y-%m-%dT%H:%M:%S)

ETCDCTL_API=3 etcdctl snapshot restore $REMOTE_WORKDIR/$(basename $SNAPSHOT_FILE) \\
    --data-dir \${dataDir} \\
    --name \${name} \\
    --initial-cluster \${initCluster} \\
    --initial-advertise-peer-urls \${initAdvPeerUrls} $SKIP_HASH_CHECK_FLAG
EOF
        REMOTE_RESTORE_SCRIPT[$i]=$WORKDIR/etcd-restore-$node.sh
    done

    echo "[info]  Sending remote restore script and snapshot file to each etcd node ..."
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (scp -q -o StrictHostKeyChecking=no -i $SSH_KEY $SNAPSHOT_FILE ${REMOTE_RESTORE_SCRIPT[$i]} $SSH_USER@${node}:$REMOTE_WORKDIR/) \
		&& (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo chmod +x $REMOTE_WORKDIR/etcd-restore-${node}.sh"); then
	    if $DEBUG; then
		echo "[debug] - sent remote restore script etcd-restore-${node}.sh and snapshot $SNAPSHOT_FILE to node $node"
	    fi
	else
            echo "[error] Failed to send remote restore script and snapshot file to node $node. Exit."
	    exit 1
	fi
    done
    echo "[info]  Sent remote restore script and snapshot file to each etcd node."

    echo ""
    echo "[final confirm]  Please review \"etcdctl snapshot restore\" flags for each node in the ${#ETCD_NODES_ARRAY[@]}-node etcd cluster:"
    for i in ${!ETCD_NODES_ARRAY[@]}; do 
        echo "[final confirm]  ##  node ${ETCD_NODES_ARRAY[$i]}:"
	echo "[final confirm]    --name ${ETCD_name[$i]}"
	echo "[final confirm]    --initial-cluster $ETCD_INIT_CLUSTER"
	echo "[final confirm]    --initial-advertise-peer-urls ${ETCD_init_adv_peer_urls[$i]}"
	echo "[final confirm]"
    done
    echo "[final confirm]  Restore from snapshot file $SNAPSHOT_FILE."

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
    NODE_RESTORED=0
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo $REMOTE_WORKDIR/etcd-restore-${node}.sh 2>&1 | tee $REMOTE_WORKDIR/etcd-restore.log" | grep "restored snapshot" > /dev/null); then
	    (( NODE_RESTORED++ ))
	    echo "[info]  - node $node: restored snapshot to $DATA_DIR successfully"
	else
	    RESTORE_DATA_FAIL=true
            echo "[error] - node $node: failed to restored snapshot to $DATA_DIR"
	fi
    done

    if $RESTORE_DATA_FAIL; then
        echo "[error] Faile to restore snapshot to $DATA_DIR in some nodes. Please check $REMOTE_WORKDIR/etcd-restore.log in etcd nodes."
	exit 1
    else
	echo "[info]  Successfully restored snapshot to $DATA_DIR in each etcd nodes."
    fi

    echo "[info]  Starting etcd in each etcd node ..."
    ALL_ETCD_STARTING=true
    for i in ${!ETCD_NODES_ARRAY[@]}; do
	node=${ETCD_NODES_ARRAY[$i]}
	if (ssh -q -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@${node} "sudo mv /etc/kubernetes/etcd.yaml $ETCD_MANIFEST_PATH"); then
            echo "[info]  etcd is starting in node $node ..."
	else
	    ALL_ETCD_STARTING=false
	    echo "[error] failed to mv etcd manifest to $ETCD_MANIFEST_PATH in node $node"
	fi
    done

    if $ALL_ETCD_STARTING; then
	echo "[info]  Restore procedure completes successfully. Please run \"etcdctl -w table endpoint --cluster status\" for cluster health check."
    else
	echo "[error] Failed to move etcd manifest to $ETCD_MANIFEST_PATH in some etcd nodes. Exit."
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

    # fetch etcd manifest from each node and check if etcd uses same image version across the cluster
    get_etcd_manifest_check_version_tkg

    # get etcdctl cli from etcd node, which is required to print snaoshot status
    get_etcdctl_from_etcd_node_tkg

    if $PULL_SNAPSHOT_FROM_ETCD_NODES; then
	select_snapshot_from_etcd_nodes_tkg
    else
        check_snapshot_status
    fi

    if $DEBUG; then
        echo "[debug] SSH key:              $SSH_KEY"
        echo "[debug] SSH user:             $SSH_USER"
        echo "[debug] data dir:             $DATA_DIR"
        echo "[debug] snapshot file:        \"${SNAPSHOT_FILE:-}\""
        echo "[debug] etcd nodes:           \"${ETCD_NODES_ARRAY[@]}\""
        echo -n "[debug] SKIP_HASH_CHECK:   "
        if $SKIP_HASH_CHECK; then echo "true"; else echo "false"; fi
        echo -n "[debug] PULL_SNAPSHOT_FROM_ETCD_NODES: "
        if $PULL_SNAPSHOT_FROM_ETCD_NODES; then echo "true"; else echo "false"; fi
	echo "[debug] output dir:           $WORKDIR"
    fi

    # restore
    restore_etcd_tkg

    exit 0
}

main
