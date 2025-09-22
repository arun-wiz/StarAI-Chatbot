pipeline {
  agent {
    kubernetes {
      defaultContainer 'kaniko'
      yaml '''\
apiVersion: v1
kind: Pod
metadata:
  name: kaniko
spec:
  serviceAccountName: jenkins
  containers:
  - name: kubectl
    image: arunrana1214/debian-k8s-awsctl:latest
    command: ["/bin/cat"]
    tty: true
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    command: ["/busybox/sh"]
    tty: true
    volumeMounts:
    - name: kaniko-secret
      mountPath: /kaniko/.docker
  volumes:
  - name: kaniko-secret
    secret:
      secretName: regcred
      items:
      - key: .dockerconfigjson
        path: config.json
'''
    }
  }

  environment {
    REPO_DIR           = 'StarAI-Chatbot'

    // ---- AWS Account(EKS/ECR) ----
    EKS_CLUSTER_NAME_B = 'starai-eks'
    EKS_REGION_B       = 'us-east-1'
    ECR_ACCOUNT        = '879381248241'
    ECR_REGION         = 'us-east-1'
    ECR_REPO           = 'starai-chatbot'
    ECR_IMAGE          = "${ECR_ACCOUNT}.dkr.ecr.${ECR_REGION}.amazonaws.com/${ECR_REPO}:latest"

    // Optional DockerHub mirror (set DOCKERHUB_IMAGE empty to skip)
    DOCKERHUB_IMAGE    = 'arunrana1214/starai-chatbot:latest'

    // Ingress
    PUBLIC_DOMAIN      = 'staraichat.sgcybersec.com'
    ALB_ACM_ARN        = 'arn:aws:acm:us-east-1:879381248241:certificate/35b69081-e4df-4f8f-b51b-d7f5746a0d97'

    // Langflow Flow ID (or override via parameter)
    FLOW_ID            = 'REPLACE_WITH_YOUR_FLOW_ID'
  }

  options { ansiColor('xterm') }

  parameters {
    string(name: 'GIT_REPO', defaultValue: 'Arun-Demos/StarAI-Chatbot', description: 'GitHub org/repo')
    string(name: 'FLOW_ID_PARAM', defaultValue: '', description: 'Override FLOW_ID (optional)')
    string(name: 'PUBLIC_DOMAIN_PARAM', defaultValue: '', description: 'Override domain (optional)')
  }

  stages {

    stage('Clone GitHub Repo') {
      steps {
        container('kubectl') {
          withCredentials([
            conjurSecretCredential(credentialsId: 'github-username', variable: 'GIT_USER'),
            conjurSecretCredential(credentialsId: 'github-token',    variable: 'GIT_TOKEN')
          ]) {
            sh '''
              bash -lc '
                set -euo pipefail
                rm -rf "${REPO_DIR}"
                git clone "https://${GIT_USER}:${GIT_TOKEN}@github.com/${GIT_REPO}.git" "${REPO_DIR}"
              '
            '''
          }
        }
      }
    }

    stage('Fetch AWS Dynamic Secret') {
      steps {
        container('kubectl') {
          withCredentials([
            conjurSecretCredential(credentialsId: 'data-dynamic-Starai', variable: 'AWS_DYNAMIC_SECRET')
          ]) {
            script {
              def creds = readJSON text: AWS_DYNAMIC_SECRET
              env.AWS_ACCESS_KEY_ID     = creds.data.access_key_id
              env.AWS_SECRET_ACCESS_KEY = creds.data.secret_access_key
              env.AWS_SESSION_TOKEN     = creds.data.session_token
              env.AWS_DEFAULT_REGION    = env.ECR_REGION
            }
            sh 'aws sts get-caller-identity'
          }
        }
      }
    }

    stage('Compute Image Tag') {
      steps {
        container('kubectl') {
          script {
            def sha = sh(returnStdout: true, script: "git -C ${env.REPO_DIR} rev-parse --short=12 HEAD").trim()
            def ts  = sh(returnStdout: true, script: "date -u +%Y%m%d%H%M%S").trim()
            env.IMG_TAG         = "${env.BUILD_NUMBER}-${ts}-${sha}"
            env.DH_IMAGE_TAGGED = "${env.DOCKERHUB_IMAGE}".replace(':latest', ":${env.IMG_TAG}")
            env.ECR_IMAGE_TAGGED= "${env.ECR_IMAGE}".replace(':latest', ":${env.IMG_TAG}")
            echo "[INFO] Using image tag: ${env.IMG_TAG}"
          }
        }
      }
    }

    stage('Kaniko Build & Push (DockerHub + ECR)') {
      steps {
        container('kaniko') {
          dir("${env.REPO_DIR}") {
            sh '''
              echo "[INFO] Building image and pushing to DockerHub + ECR..."
              /kaniko/executor \
                --dockerfile=Dockerfile \
                --context=. \
                --destination=${DH_IMAGE_TAGGED} \
                --destination=${ECR_IMAGE_TAGGED} \
                --destination=${DOCKERHUB_IMAGE} \
                --destination=${ECR_IMAGE}
              '''
          }
        }
      }
    }

    stage('Render & Apply DB Secret from Conjur') {
      steps {
        container('kubectl') {
          withCredentials([
            conjurSecretCredential(credentialsId: 'MongoDB-Appuser',        variable: 'MONGO_USERNAME'),
            conjurSecretCredential(credentialsId: 'mongo-app-pass',         variable: 'MONGO_PASSWORD'),
            conjurSecretCredential(credentialsId: 'MongoDB-StarAI-Address', variable: 'MONGO_HOST')
          ]) {
            dir("${env.REPO_DIR}") {
              sh 'bash -lc "chmod +x ci/apply_db_secret.sh && ./ci/apply_db_secret.sh"'
              script { env.KUBECONFIG = "${env.WORKSPACE}/${env.REPO_DIR}/.kubeconfig" }
            }
          }
        }
      }
    }

    stage('Deploy to EKS') {
      steps {
        container('kubectl') {
          dir("${env.REPO_DIR}") {
            script {
              if (params.FLOW_ID_PARAM?.trim()) { env.FLOW_ID = params.FLOW_ID_PARAM }
              if (params.PUBLIC_DOMAIN_PARAM?.trim()) { env.PUBLIC_DOMAIN = params.PUBLIC_DOMAIN_PARAM }
            }
            withEnv([
              "EKS_CLUSTER_NAME_B=${env.EKS_CLUSTER_NAME_B}",
              "EKS_REGION_B=${env.EKS_REGION_B}",
              "ECR_IMAGE=${env.ECR_IMAGE}",
              "ECR_IMAGE_TAGGED=${env.ECR_IMAGE_TAGGED}",
              "PUBLIC_DOMAIN=${env.PUBLIC_DOMAIN}",
              "ALB_ACM_ARN=${env.ALB_ACM_ARN}",
              "FLOW_ID=${env.FLOW_ID}"
            ]) {
              sh 'bash -lc "chmod +x ci/deploy.sh && ./ci/deploy.sh"'
            }
          }
        }
      }
    }
  }

  post {
    always {
      container('kubectl') {
        sh 'rm -rf "${REPO_DIR}" || true'
      }
    }
  }
}
