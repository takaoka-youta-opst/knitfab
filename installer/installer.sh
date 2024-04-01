#! /bin/bash
set -e

HELM=${HELM:-helm}
KUBECTL=${KUBECTL:-kubectl}
OPENSSL=${OPENSSL:-openssl}
REPOSITORY=${REPOSITORY:-opst/knitfab}
IMAGE_REPOSITORY_HOST=${IMAGE_REPOSITORY_HOST:-ghcr.io}
BRANCH=${BRANCH:-main}

CHART_REPOSITORY_ROOT=${CHART_REPOSITORY_ROOT:-"https://raw.githubusercontent.com/${REPOSITORY}/${BRANCH}/charts/release"}
DEFAULT_CHART_VERSION=v1.0.0
CHART_VERSION=${CHART_VERSION:-${DEFAULT_CHART_VERSION}}
VERBOSE=${VERBOSE}
THIS=./${0##*/}
HERE=${0%/*}

function message() {
	echo "$@" >&2
}

function run() {
	if [ -n "${VERBOSE}" ] ; then
		message '$ '"$@"
	else
		message '$ '"${@: 0:3} ... ${@: -2:2}"
	fi

	"$@"
}

function abspath() {
	if [ -d "${1}" ] ; then
		( cd "${1}" && pwd )
	else
		( cd "${1%/*}" && echo "$(pwd)/${1##*/}" )
	fi
}

function get_node_ip() {
	${KUBECTL} get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'
}

function prepare_install() {
	mkdir -p ${SETTINGS}/{values,certs}
	chmod -R go-rwx ${SETTINGS}
	cd ${SETTINGS}

	if [ -r "${TLSCACERT}" ] && [ -r "${TLSCAKEY}" ] ; then
		CACOPIED=" (copied from ${TLSCACERT})"
		CAKEYCOPIED=" (copied from ${TLSKEY})"
		cp -r "${TLSCACERT}" certs/ca.crt
		cp -r "${TLSCAKEY}" certs/ca.key
	elif [ -z "${TLSCACERT}" ] && [ -z "${TLSCAKEY}" ] ; then
		message "generating self-signed CA certificate & key..."
		# create self-signed CA certificate/key pair
		# ... key
		${OPENSSL} genrsa -out certs/ca.key 4096

		# ... certificate
		${OPENSSL} req -new -x509 -nodes \
			-key certs/ca.key \
			-sha256 -days 3650 \
			-out certs/ca.crt \
			-subj "/CN=knitfab/O=knitfab/OU=knitfab"

		TLSCACERT=certs/ca.crt
		TLSCAKEY=certs/ca.key
	else
		message "ERROR: TLS CA certificate/key pair needs both. Or not set to generate new self-signed one."
		exit 1
	fi

	if [ -r "${TLSCERT}" ] && [ -r "${TLSKEY}" ] ; then
		cp -r "${TLSCERT}" certs/server.crt
		cp -r "${TLSKEY}" certs/server.key
	elif [ -z "${TLSCERT}" ] && [ -z "${TLSKEY}" ] ; then

		message "generating server certificate & key..."
		# create server key
		${OPENSSL} genrsa -out certs/server.key 4096

		function alt_names() {
			local DNS=()
			for NAME in $(get_node_ip) ; do
				COUNT=$((COUNT + 1))
				echo "IP.${COUNT} = ${NAME}"
			done
		}

		cat <<EOF > certs/san.extfile
[req]
distinguished_name = req_distinguished_name
req_extensions = req_ext
prompt = no

[req_distinguished_name]
CN = knitfab

[ req_ext ]
subjectAltName = @alt_names

[ SAN ]
subjectAltName = @alt_names
basicConstraints=CA:FALSE

[ v3_ext ]
authorityKeyIdentifier=keyid,issuer:always
basicConstraints=CA:FALSE
keyUsage=keyEncipherment,dataEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=@alt_names

[alt_names]
$(alt_names)
EOF

		# create server CSR
		${OPENSSL} req -new \
			-key certs/server.key -out certs/server.csr -config certs/san.extfile

		# create server certificate
		${OPENSSL} x509 -req -in certs/server.csr \
			-CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
			-out certs/server.crt \
			-extensions v3_ext -extfile certs/san.extfile \
			-days 3650 -sha256

		message "cetificates generated."
		message ""
	else
		message "ERROR: TLS certificate/key pair needs both. Or not set to generate new one."
		exit 1
	fi


	cat <<EOF > ./README.md
knitfab-install-settings/README.md
=================================

This directory is generated by knitfab installer command: \`${THIS} --prepare\`.

In this directory, you can find install settings for knitfab.

  - certs/*
    - certificate and private key of server and CA.
  - values/*
    - Install paramters for knitfab.
    - please inspect and set values for your environment. For more details, see values/README.md.

This directory contains kubeconfig, RDB password and CA key pair.
**KEEP THIS DIRECTORY SECURE**, please be careful to handle this directory.
Permission is set to be read/write by only the owner, you.

Next Step
----------

1. inspect ./knitfab-install-settings/values/ directory and set values for your environment.
    - Especially, you need to invest values/knit-storage-nfs.yaml to persist your data.
    - Other files may be helpful to understand the settings, and you can modify them if needed.
2. ${THIS} --install ... : to install knitfab with your setting.
    - To know options, run "${THIS}" without arguments.
EOF

	cp ${KUBECONFIG} ./kubeconfig

	cat <<EOF >> values/knit-app.yaml
# # # values/knit-app.yaml # # #

# this file declares install paramaters for knit-app.

# # clusterTLD: (optional) Your k8s cluster's top-level domain.
# #  By default, "cluster.local" is used.
# clusterTLD: "cluster.local"

# knitd: api server related settings.
knitd:
  # port: Port number of knit-api service, exposed from k8s cluster node.
  port: 30803

EOF

	cat <<EOF >> values/knit-db-postgres.yaml
# # # values/knit-app.yaml # # #

# this file declares install paramaters for database for knitfab.

credential:
  # username: (optional) Username for the database.
  #  By default, "knit" is used.
  # username: "knit"

  # password: Password for the database.
  #  This template has random password. Use it as is, or you can use your own password.
  password: "$(head -c 32 /dev/urandom | base64 | tr -d '\r\n')"

EOF

	cat <<EOF > values/knit-image-registry.yaml
# # # values/knit-image-registry.yaml # # #

# # port: Port number of the registry service, exposed from k8s cluster node.
port: 30503

EOF

	: > values/knit-certs.yaml
	chmod go-rwx values/knit-certs.yaml
	cat <<EOF > values/knit-certs.yaml
# # # values/knit-certs.yaml # # #
cacert: $(cat ./certs/ca.crt | base64 | tr -d '\r\n')
cakey: $(cat ./certs/ca.key | base64 | tr -d '\r\n')
cert: $(cat ./certs/server.crt | base64 | tr -d '\r\n')
key: $(cat ./certs/server.key | base64 | tr -d '\r\n')
EOF

	cat <<EOF > values/knit-storage-nfs.yaml
# # # values/knit-storage-nfs.yaml # # #

# # nfs: NFS server related settings.
# #
# # This is the main setting for knitfab to persist your data: how and where.
# #
# #  There are 2 modes: In-Cluster mode and External mode.
# #
# #  * In-Cluster mode (when "external: false", default): knitfab employs in-cluster NFS server.
# #
# #  BY DEFAULT, YOUR DATA WILL BE REMOVED WHEN THE NFS SERVER POD IS REMOVED.
# #
# #  To persist your data,
# #    set "hostPath" to the directory on the node, and
# #    set "node" to the node name where the in-cluster NFS server pod will be scheduled.
# #  Then, your data will be read/written from the "hostPath" on the "node",
# #  and persisted even after the NFS server pod is restarted.
# #
# #  * External mode (when "external: true"): use NFS server you own. (You need your own NFS server)
# #
# #  To use this mode, connection parameters to your NFS server are needed.
# #    set "server" to the hostname of the nfs server, and
# #    set "share" and "mountOptions" if needed.
# #  In this mode, your data will be read/written from your NFS server, and parsisted even after the NFS server pod is restarted.
nfs:
  # # external: If true (External mode), use NFS server you own.
  # #  Otherwise(In-cluster mode), knitfab employs in-cluster NFS server.
  external: false

  # # mountOptions: (optional) Mount options for the nfs server.
  # #  By default, "nfsvers=4.1,rsize=8192,wsize=8192,hard,nolock".
  # mountOptions: "nfsvers=4.1,rsize=8192,wsize=8192,hard,nolock"

  # # share: (optional) Export root of the nfs server. default is "/".
  # share: "/"

  # # # FOR EXTERNAL MODE # # #

  # # server: Hostname of the nfs server.
  # #  If external is true, this value is required.
  # server: "nfs.example.com"

  # # # FOR IN-CLUSTER MODE # # #

  # # hostPath: (optional) Effective only when external is false.
  # # If set, the in-cluster NFS server will read/write files at this directory ON NODE.
  # #
  # # This is useful when you want to keep the data even after the NFS server is restarted.
  # hostPath: "/var/lib/knitfab"

  # # node: (optional) kubernetes node name where the in-cluster NFS server pod should be scheduled.
  # #
  # # by default, the pod will be scheduled to the indeterminated node,
  # # so restarting pod may cause data loss in multinode cluster.
  # #
  # # This value is effective only when "external: false".
  node: ""

EOF

	if [ -n "${PULL_SECRET}" ] ; then
		${KUBECTL} create secret generic knitfab-regcred \
			--type=kubernetes.io/dockerconfigjson --from-file "${PULL_SECRET}" \
			--dry-run=client -o yaml > ./knit-image-registry-secret.yaml
	fi

	cat <<EOF >&2
Prepareng for knitfab installation is done.

✔ 1. ${THIS} --prepare : to generate templates of knitfab install parameters.

Nest Steps
-----

  2. inspect ${SETTINGS}/values/ directory and set values for your environment.
    - Follow README.
    - There are settings for your data to be persistent.
        - Please inspect and set them. Or, you may loss your data by restarting knitfab pods.
  3. ${THIS} --install ... : to install knitfab with your setting.
    - To know options, run "${THIS}" without arguments.

NOTE
-----

The directory "${SETTINGS}" contains kubeconfig, RDB password and CA key pair.
**KEEP THE DIRECTORY SECURE**, please be careful to handle this directory.
Permission is set to be read/write by the owner only.

EOF

}


for ARG in ${@} ; do
	shift || :
	case ${ARG} in
		--settings|-s)
			SETTINGS=${1}; shift || :
			;;

		--prepare)
			PREPARE=1;
			;;
		# knitfab chart version
		--chart-version)
			CHART_VERSION=${1}; shift || :
			;;
		--kubeconfig)
			KUBECONFIG=${1}; shift || :
			if [ -r "${KUBECONFIG}" ] ; then
				export KUBECONFIG=$(abspath ${KUBECONFIG})
			else
				message "ERROR: KUBECONFIG file not found: ${KUBECONFIG}"
				exit 1
			fi
			;;
		--tls-ca-cert)
			TLSCACERT=${1}; shift || :
			;;
		--tls-ca-key)
			TLSCAKEY=${1}; shift || :
			;;
		--ca-cert)
			CACERT=${1}; shift || :
			;;
		--ca-key)
			CAKEY=${1}; shift || :
			;;

		# kubernetes related options
		--install)
			INSTALL=1;
			;;
		--namespace|-n)
			NAMESPACE=${1}; shift || :
			;;
		--verbose)
			VERBOSE=1
			;;
		*)
			;;
	esac
done

if [ -n "${PREPARE}" ] ; then
	if [ -n "${INSTALL}" ] ; then
		message "ERROR: --prepare and --install are exclusive."
		exit 1
	fi

	if [ -z "${KUBECONFIG}" ] ; then
		KUBECONFIG=$(abspath ~/.kube/config)
	fi

	if ! [ -r "${KUBECONFIG}" ] ; then
		message "ERROR: KUBECONFIG file not found: ${KUBECONFIG}"
		exit 1
	fi
	export KUBECONFIG

	if [ -z "${SETTINGS}" ] ; then
		SETTINGS=${HERE}/knitfab-install-settings
	fi
	export SETTINGS=$(abspath ${SETTINGS})

	prepare_install
	exit 0
fi

if [ -z "${INSTALL}" ] ; then
	cat <<EOF >&2
knitfab installer
=================

Usage
-------

\`\`\`
# prepare install settings
${THIS} --prepare [--tls-ca-cert <CA_CERT>] [--tls-ca-key <CA_KEY>] [--kubeconfig <KUBECONFIG>] [--settings|-s <directory where install settings are saved>]
\`\`\`
* When --tls-ca-cert and --tls-ca-key is not passed, it generates self-signed CA certificate & key.
* --kubeconfig is the path to the kubeconfig file. Default is ~/.kube/config.
* --settings is the directory where install settings are saved. Default is \`./knitfab-install-settings\`.

\`\`\`
# install knitfab
${THIS} --install [--settings|-s <SETTINGS_DIR>] [--chart-version <VERSION>] [--namespace|-n <NAMESPACE>] [--kubeconfig <KUBECONFIG>]
\`\`\`

* --settings is the directory where install settings are saved. Default is \`./knitfab-install-settings\`.
* --chart-version is the version of knitfab chart. Default is \`${DEFAULT_CHART_VERSION}\` .
* --namespace is the namespace where knitfab is installed. Default is "knitfab".
* --kubeconfig is the path to the kubeconfig file. Default is \`\$\{--settings\}/kubeconfig\`.

Steps
-----

1. \`./installer.sh --prepare ...\`: to generate templates of knitfab install parameters.
2. inspect \`--settings\` directory and update files for your environment.
    - default is \`./knitfab-install-settings\`
3. \`./installer.sh --install ...\`  to install knitfab with your setting.

### Next Step

Do \`./installer.sh --prepare ...\`. It generates configuration files of knitfab installing
EOF
	exit 1
fi

#
#
#       INSTALL KNITFAB
#
#


if [ -z "${SETTINGS}" ] ; then
	SETTINGS=${HERE}/knitfab-install-settings
fi

CERTS=${SETTINGS}/certs
VALUES=${SETTINGS}/values

if [ -z "${KUBECONFIG}" ] ; then
	KUBECONFIG=${HERE}/knitfab-install-settings/kubeconfig
fi

if ! [ -r "${KUBECONFIG}" ] ; then
	message "ERROR: KUBECONFIG file not found: ${KUBECONFIG}"
	exit 1
fi
export KUBECONFIG=$(abspath ${KUBECONFIG})

NAMESPACE=${NAMESPACE:-knitfab}

if [ -r "${SETTINGS}/knit-image-registry-secret.yaml" ] ; then
	${KUBECTL} apply -n ${NAMESPACE} -f ${SETTINGS}/knit-image-registry-secret.yaml
	SET_PULL_SECRET='--set imagePullSecret=knitfab-regcred'
fi


cat <<EOF > ${SETTINGS}/uninstaller.sh
#! /bin/bash
set -e

export KUBECONFIG="${KUBECONFIG}"

${HELM} uninstall -n ${NAMESPACE} --wait knit-app || :

if ! [ "\$1" == "--hard" ] ; then
	echo "\\\`knit-app\\\` is uninstalled." >&2
	echo "To remove other components, run this script with --hard option." >&2
	exit 0
else
	echo "" >&2
	echo "** --hard uninstall **" >&2
	echo "" >&2
	echo "This will remove all data in the database and the image registry." >&2
	read -p "Are you sure? [y/N] " ANSWER
	if [ "\${ANSWER}" == "y" ] ; then
		echo "Removing other components..." >&2
	else
		echo "Canceled." >&2
		exit 1
	fi
fi

${HELM} uninstall -n ${NAMESPACE} --wait knit-image-registry || :
${HELM} uninstall -n ${NAMESPACE} --wait knit-db-postgres || :
${HELM} uninstall -n ${NAMESPACE} --wait knit-certs || :
${HELM} uninstall -n ${NAMESPACE} --wait knit-storage-nfs || :
EOF

chmod +x ${SETTINGS}/uninstaller.sh

message "[1 / 3] addding helm repositories..."

run ${HELM} repo add --force-update knitfab ${CHART_REPOSITORY_ROOT}

message "[2 / 3] install knit middlewares..."

message "[2 / 3] #1 install storage driver"
if ${HELM} status knit-storage-nfs -n ${NAMESPACE} > /dev/null 2> /dev/null ; then
	message "already installed: knit-storage-nfs"
else
	EXTERNAL=false
	if [ -n "${KNIT_NFS_HOST}" ] ; then
		EXTERNAL=true
	fi

	run ${HELM} install --dependency-update --wait \
		-n ${NAMESPACE} --create-namespace \
		--version ${CHART_VERSION} \
		-f ${VALUES}/knit-storage-nfs.yaml \
	knit-storage-nfs knitfab/knit-storage-nfs
	sleep 5
fi

message "[2 / 3] #2 install tls certificates"
if ${HELM} status knit-certs -n ${NAMESPACE} > /dev/null 2> /dev/null ; then
	message "already installed: knit-certs"
else
	run ${HELM} install --dependency-update --wait \
		-n ${NAMESPACE} --create-namespace \
		--version ${CHART_VERSION} \
		-f ${VALUES}/knit-certs.yaml \
	knit-certs knitfab/knit-certs
fi

message "[2 / 3] #3 install database"
if ${HELM} status knit-db-postgres -n ${NAMESPACE} > /dev/null 2> /dev/null ; then
	message "already installed: knit-db-postgres"
else
	run ${HELM} install --dependency-update --wait \
		-n ${NAMESPACE} --create-namespace \
		--version ${CHART_VERSION} \
		--set-json "storage=$(${HELM} get values knit-storage-nfs -n ${NAMESPACE} -o json --all)" \
		-f ${VALUES}/knit-db-postgres.yaml \
	knit-db-postgres knitfab/knit-db-postgres
fi

message "[2 / 3] #4 install image registry"
if ${HELM} status knit-image-registry -n ${NAMESPACE} > /dev/null 2> /dev/null ; then
	message "already installed: knit-image-registry"
else
	run ${HELM} install --dependency-update --wait \
		-n ${NAMESPACE} --create-namespace \
		--version ${CHART_VERSION} \
		--set-json "storage=$(${HELM} get values knit-storage-nfs -n ${NAMESPACE} -o json --all)" \
		--set-json "certs=$(${HELM} get values knit-certs -n ${NAMESPACE} -o json --all)" \
		-f ${VALUES}/knit-image-registry.yaml \
	knit-image-registry knitfab/knit-image-registry
fi

message "[3 / 3] install knit app"
if ${HELM} status knit-app -n ${NAMESPACE} > /dev/null 2> /dev/null ; then
	message "already installed: knit-app"
else
	run ${HELM} install --dependency-update --wait \
		-n ${NAMESPACE} --create-namespace \
		--version ${CHART_VERSION} \
		--set-json "storage=$(${HELM} get values knit-storage-nfs -n ${NAMESPACE} -o json --all)" \
		--set-json "database=$(${HELM} get values knit-db-postgres -n ${NAMESPACE} -o json --all)" \
		--set "imageRepository=${IMAGE_REPOSITORY_HOST}/${REPOSITORY}" \
		--set-json "certs=$(${HELM} get values knit-certs -n ${NAMESPACE} -o json --all)" \
		${SET_PULL_SECRET} -f ${VALUES}/knit-app.yaml \
	knit-app knitfab/knit-app
fi

mkdir -p ${SETTINGS}/handouts
cat <<EOF > ${SETTINGS}/handouts/README.md
handouts/README.md
=================

This directory contains resources to connect your knitfab.

  - README.md
    - This file.

  - knitprofile
    - knit profile file.
    - pass this file to your knit client in your project directory: \`knit init knitprofile\`

  - docker/certs.d/*
    - CA certificate of the in-cluster image registry.
    - copy this directory to your docker configure directory (\`/etc/docker/certs.d\`, for example)
    - for more detail, see https://docs.docker.com/engine/security/certificates/
EOF

for IP in $(get_node_ip) ; do
	cat <<EOF > ${SETTINGS}/handouts/knitprofile
# knit profile file
# pass this file to your knit client in your project directory: \`knit init knitprofile\`
apiRoot: https://${IP}:$(${KUBECTL} -n ${NAMESPACE} get service/knitd -o jsonpath="{.spec.ports[?(@.name==\"knitd\")].nodePort}")/api
cert:
  ca: $(cat ${CERTS}/ca.crt | base64 | tr -d '\r\n')
EOF

	DOCKER_CERT_D=${SETTINGS}/handouts/docker/certs.d/${IP}:$(${KUBECTL} -n ${NAMESPACE} get service/image-registry -o jsonpath="{.spec.ports[?(@.name==\"image-registry\")].nodePort}")
	mkdir -p ${DOCKER_CERT_D}
	cp ${CERTS}/ca.crt ${DOCKER_CERT_D}/ca.crt

	break  # pick one IP
done

cat <<EOF >&2

Install is done.

Next Step
----------

* Handouts for your user is generated at ${SETTINGS}/handout .
  - Please pass the files to your user.

* Uninstaller is generated at ${SETTINGS}/uninstaller.sh .
  - To uninstall knitfab, run this script.

EOF
