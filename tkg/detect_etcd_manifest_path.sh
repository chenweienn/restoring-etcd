#!/bin/bash

if [ "$1" = "--debug" ]; then
  set -x
fi

KUBELET_PID=$(pidof kubelet)
if [ -z "${KUBELET_PID}" ]; then
  echo "[error]  kubelet is not running. Exit." 1>&2
  exit 1
fi

KUBELET_CMD=$(ps -p ${KUBELET_PID} -o args -ww --no-headers)

# echo "[debug]  kubelet command: ${KUBELET_CMD}"
# echo ""

# detect kubelet flag "--pod-manifest-path=<PATH>"
STATIC_MANIFEST_PATH=$(echo "${KUBELET_CMD}" | awk -F'pod-manifest-path=' '{print $2}' | awk '{print $1}')

if [ -z "${STATIC_MANIFEST_PATH}" ]; then
  # in case the flag is specified as "--pod-manifest-path <PATH>"
  STATIC_MANIFEST_PATH=$(echo "${KUBELET_CMD}" | awk -F'pod-manifest-path' '{print $2}' | awk '{print $1}')
fi

# if command line flag --pod-manifest-path is not detected, check field staticPodPath in kubelet config file
# https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/

if [ -z "${STATIC_MANIFEST_PATH}" ]; then
  # echo "[debug]  No kubelet flag --pod-manifest-path. Continue checking field staticPodPath in kubelet config file ..."
  KUBELET_CONFIG_FILE=$(echo "${KUBELET_CMD}" | awk -F'--config=' '{print $2}' | awk '{print $1}')
  
  if [ -z "${KUBELET_CONFIG_FILE}" ]; then
    # in case the flag is specified as "--config <PATH>"
    KUBELET_CONFIG_FILE=$(echo "${KUBELET_CMD}" | awk -F'--config' '{print $2}' | awk '{print $1}')
  fi
  
  if [ -f "${KUBELET_CONFIG_FILE}" ]; then
    # echo "[debug]  kubelet config file: ${KUBELET_CONFIG_FILE}"
    STATIC_MANIFEST_PATH=$(cat ${KUBELET_CONFIG_FILE} | grep staticPodPath | awk '{print $2}')
  fi
fi

if [ -d "${STATIC_MANIFEST_PATH}" ]; then
  ETCD_MANIFEST=$(ls -1 ${STATIC_MANIFEST_PATH}/*etcd*)
  if [ -f "${ETCD_MANIFEST}" ]; then
    echo "${ETCD_MANIFEST}"
    exit 0
  else
    echo "[error]  Failed to detect etcd manidest. Exit"
    exit 1
  fi
else
  echo "[error]  Failed to detect static Pod manifest path. Exit."
  exit 1
fi

