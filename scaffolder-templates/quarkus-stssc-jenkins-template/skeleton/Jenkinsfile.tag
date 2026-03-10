library identifier: 'RHTAP_Jenkins@main', retriever: modernSCM(
[$class: 'GitSCMSource',
remote: 'https://${{values.gitlabHost}}/rhdh/tssc-sample-jenkins.git'])

pipeline {
    agent {
        kubernetes {
        defaultContainer 'jnlp'
        podRetention onFailure()
        customWorkspace "/home/jenkins/agent/workspace-${env.BUILD_ID}"
        yaml '''
            apiVersion: v1
            kind: Pod
            spec:
              containers:
              - name: jnlp
                image: quay.io/rhpds/tssc-jenkins-promote-agent:0.1
                tty: true
                args: ["${computer.jnlpmac}","${computer.name}"]
                securityContext:
                  privileged: true
              - name: skopeo
                image: registry.redhat.io/ubi9/skopeo:9.5
                command: ["cat"]
                tty: true
                securityContext:
                  privileged: true
            '''
        }
    }

    environment {
        COSIGN_PUBLIC_KEY = credentials('COSIGN_PUBLIC_KEY')
        TRUSTIFICATION_OIDC_CLIENT_SECRET = credentials('TRUSTIFICATION_OIDC_CLIENT_SECRET')
        TUF_MIRROR = 'http://tuf.tssc-tas.svc'
        QUAY_IO_CREDS = credentials('QUAY_IO_CREDS')
        IMAGE_URL = '${{values.quayHost}}/${{values.quayDestination}}'
        POLICY_CONFIGURATION = 'git::github.com/rhpds/jenkins-rhtap-config//default'
        REKOR_HOST = 'http://rekor-server.tssc-tas.svc'
        IGNORE_REKOR = 'false'
        STRICT = 'true'
        INFO = 'true'
        GITOPS_AUTH_USERNAME = credentials('GITOPS_AUTH_USERNAME')
        GITOPS_AUTH_PASSWORD = credentials('GITOPS_AUTH_PASSWORD')
        GITOPS_REPO_URL = 'https://${{values.gitlabHost}}/${{values.destination}}-gitops'
        ENVIRONMENT = 'stage'
    }

    stages {
        stage('gather-images') {
            steps {
                script {
                    env.GIT_TAG = sh(script: 'git describe --tags --abbrev=0', returnStdout: true).trim()
                    env.GIT_COMMIT = sh(script: 'git rev-parse $GIT_TAG', returnStdout: true).trim()
                }
                sh '''
                    mkdir -p $(pwd)/results/gather-deploy-images
tee $(pwd)/results/gather-deploy-images/IMAGES_TO_VERIFY <<EOF
{
    "components": [
    {
        "containerImage": "$IMAGE_URL:$GIT_COMMIT",
        "source": {
            "git": {
                "url": "$GIT_URL",
                "revision": "$GIT_COMMIT"
            }
        }
    }
    ]
}
EOF
                    cat $(pwd)/results/gather-deploy-images/IMAGES_TO_VERIFY
                '''
            }
        }

        stage('verify-ec') {
            steps {
                script {
                    env.EFFECTIVE_TIME = new Date().format("yyyy-MM-dd'T'HH:mm:ss'Z'", TimeZone.getTimeZone("UTC"))
                    env.HOMEDIR = sh(script: 'pwd', returnStdout: true).trim()
                    rhtap.info('verify_enterprise_contract')
                    rhtap.verify_enterprise_contract()
                }
            }
        }

        stage("update-image-tag-for-stage") {
            steps {
                container('skopeo') {
                    sh '''
                        IMAGE_REGISTRY="${IMAGE_URL%%/*}"
                        skopeo login -u $QUAY_IO_CREDS_USR -p $QUAY_IO_CREDS_PSW $IMAGE_REGISTRY
                        skopeo copy docker://$IMAGE_URL:$GIT_COMMIT docker://$IMAGE_URL:$GIT_TAG
                    '''
                }
            }
        }

        stage('deploy-to-stage') {
            steps {
                script {
                    env.PARAM_IMAGE = env.IMAGE_URL + ':' + env.GIT_TAG
                    rhtap.info('update_deployment')
                    rhtap.update_deployment()
                }
            }
        }
    }
}
