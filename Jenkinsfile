pipeline {
  agent {
    kubernetes {
      label 'kaniko-kubectl-conjur'
      defaultContainer 'jnlp'
      yaml """
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: kaniko-kubectl-conjur
spec:
  serviceAccountName: jenkins
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:v1.23.2
    tty: true
    command: ["/busybox/cat"]
    args: ["/dev/null"]
    volumeMounts:
    - { name: workspace, mountPath: /workspace }
  - name: kubectl
    image: bitnami/kubectl:1.29
    command: ["sh","-c","sleep 86400"]
    volumeMounts:
    - { name: workspace, mountPath: /workspace }
  - name: aws
    image: amazon/aws-cli:2.17.0
    command: ["sh","-c","sleep 86400"]
    volumeMounts:
    - { name: workspace, mountPath: /workspace }
  - name: tools
    image: alpine:3.20
    command: ["sh","-c","apk add --no-cache curl jq python3 && sleep 86400"]
    volumeMounts:
    - { name: workspace, mountPath: /workspace }
  volumes:
  - name: workspace
    emptyDir: {}
"""
    }
  }

  environment {
    # ===== Account/Region targets =====
    AWS_ACCOUNT_B   = "ACCOUNT_B"
    AWS_REGION_B    = "REGION_B"
    ECR_REPO        = "YOUR_ECR_REPO"
    IMAGE           = "${AWS_ACCOUNT_B}.dkr.ecr.${AWS_REGION_B}.amazonaws.com/${ECR_REPO}"
    TAG             = "build-${env.BUILD_NUMBER}"
    IMAGE_FULL      = "${IMAGE}:${TAG}"

    K8S_NAMESPACE   = "chatbot"
    EKS_CLUSTER_B   = "YOUR_EKS_CLUSTER_IN_ACCOUNT_B"
    PUBLIC_DOMAIN   = "your-domain.example.com"
    ALB_ACM_ARN     = "arn:aws:acm:REGION_B:ACCOUNT_B:certificate/REPLACE_ME"
    FLOW_ID         = "REPLACE_WITH_YOUR_FLOW_ID"

    # ===== Conjur config =====
    CONJUR_URL          = "https://YOUR_TENANT.secretsmgr.cyberark.cloud"
    CONJUR_ACCOUNT      = "conjur"
    CONJUR_AUTHN_JWT_ID = "jenkins"  // your authn-jwt service id

    # Conjur variable IDs for AWS (Account B) dynamic creds
    AWS_ACCESS_KEY_ID_VAR     = "data/aws/account-b/access_key_id"
    AWS_SECRET_ACCESS_KEY_VAR = "data/aws/account-b/secret_access_key"
    AWS_SESSION_TOKEN_VAR     = "data/aws/account-b/session_token"

    # Conjur variable IDs for Mongo connectivity
    MONGO_HOST_VAR     = "data/mongo/host"
    MONGO_USERNAME_VAR = "data/mongo/username"
    MONGO_PASSWORD_VAR = "data/mongo/password"
  }

  parameters {
    string(name: 'FLOW_ID_PARAM', defaultValue: '', description: 'Override FLOW_ID (optional)')
    string(name: 'PUBLIC_DOMAIN_PARAM', defaultValue: '', description: 'Override domain (optional)')
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Fetch secrets from Conjur') {
      steps {
        container('tools') {
          sh """
            set -e
            cp jenkins/conjur_helpers.sh /tmp/conjur_helpers.sh
            chmod +x /tmp/conjur_helpers.sh
            . /tmp/conjur_helpers.sh

            # Export required env (already set in pipeline env)
            export CONJUR_URL CONJUR_ACCOUNT CONJUR_AUTHN_JWT_ID
            export AWS_ACCESS_KEY_ID_VAR AWS_SECRET_ACCESS_KEY_VAR AWS_SESSION_TOKEN_VAR
            export MONGO_HOST_VAR MONGO_USERNAME_VAR MONGO_PASSWORD_VAR

            # Fetch and export AWS_* + MONGO_URI
            fetch_all_from_conjur

            # Write MONGO_URI to a temp file for later
            echo "$MONGO_URI" > /workspace/MONGO_URI.txt
          """
        }
      }
    }

    stage('Build & Push (Kaniko → ECR in Account B)') {
      steps {
        container('aws') {
          sh """
            set -e
            # Set AWS env from Conjur (exported by previous stage via /workspace)
            export AWS_ACCESS_KEY_ID="$(cat /proc/1/environ | tr '\\0' '\\n' | grep '^AWS_ACCESS_KEY_ID=' | cut -d= -f2-)"
            export AWS_SECRET_ACCESS_KEY="$(cat /proc/1/environ | tr '\\0' '\\n' | grep '^AWS_SECRET_ACCESS_KEY=' | cut -d= -f2-)"
            export AWS_SESSION_TOKEN="$(cat /proc/1/environ | tr '\\0' '\\n' | grep '^AWS_SESSION_TOKEN=' | cut -d= -f2-)"
            # login to ECR in Account B
            aws ecr get-login-password --region ${AWS_REGION_B} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_B}.dkr.ecr.${AWS_REGION_B}.amazonaws.com
          """
        }
        container('kaniko') {
          sh """
            /kaniko/executor \
              --context=/workspace/app \
              --dockerfile=/workspace/app/Dockerfile \
              --destination=${IMAGE_FULL} \
              --snapshotMode=redo \
              --reproducible \
              --cache=true \
              --cache-ttl=24h
          """
        }
      }
    }

    stage('Render manifests for Account B') {
      steps {
        container('tools') {
          sh """
            set -e
            # Image
            sed -i 's#ACCOUNT_B.dkr.ecr.REGION_B.amazonaws.com/YOUR_ECR_REPO:latest#${IMAGE_FULL}#g' k8s/app-langflow/deployment.yaml
            # Flow ID
            if [ -n "${params.FLOW_ID_PARAM}" ]; then FLOW="${params.FLOW_ID_PARAM}"; else FLOW="${FLOW_ID}"; fi
            sed -i 's#FLOW_ID: "REPLACE_WITH_YOUR_FLOW_ID"#FLOW_ID: "'"\${FLOW}"'"#g' k8s/app-langflow/configmap.yaml
            # Domain + ACM
            DOM="${PUBLIC_DOMAIN}"; [ -n "${params.PUBLIC_DOMAIN_PARAM}" ] && DOM="${params.PUBLIC_DOMAIN_PARAM}"
            sed -i 's#your-domain.example.com#'"\${DOM}"'#g' k8s/ingress/alb-ingress.yaml
            sed -i 's#ALB_ACM_ARN_REPLACE#'"\${ALB_ACM_ARN}"'#g' k8s/ingress/alb-ingress.yaml
          """
        }
      }
    }

    stage('Update kubeconfig (Account B)') {
      steps {
        container('aws') {
          sh """
            set -e
            export AWS_ACCESS_KEY_ID="$(cat /proc/1/environ | tr '\\0' '\\n' | grep '^AWS_ACCESS_KEY_ID=' | cut -d= -f2-)"
            export AWS_SECRET_ACCESS_KEY="$(cat /proc/1/environ | tr '\\0' '\\n' | grep '^AWS_SECRET_ACCESS_KEY=' | cut -d= -f2-)"
            export AWS_SESSION_TOKEN="$(cat /proc/1/environ | tr '\\0' '\\n' | grep '^AWS_SESSION_TOKEN=' | cut -d= -f2-)"
            aws eks update-kubeconfig --name ${EKS_CLUSTER_B} --region ${AWS_REGION_B}
          """
        }
      }
    }

    stage('Create/Update K8s Secret from Conjur (Mongo)') {
      steps {
        container('kubectl') {
          sh """
            set -e
            MONGO_URI="$(cat /workspace/MONGO_URI.txt)"
            kubectl -n ${K8S_NAMESPACE} create secret generic mongo-credentials \
              --from-literal=MONGO_URI="$MONGO_URI" \
              --dry-run=client -o yaml | kubectl apply -f -
          """
        }
      }
    }

    stage('Deploy to EKS (Account B)') {
      steps {
        container('kubectl') {
          sh """
            set -e
            kubectl apply -f k8s/namespace.yaml
            kubectl -n ${K8S_NAMESPACE} apply -f k8s/app-langflow/configmap.yaml
            kubectl -n ${K8S_NAMESPACE} apply -f k8s/app-langflow/deployment.yaml
            kubectl -n ${K8S_NAMESPACE} apply -f k8s/app-langflow/service.yaml
            kubectl -n ${K8S_NAMESPACE} apply -f k8s/ingress/alb-ingress.yaml

            kubectl -n ${K8S_NAMESPACE} rollout status deploy/chatbot --timeout=180s
          """
        }
      }
    }
  }

  post {
    always { echo "Build ${env.BUILD_NUMBER} complete" }
  }
}
