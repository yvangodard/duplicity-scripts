#! /bin/bash

# Une batterie de scripts pour utiliser Duplicity
# avec le support de contrôles Nagios / Centreon
# godardyvan@gmail.com - http://www.yvangodard.me 
# Plus d'infos : https://goo.gl/MXPkee
# Licence MIT - https://goo.gl/yiCVlX

# Variables initialisation
version="duplicityScripts v0.1 - 2016, Yvan Godard [godardyvan@gmail.com]"
scriptDir=$(dirname "${0}")
scriptName=$(basename "${0}")
scriptNameWithoutExt=$(echo "${scriptName}" | cut -f1 -d '.')

# Charger la configuration par défaut si elle existe
[ -e /etc/master-backup.conf ] && . /etc/master-backup.conf

# Charger une configuration si fournie en argument du script pouvant écraser certaines
# valeurs de la configuration par défaut
# Seules les configurations dont le template est /etc/master-backup*.conf sont acceptées
if [ -n "$1" -a -z "${1##/etc/master-backup*}" -a -z "${1%%*.conf}" -a -e "$1" ]; then
	. $1
	shift
elif [ "$1" == "--conf" ]; then
	[ -n "$2" -a -e "$2" ] && . $2
	shift ; shift
fi

export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin

: ${BASE:=/var/backups/master}
: ${DEV:=}
: ${TAG:=Master-Backup}
: ${URL:=}
: ${WHAT:=}
: ${OPTIONS:=}
: ${PASSPHRASE:=__duplicity__GnuPG__passphrase__}
: ${CACHE:=~/.cache/duplicity}
: ${DUPLICITY_DIR_TESTFILES:=/var/duplicityTestFiles}

timestamp () {
	date +%F-%Hh%M
}

log () {
	logger -st ${TAG} "$(timestamp): $*"
}

TIMESTAMP=$(timestamp)

# Duplicity sert pour les sauvegardes complètes et incrémentales vers une destination
if [ -z "${URL}" ]; then
	log "Pas d'URL définie pour réaliser la sauvegarde"
	exit 1
fi

if [ -n "$1" -a "$1" == "--no-email" ]; then
	shift
	unset EMAIL
fi

let REPORT_STATUS=0
if [ -n "$1" -a "$1" == "--report-status" ]; then
	shift
	let REPORT_STATUS=1
fi

unset INCREMENTAL
if [ -n "$1" -a "$1" == "--incremental" ]; then
	shift
	INCREMENTAL="incr"
fi

# Tests sur dossiers de travail
LOG_DIR="${BASE%/}/LOGS_${TAG%/}"
[ -e ${BASE} ] || mkdir -p ${BASE}
[ -d ${BASE} ] || mkdir -p ${BASE}
[ -e ${DUPLICITY_DIR_TESTFILES} ] || mkdir -p ${DUPLICITY_DIR_TESTFILES}
[ -d ${DUPLICITY_DIR_TESTFILES} ] || mkdir -p ${DUPLICITY_DIR_TESTFILES}
[ -e ${LOG_DIR} ] || mkdir -p ${LOG_DIR}
[ -d ${LOG_DIR} ] || mkdir -p ${LOG_DIR}
[ -n "${DEV}" ] && mount ${DEV} ${BASE} >/dev/null 2>&1
pushd ${BASE} >/dev/null 2>&1 || exit 1
[ -d ${BASE}/tmp ] || mkdir -p ${BASE}/tmp

DUPLICITY_OPTS="${OPTIONS} $*"

# Pas besoin de l'option full si on gère un dossier dédié par mois
if [ -n "${FULLDELAY}" -a -z "${INCREMENTAL}" ]; then
	DUPLICITY_OPTS="${DUPLICITY_OPTS} --full-if-older-than ${FULLDELAY}"
fi

# Taille des volumes à utiliser
DUPLICITY_OPTS="${DUPLICITY_OPTS} --volsize 100"

# Dossier temporaire à utiliser
DUPLICITY_OPTS="${DUPLICITY_OPTS} --tempdir ${BASE%/}/tmp"

unset CACHE_OPTS
if [ -n "${CACHE}" ]; then
	[ -d "${CACHE}" ] || mkdir -p "${CACHE}"
	CACHE_OPTS="--archive-dir ${CACHE}"
fi

if [ -n "${NAME}" ]; then
	CACHE_OPTS="${CACHE_OPTS} --name ${NAME}"
fi

H=$(hostname)

# Option de journalisation
STDOUT_FILE=$(mktemp ${LOG_DIR%/}/.master-backup-duplicity-${H}.XXXXX)
STDOUT_FILE_WITHOUT_TMP=$(echo "${STDOUT_FILE}" | awk 'sub("......$", "")')
LOG_FILE="${LOG_DIR%/}/master-backup-duplicity-${H}-${TIMESTAMP}.log"
DUPLICITY_OPTS="${DUPLICITY_OPTS} --log-file ${LOG_FILE}"

# PASSPHRASE est le secret pour le cryptage avec duplicity
export PASSPHRASE FTP_PASSWORD

# Ajout d'un fichier de test pour Nagios
DATE_FOR_NAGIOS=$(date +%F)
SEARCHFILE=test-${TAG}-${DATE_FOR_NAGIOS}
touch "${DUPLICITY_DIR_TESTFILES%/}/${SEARCHFILE}"
WHAT="${WHAT} --include ${DUPLICITY_DIR_TESTFILES}"

{
	if [ -n "${WHAT}" ]; then
		rm -f .${TAG}_DONE
		rm -f .${TAG}_OK
		rm -f .${TAG}_FAILURE
		echo
		log "Sauvegarde ${H} vers ${URL}"
		echo
		WHERE="${URL}"
		nice duplicity ${INCREMENTAL} ${CACHE_OPTS} ${DUPLICITY_OPTS} ${WHAT} --exclude / / ${WHERE}
		ERR=$?
		
		if (( ERR )); then
			log "Sauvegarde ${H} vers ${URL} échouée"
			touch .${TAG}_FAILURE
		else
			log "Sauvegarde ${H} vers ${URL} réussie"
			touch .${TAG}_OK
		fi
		
		# On permet le nettoyage même en cas d'erreur au cas où un reparamétrage sur la
		# taille des sauvegardes corrige une erreur liée à un espace de stockage plein
		if (( HOWMANYKEEPFULL >= 1 )); then
			log "Nettoyage des sauvegardes dans ${URL}"
			nice duplicity remove-all-but-n-full ${HOWMANYKEEPFULL} ${CACHE_OPTS} --force ${WHERE}
		fi
	else
		log "Sauvegarde ${H} vers ${URL} impossible sans spécifier quoi sauvegarder !"
	fi
} 2>&1 | \
{
	# Boucle de chronométrage de la sauvegarde insérant le temps d'exécution de
	# la sauvegarde dans le journal
	let STARTTIME=$(date +%s)
	while read line
	do
		echo ${line}
	done
	echo
	let STOPTIME=$(date +%s)
	let TOTALMIN=(STOPTIME-STARTTIME)/60 TOTALMOD=(STOPTIME-STARTTIME)%60
	log "Durée totale du processus de backup: ${TOTALMIN} minutes et ${TOTALMOD} secondes"
} >${STDOUT_FILE} 2>&1

# Vérification du statut de sauvegarde
if [ "$?" -ne 0 -o -e .${TAG}_FAILURE ]; then
	STATUS="FAILED"
	ERR=1
	cp -af ${STDOUT_FILE} ${STDOUT_FILE_WITHOUT_TMP}-${TIMESTAMP}.failed
else
	STATUS="OK"
	ERR=0
fi

if (( REPORT_STATUS )); then
	duplicity collection-status ${CACHE_OPTS} ${DUPLICITY_OPTS} ${URL%/}/ >> ${STDOUT_FILE}
fi

# Suppression des fichiers tests et cache de plus d'un mois 
find ${DUPLICITY_DIR_TESTFILES%/} -name "test-${TAG}-*" -mtime +31 -print -exec rm {} \; >> ${STDOUT_FILE}
find ${LOG_DIR} -name ".master-backup-listing-${TAG}*" -mtime +31 -print -exec rm {} \; >> ${STDOUT_FILE}

# Le journal de sauvegarde est stocké dans ${LOG_DIR%/}/master-backup-duplicity-${H}-${TIMESTAMP}.log
# mais peut être aussi envoyé par email à l'issue de la sauvegarde ou simplement
# être envoyé sur la sortie standard
if [ -n "${EMAIL}" ]; then
	[ -n "${EMAILADMIN}" ] && MAILOPTION="-c ${EMAILADMIN}"
	cat ${STDOUT_FILE} | \
		mail ${MAILOPTION} -s "[${STATUS}] Sauvegarde ${H}" ${EMAIL}
else
	cat ${STDOUT_FILE}
fi
rm -f ${STDOUT_FILE}

# Archivage des journaux - Rotation sur 9 archives de journaux de 10Mo max
pushd ${LOG_DIR} >/dev/null 2>&1 || exit 1
TARBASE="master-backup-log.gz.tar"
MAXSIZE=10000000
MAX=9
for f in *.log
do
	# Rotation des archives
	SIZE=$( stat -c "%s" ${TARBASE} 2>/dev/null )
	if (( MAX && SIZE > MAXSIZE )); then
		let I=1
		while [ -e "${TARBASE}.${I}" ]; do (( I++ < MAX-1 )) || break ; done
		while (( I > 1 )); do let I-- ; mv -f "${TARBASE}.${I}" "${TARBASE}.$((I+1))" ; done
		mv -f "${TARBASE}" "${TARBASE}.${I}"
	fi
	# Archivage du journal de duplicity
	if [ -s "${f}" ]; then
		gzip -9n ${f}             || break
		tar rf ${TARBASE} ${f}.gz   || break
		rm -f ${f}.gz
	fi
done

cd ${BASE%/}
popd >/dev/null 2>&1
[ -n "${DEV}" ] && umount ${BASE} >/dev/null 2>&1

touch ${BASE%/}/.${TAG}_DONE

exit ${ERR}