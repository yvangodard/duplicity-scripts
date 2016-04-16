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
messageContent=$(mktemp /tmp/${scriptNameWithoutExt}_messageContent.XXXXX)
H=$(hostname)
warningTest=0
criticalTest=0
warningVerifyScript=0
thisTime=0
totalSec=0
totalTimeProbe=0
defaultConfigFile="/etc/master-backup.conf"
bufferFolder="/var/${scriptNameWithoutExt}"
bufferFile="${bufferFolder%/}/bufferFile.txt"
tempScript=$(mktemp /tmp/${scriptNameWithoutExt}_tempScript.XXXXX)
tempFinalResult=$(mktemp /tmp/${scriptNameWithoutExt}_tempFinalResult.XXXXX)
tempOutputResult=$(mktemp /tmp/${scriptNameWithoutExt}_tempOutputResult.XXXXX)
tempPreviousContent=$(mktemp /tmp/${scriptNameWithoutExt}_tempPreviousContent.XXXXX)
tempWarningTest=$(mktemp /tmp/${scriptNameWithoutExt}_tempWarningTest.XXXXX)
tempWarningVerifyScript=$(mktemp /tmp/${scriptNameWithoutExt}_tempWarningVerifyScript.XXXXX)
tempCriticalTest=$(mktemp /tmp/${scriptNameWithoutExt}_tempCriticalTest.XXXXX)
tempProcessingOutput=$(mktemp /tmp/${scriptNameWithoutExt}_tempProcessingOutput.XXXXX)

# Charger la configuration par défaut si elle existe
[ -e ${defaultConfigFile} ] && . ${defaultConfigFile} && configFile=${defaultConfigFile}

# Charger une configuration si fournie en argument du script pouvant écraser certaines
# valeurs de la configuration par défaut
# Seules les configurations dont le template est /etc/master-backup*.conf sont acceptées
if [ -n "$1" -a -z "${1##/etc/master-backup*}" -a -z "${1%%*.conf}" -a -e "$1" ]; then
	configFile="$1"
	. $1
	shift
elif [ "$1" == "--conf" ]; then
	configFile="$2"
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
: ${NAGIOS_WARN_DAYS:=2}
: ${NAGIOS_CRIT_DAYS:=5}
: ${MAX_DELAY_PROBE:=30}
: ${DELAY_PROCESSING_LIMIT:=15}
: ${NAGIOS_PROBE_WITH_RESTORE_TEST:=NO}

# Tests sur dossiers de travail
[ -e ${BASE} ] || mkdir -p ${BASE}
[ -d ${BASE} ] || mkdir -p ${BASE}
[ -e ${DUPLICITY_DIR_TESTFILES} ] || mkdir -p ${DUPLICITY_DIR_TESTFILES}
[ -d ${DUPLICITY_DIR_TESTFILES} ] || mkdir -p ${DUPLICITY_DIR_TESTFILES}
pushd ${BASE} >/dev/null 2>&1 || exit 1
[ -d ${BASE}/tmp ] || mkdir -p ${BASE}/tmp

function endThisScript () {
	[[ ! -z ${3} ]] && echo ${3}
	[[ ! -z $(cat ${messageContent}) ]] && echo "" && cat ${messageContent}
	[[ -e ${messageContent} ]] && rm -R ${messageContent}
	if [[ "${2}" == "removeTemp" ]]; then
		[[ -e ${tempFinalResult} ]] && rm -R ${tempFinalResult}
		[[ -e ${tempOutputResult} ]] && rm -R ${tempOutputResult}
		[[ -e ${tempScript} ]] && rm -R ${tempScript}
		[[ -e ${tempPreviousContent} ]] && rm -R ${tempPreviousContent}
		[[ -e ${lockFile} ]] && rm -R ${lockFile}
	fi
	find /tmp -name "${scriptNameWithoutExt}*" -name "*.testrestore" -exec rm -rf {} \; 
	[[ -e ${tempWarningTest} ]] && rm ${tempWarningTest}
	[[ -e ${tempWarningVerifyScript} ]] && rm ${tempWarningVerifyScript}
	[[ -e ${tempCriticalTest} ]] && rm ${tempCriticalTest}
	[[ -e ${tempProcessingOutput} ]] && rm ${tempProcessingOutput}
	exit ${1}
}

#  Test root access
[[ `whoami` != 'root' ]] && endThisScript 3 ${processingOutput} "FATAL ERROR - This tool needs a root access. Use 'sudo'."

# Add lockfile to avoid multiple instances
lockFile=/tmp/${scriptNameWithoutExt}_${TAG}.lock
if [[ -e ${lockFile} ]]; then
	echo "$(date)" > ${messageContent}
	echo "Vous avez tenté de lancé simultanément plusieurs instances de la sonde pour le même backup '${TAG}'." >> ${messageContent}
	echo "Mais ceci est impossibe. L'autre instance du contrôle est lancée à la date suivante : $(date -r ${lockFile})." >> ${messageContent}
	endThisScript 2 "dontRemoveTemp" "FATAL ERROR - Impossible de lancer simultanément plusieurs instances de la sonde pour le même backup '${TAG}'"
fi
touch ${lockFile}

# Duplicity sert pour les sauvegardes complètes et incrémentales vers une destination
[[ -z "${URL}" ]] && endThisScript 2 "removeTemp" "FATAL ERROR - Pas d'URL définie pour lister la sauvegarde."

{
	## Processing
	echo "************************************************************************************" >> ${messageContent}
	echo "********************************* DUPLICITY TESTS **********************************" >> ${messageContent}
	echo "************************************************************************************" >> ${messageContent}
	echo "" >> ${messageContent}

	# Boucle pour patienter si Duplicity tourne en ce moment
	if [[ ! -z $(/usr/bin/pgrep master-backup.sh) ]];
		then
		echo "Duplicity semble en cours de backup. Nous patientons ${DELAY_PROCESSING_LIMIT} secondes pour voir si il est possible de poursuivre." >> ${messageContent}
		delay=0
		until [[ ${delay} -ge ${DELAY_PROCESSING_LIMIT} ]]
		do
			sleep 1
			let delay=${delay}+1
			let MAX_DELAY_PROBE=${MAX_DELAY_PROBE}-1
			[[ -z $(/usr/bin/pgrep master-backup.sh) ]] && delay=${DELAY_PROCESSING_LIMIT}
		done
	fi
	[[ ! -z $(/usr/bin/pgrep master-backup.sh) ]] && endThisScript 3 ${processingOutput} "ERROR - Duplicity est en cours d'exécution."

	# Test si DONE
	echo "" >> ${messageContent}
	echo "************************************************************************************" >> ${messageContent}
	echo "" >> ${messageContent}
	echo "Test sur le fichier '${BASE%/}/.${TAG}_DONE' :" >> ${messageContent}
	if [[ -e ${BASE%/}/.${TAG}_DONE ]]; then
		echo "La dernière sauvegarde a été complètement terminée." >> ${messageContent}
	else
		let warningTest=(warningTest+1)
		echo "La dernière sauvegarde n'a pas été terminée," >> ${messageContent}
		echo "le fichier '${BASE%/}/.${TAG}_DONE' n'a pas été trouvé." >> ${messageContent}
	fi

	# Test si OK
	echo "" >> ${messageContent}
	echo "************************************************************************************" >> ${messageContent}
	echo "" >> ${messageContent}
	echo "Test sur le fichier '${BASE%/}/.${TAG}_OK' :" >> ${messageContent}
	if [[ -e ${BASE%/}/.${TAG}_OK ]]; then
		echo "La dernière sauvegarde a été exécutée avec succès." >> ${messageContent}
	else
		let warningTest=(warningTest+1)
		echo "La dernière sauvegarde n'a pas été réussie," >> ${messageContent}
		echo "le fichier '${BASE%/}/.${TAG}_OK' n'a pas été trouvé." >> ${messageContent}
	fi

	if [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "YES" ]] || [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "Yes" ]] || [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "yes" ]] || [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "Y" ]] || [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "y" ]] ; then
		if [[ ${warningTest} -eq 0 ]]; then
			# Test si restauration fichier test OK
			{
				if [[ -e ${scriptDir%/}/master-backup-restore.sh ]]; then
					echo "" >> ${messageContent}
					echo "************************************************************************************" >> ${messageContent}
					echo "" >> ${messageContent}
					# test si fichier de test de J-x existe (warning)
					DATE_FOR_NAGIOS=$(date --date "${NAGIOS_WARN_DAYS} days ago" +%F)
					SEARCHFILE=test-${TAG}-${DATE_FOR_NAGIOS}
					echo "Test de présence du fichier de test '${DUPLICITY_DIR_TESTFILES%/}/${SEARCHFILE}' :" >> ${messageContent}
					[[ -f /tmp/${scriptNameWithoutExt}_${SEARCHFILE}.testrestore ]] && rm /tmp/${scriptNameWithoutExt}_${SEARCHFILE}.testrestore
					${scriptDir%/}/master-backup-restore.sh --conf ${configFile} -t ${NAGIOS_WARN_DAYS}D ${DUPLICITY_DIR_TESTFILES%/}/${SEARCHFILE} /tmp/${scriptNameWithoutExt}_${SEARCHFILE}.testrestore >> ${messageContent} 2>&1 
					if [ $? -eq 0 ]; then
						echo "" >> ${messageContent}
						echo "La restauration du fichier de test semble fonctionner. OK." >> ${messageContent}
					else
						let warningTest=(warningTest+1)
						echo "" >> ${messageContent}
						echo "La restauration du fichier de test semble HS !" >> ${messageContent}

						# test si fichier de test de J-x existe (critical)
						echo "" >> ${messageContent}
						echo "************************************************************************************" >> ${messageContent}
						echo "" >> ${messageContent}
						DATE_FOR_NAGIOS=$(date --date "${NAGIOS_CRIT_DAYS} days ago" +%F)
						SEARCHFILE=test-${TAG}-${DATE_FOR_NAGIOS}
						echo "Test de présence du fichier de test '${DUPLICITY_DIR_TESTFILES%/}/${SEARCHFILE}' :" >> ${messageContent}
						[[ -e /tmp/${scriptNameWithoutExt}_${SEARCHFILE}.testrestore ]] && rm /tmp/${scriptNameWithoutExt}_${SEARCHFILE}.testrestore
						${scriptDir%/}/master-backup-restore.sh --conf ${configFile} -t ${NAGIOS_CRIT_DAYS}D ${DUPLICITY_DIR_TESTFILES%/}/${SEARCHFILE} /tmp/${scriptNameWithoutExt}_${SEARCHFILE}.testrestore >> ${messageContent} 2>&1 
						if [ $? -eq 0 ]; then
							echo "" >> ${messageContent}
							echo "La restauration du fichier de test semble fonctionner. OK." >> ${messageContent}
						else
							let criticalTest=${criticalTest}+1
							echo "" >> ${messageContent}
							echo "La restauration du fichier de test semble HS !" >> ${messageContent}
						fi
						[[ -e /tmp/${scriptNameWithoutExt}_${SEARCHFILE}.testrestore ]] && rm /tmp/${scriptNameWithoutExt}_${SEARCHFILE}.testrestore
					fi
				else
					let criticalTest=${criticalTest}+1
					echo "Le script de restauration '${scriptDir%/}/master-backup-restore.sh' est absent." >> ${messageContent}
					endThisScript 2 ${processingOutput} "CRITICAL - ${scriptName} ${TAG} - Le script de restauration '${scriptDir%/}/master-backup-restore.sh' est absent."
				fi
			} 2>&1 | \
			{
				# Boucle de chronométrage
				let startTime=$(date +%s)
				while read line
				do
					echo ${line}
				done
				echo
				let stopTime=$(date +%s)
				let totalSec=(stopTime-startTime)
				echo "Durée totale du processus de restauration : ${totalSec} secondes" >> ${messageContent}
				let MAX_DELAY_PROBE=(MAX_DELAY_PROBE-totalSec)
			}
		fi
	fi

	# On récupère l'état du backup
	echo "" >> ${messageContent}
	echo "************************************************************************************" >> ${messageContent}
	echo "" >> ${messageContent}
	echo "On vérifie l'état du backup avec '${scriptDir%/}/master-backup-status.sh --conf ${configFile}' :" >> ${messageContent}

	if [[ -e ${scriptDir%/}/master-backup-status.sh ]]; then
		echo "" >> ${messageContent}
		# Create hash to identify our test
		hashedConfigFile=$(echo "${configFile}" | md5sum | perl -p -e 's/ -//g' | perl -p -e 's/ //g')
		# Test access to write on buffer folder & buffer file
		if [[ ! -d ${bufferFolder} ]]; then
			mkdir -p ${bufferFolder}
			[[ $? -ne 0 ]] && echo "Impossible de créer le dossier '${bufferFolder}'" >> ${messageContent} && endThisScript 2 ${processingOutput} "FATAL ERROR - Impossible de créer le dossier '${bufferFolder}'"
		fi
		if [[ ! -f ${bufferFile} ]]; then
			touch ${bufferFile}
			[[ $? -ne 0 ]] && echo "Impossible de créer le fichier '${bufferFile}'" >> ${messageContent} && endThisScript 2 ${processingOutput} "FATAL ERROR - Impossible de créer le fichier '${bufferFile}'"
		fi

		# Test if a previous outpout is stored in buffer file
		cat ${bufferFile} | grep ${hashedConfigFile} > /dev/null 2>&1
		if [[ $? -eq 0 ]]; then
			# Reading previous values
			previousLineBufferFile=$(cat ${bufferFile} | grep ^${hashedConfigFile})
			# Launching test in background
			[[ -e ${tempOutputResult} ]] && rm -R ${tempOutputResult}
			[[ -e ${tempFinalResult} ]] && rm -R ${tempFinalResult}
			nohup bash -c '${scriptDir%/}/master-backup-status.sh --conf ${configFile} >> ${tempOutputResult} ; echo $? >> ${tempFinalResult}' > /dev/null 2>&1 &
			# Loop running
			let maxTime=(MAX_DELAY_PROBE-3)
			if [[ ${maxTime} -gt 0 ]]; then
				until [[ ${thisTime} -eq $((${MAX_DELAY_PROBE}-3)) ]]
				do
					# Test if background job is done
					if [[ -e ${tempFinalResult} ]] && [[ ! -z $(cat ${tempFinalResult}) ]]; then
						# Test is done in background
						thisTime=$((${MAX_DELAY_PROBE}-4))
						# Writing outpout to buffer file
						newLineBufferFile="${hashedConfigFile};$(cat ${tempOutputResult} | perl -p -e 's/\n/%%%%%%/g' | base64 | perl -p -e 's/\n//g');$(date +%s)"
						cat ${bufferFile} | sed 's/'"${previousLineBufferFile}"'/'"${newLineBufferFile}"'/g' >> ${bufferFile}.new \
						&& mv ${bufferFile} ${bufferFile}.old && mv ${bufferFile}.new ${bufferFile} && rm ${bufferFile}.old
						cat ${tempOutputResult} >> ${messageContent}
					fi
					sleep 1
					let thisTime=${thisTime}+1
				done
			fi
			# Reading previous values
			previousDate=$(echo ${previousLineBufferFile} | cut -d ';' -f 3)
			previousDateExplicit=$(date -d @${previousDate})
			echo "*** $(date) ***" >> ${messageContent}
			echo "Le script de contrôle n'a pas terminé son exécution dans un délai raisonnable." >> ${messageContent}
			echo "Donc, nous affichons les précédentes valeurs enregistées en cache en date du ${previousDateExplicit}." >> ${messageContent}
			echo "" >> ${messageContent}
			echo "${previousLineBufferFile}" | cut -d ';' -f 2 | base64 --decode | perl -p -e 's/%%%%%%/\n/g' >> ${messageContent}
		
			# Creating temp script
			echo "#!/bin/bash" > ${tempScript}
			echo "[[ -e "${tempOutputResult}" ]] && rm -R "${tempOutputResult} >> ${tempScript}
			echo "[[ -e "${tempOutputResult}.encoded" ]] && rm -R "${tempOutputResult}.encoded >> ${tempScript}
			echo "${scriptDir%/}/master-backup-status.sh --conf ${configFile} > ${tempOutputResult}" >> ${tempScript}
			echo 'cat '${tempOutputResult}' | perl -p -e "s/\\n/%%%%%%/g" | base64 | perl -p -e "s/\\n//g" > '${tempOutputResult}.encoded >> ${tempScript}
			echo 'newLineBufferFile="'${hashedConfigFile}';$(cat '${tempOutputResult}'.encoded);$(date +%s)"' >> ${tempScript}
			echo "cat "${bufferFile}" | sed 's/"${previousLineBufferFile}"/'\"\${newLineBufferFile}\"'/g' >> "${bufferFile}".new && mv "${bufferFile}" "${bufferFile}".old && mv "${bufferFile}".new "${bufferFile}" && rm "${bufferFile}".old" >> ${tempScript}
			echo "[[ -e "${tempOutputResult}" ]] && rm -R "${tempOutputResult} >> ${tempScript}
			echo "[[ -e "${tempOutputResult}.encoded" ]] && rm -R "${tempOutputResult}.encoded >> ${tempScript}
			echo "[[ -e "${tempFinalResult}" ]] && rm -R "${tempFinalResult} >> ${tempScript}
			echo "[[ -e "${tempPreviousContent}" ]] && rm -R "${tempPreviousContent} >> ${tempScript}
			echo "rm ${tempScript}" >> ${tempScript}
			echo "rm ${lockFile}" >> ${tempScript}
			echo "exit 0" >> ${tempScript}
			# Chmod script to be executed
			chmod +x ${tempScript}
			# Run this script in background
			(/bin/bash ${tempScript} > /dev/null 2>&1 &)
			echo "dontRemoveTemp" > ${tempProcessingOutput}
		else
			# First time running test for this folder > writing outpout to Buffer file
			echo "$(date)" >> ${messageContent}
			echo "C'est la première fois que cette sonde est lancée pour contrôler le backup '${TAG}'." >> ${messageContent}
			echo "Nous n'avons donc pas en cache de précédente valeur à afficher." >> ${messageContent}
			echo "Merci de patienter, nous lançons le contrôle complet avec la commande '${scriptDir%/}/master-backup-status.sh --conf ${configFile}'." >> ${messageContent}
			echo "" >> ${messageContent}
			${scriptDir%/}/master-backup-status.sh --conf ${configFile} > ${tempOutputResult} 2>&1
			newLineBufferFile="${hashedConfigFile};$(cat ${tempOutputResult} | perl -p -e 's/\n/%%%%%%/g' | base64 | perl -p -e 's/\n//g');$(date +%s)"
			echo ${newLineBufferFile} >> ${bufferFile}
			cat ${tempOutputResult} >> ${messageContent}
			echo "removeTemp" > ${tempProcessingOutput}
		fi
	else
		let warningVerifyScript=${warningVerifyScript}+1
		echo "removeTemp" > ${tempProcessingOutput}
		echo "'${scriptDir%/}/master-backup-status.sh' est absent !" >> ${messageContent}
	fi
		
	# On renvoie le résultat vers des fichiers temporaires
	echo "${warningTest}" > ${tempWarningTest}
	echo "${warningVerifyScript}" > ${tempWarningVerifyScript}
	echo "${criticalTest}" > ${tempCriticalTest}

} 2>&1 | \
{
	# Boucle de chronométrage de la totalité du processus
	let totalStartTime=$(date +%s)
	while read totalline
	do
		echo ${totalline}
	done
	let totalStopTime=$(date +%s)
	let totalTimeMin=(totalStopTime-totalStartTime)/60 totalTimeSec=(totalStopTime-totalStartTime)%60
	echo "" >> ${messageContent}
	echo "************************************************************************************" >> ${messageContent}
	echo "" >> ${messageContent}
	echo "Durée totale d'éxécution de la sonde : ${totalTimeMin} minute"$([[ ${totalTimeMin} -gt 1 ]] && echo 's')" et ${totalTimeSec} seconde"$([[ ${totalTimeSec} -gt 1 ]] && echo 's') >> ${messageContent}
	echo "" >> ${messageContent}
	echo "************************************************************************************" >> ${messageContent}
}

processingOutput=$(cat ${tempProcessingOutput})
if [[ $(cat ${tempCriticalTest}) -ge 1 ]]; then
	endThisScript 2 ${processingOutput} "CRITICAL - ${scriptName} (${TAG} sur ${H}) - Pas de backup depuis ${NAGIOS_CRIT_DAYS} jour"$([[ ${NAGIOS_CRIT_DAYS} -gt 1 ]] && echo 's')" !"
elif [[ $(cat ${tempWarningTest}) -ge 1 ]]; then
	if [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "YES" ]] || [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "Yes" ]] || [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "yes" ]] || [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "Y" ]] || [[ ${NAGIOS_PROBE_WITH_RESTORE_TEST} == "y" ]] ; then
		endThisScript 1 ${processingOutput} "WARNING - ${scriptName} (${TAG} sur ${H}) - Pas de backup depuis ${NAGIOS_WARN_DAYS} jour"$([[ ${NAGIOS_WARN_DAYS} -gt 1 ]] && echo 's')" !"
	else
		endThisScript 1 ${processingOutput} "WARNING - ${scriptName} (${TAG} sur ${H})"
	fi
elif [[ $(cat ${tempWarningVerifyScript}) -ge 1 ]]; then
    endThisScript 1 ${processingOutput} "WARNING - ${scriptName} (${TAG} sur ${H}) - master-backup-status.sh est absent !"
else
    endThisScript 0 ${processingOutput} "OK - ${scriptName} (${TAG} sur ${H})"
fi

endThisScript 0