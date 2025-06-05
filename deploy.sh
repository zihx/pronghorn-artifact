#!/bin/bash

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
echo $DIR

# Define the directory path
data_dir="volumes/data"
# Check if the directory exists
if [ -d "$data_dir" ]; then
    # Directory exists, so delete it
    echo "Deleting existing directory: $data_dir"
    rm -rf "$data_dir"
fi
mkdir -p "$data_dir"

# Install OpenFaaS
arkade install openfaas --set faasnetes.image=zihuanxue/faas-netes:privileged-containers &> /dev/null
if kubectl get namespace openfaas &> /dev/null; then
    echo "[Completed] OpenFaaS Installed."
else
    echo "[Error] OpenFaaS Installation Unsuccessful."
    exit 1
fi

# Ensure gateway rollout is complete
while true; do
    pod_list=$(kubectl get pods -n openfaas | grep gateway)
    if [ -n "$pod_list" ]; then
        status=$(echo "$pod_list" | grep Running)
        if [ -n "$status" ]; then
            echo "[Completed] Gateway Rollout"
            break;
        else
            echo "[Waiting] Gateway Rollout In Progress"
            sleep 10
        fi
    else
        echo "[Error] No Gateway Pod Found"
        exit 1
    fi
done

# Port forward OpenFaaS Gateway
nohup kubectl port-forward -n openfaas svc/gateway 8080:8080 &

sleep 5s

# Export OpenFaaS Password
export OPENFAAS_PASSWORD=$(kubectl get secret -n openfaas basic-auth -o jsonpath="{.data.basic-auth-password}" | base64 --decode; echo)
echo $OPENFAAS_PASSWORD > .credentials

# Authenticate OpenFaaS
cat .credentials | faas-cli login --username admin --password-stdin

# Deploy MinIO (Object Store)
kubectl apply -f $DIR/minio.yaml
kubectl apply -f $DIR/minio-service.yaml

# Deploy Database
kubectl apply -f $DIR/database/pod.yaml

# Check Database deployment
attempts=0
pod_name=$(kubectl get pod -n stores -o jsonpath='{.items[0].metadata.name}')

while [[ "$attempts" -lt 3 ]]; do
    pod_status=$(kubectl get pod -n stores $pod_name -o jsonpath='{.status.phase}')
    if [[ "$pod_status" == "Running" ]]; then
        echo "[Completed] Database Deployed on Cluster."
        break
    else
        echo "[Waiting] Database Deployment In Progress"
        sleep 10
        attempts=$((attempts+1))
    fi
done

if [[ "$attempts" -eq 3 ]]; then
    echo "[Error] Database Deployment Failed."
    exit 1
fi

# Check MinIO deployment
attempts=0
pod_name=$(kubectl get pod -n stores -o jsonpath='{.items[1].metadata.name}')

while [[ "$attempts" -lt 3 ]]; do
    pod_status=$(kubectl get pod -n stores $pod_name -o jsonpath='{.status.phase}')
    if [[ "$pod_status" == "Running" ]]; then
        echo "[Completed] MinIO Deployed on Cluster."
        break
    else
        echo "[Waiting] MinIO Deployment In Progress"
        sleep 10
        attempts=$((attempts+1))
    fi
done

if [[ "$attempts" -eq 3 ]]; then
    echo "[Error] MinIO Deployment Failed."
    exit 1
fi

# Check if MinIO service is running
attempts=0

while [[ "$attempts" -lt 3 ]]; do
    service_ip=$(kubectl get svc minio-svc -n stores -o jsonpath='{.spec.clusterIP}')
    if [[ -n "$service_ip" ]]; then
        echo "[Completed] MinIO Service Deployed."
        break
    else
        echo "[Waiting] MinIO Service Deployment In Progress"
        sleep 10
        attempts=$((attempts+1))
    fi
done

if [[ "$attempts" -eq 3 ]]; then
    echo "[Error] MinIO Service Deployment Failed."
    exit 1
fi

nohup kubectl port-forward -n stores svc/minio-svc 9000:9000 &

mc alias set myminio http://localhost:9000 minioadmin minioadmin
