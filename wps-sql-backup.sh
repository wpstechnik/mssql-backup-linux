#!/bin/bash


whatami=`basename "${0}"`
logfile="/var/log/${whatami}.log"
logfile="${whatami}.log"
backup_path="/var/opt/mssql/backup"
archive_password_file="/root/.archive_passphrase"
dow=$(date +%Y%m%d-%Hh%M)
current_filename=""
previous_filename=""
pointer_filename=""
db=""
PREFIX=""

function l1
{
   echo -n "[ ** ] "
   echo -n $(date +%F_%H:%M:%S) ${1}...\  >> ${logfile}
   if [ -z ${VERBOSE} ]; then echo ${1}; fi
   timera=$(date +%s)
}

function l2
{
    timerb=$(date +%s)
    duration=$((timerb-timera))
    echo "DONE (${duration}s.)" >> ${logfile}

}

function update_db_name
{
        case ${PREFIX} in
            "nexo")
            db="Nexo_${DATABASE}"
            ;;
            "gt")
            db="${DATABASE}"
            ;;
        esac
}

function create_backup
{
    current_filename="${PREFIX}-${DATABASE}-${dow}.bak"
    pointer_filename="${PREFIX}-${DATABASE}.bak"
    sql_user=`echo ${HOST} | cut -d'@' -f 1`
    sql_host=`echo ${HOST} | cut -d'@' -f 2`

    l1 "Creating backup ${DATABASE} from ${PREFIX} as $sql_user with pass ${MSSQL_PASS} on host $sql_host"
    ${DRY_RUN} sqlcmd -S $sql_host -U $sql_user -P "${MSSQL_PASS}" -Q "BACKUP DATABASE [${DATABASE}] TO DISK = N'${backup_path}/${current_filename}' WITH NOFORMAT, NOINIT, NAME = '${DATABASE}', SKIP, NOREWIND, NOUNLOAD, STATS = 10" && l2
}

function restore_backup
{
    sql_user=`echo ${HOST} | cut -d'@' -f 1`
    sql_host=`echo ${HOST} | cut -d'@' -f 2`

    l1 "Restoring backup ${DATABASE} from ${PREFIX} as $sql_user with pass ${MSSQL_PASS} on host $sql_host"
    ${DRY_RUN} sqlcmd -S $sql_host -U $sql_user -P "${MSSQL_PASS}" -Q "RESTORE DATABASE [${DATABASE}] FROM DISK = N'${backup_path}/${current_filename}' WITH FILE = 1, NOUNLOAD, REPLACE, STATS = 10" && l2
}

function compress_backup
{
    previous_filename="${current_filename}"
    current_filename="${current_filename}.lz"
    pointer_filename="${pointer_filename}.lz"

    l1 "Compressing backup of ${DATABASE}"
    ${DRY_RUN} plzip -${COMPRESSION_LEVEL-0} "${backup_path}/${previous_filename}" && l2
}

function decompress_backup
{
    previous_filename="${current_filename}"
    current_filename=$(basename ${current_filename} .lz)

    l1 "Decompressing backup of ${DATABASE}"
    ${DRY_RUN} plzip -d "${backup_path}/${previous_filename}" && l2
}


function encrypt_backup
{
    previous_filename="${current_filename}"
    current_filename="${current_filename}.gpg"
    pointer_filename="${pointer_filename}.gpg"

    l1 "Encrypting backup of ${DATABASE}"
    ${DRY_RUN} gpg --no-use-agent --passphrase-file "${archive_password_file}" --symmetric "${backup_path}/${previous_filename}" && l2
    l1 "Removing unencrypted version of ${DATABASE}"
    ${DRY_RUN} rm -f "${backup_path}/${previous_filename}" && l2
}

function decrypt_backup
{
    previous_filename="${current_filename}"
    current_filename=$(basename ${current_filename} .gpg)

    l1 "Decrypting backup of ${DATABASE}"
    ${DRY_RUN} gpg --no-use-agent --passphrase-file "${archive_password_file}" --output "${backup_path}/${current_filename}" --decrypt "${backup_path}/${previous_filename}" && l2

}

function send_backup
{
    if [ "${BACKUP_SERVER}" == "0" ]; then
        l1 "Do not send backup to remote location option chosen" && l2
    else
        l1 "Sending backup of ${DATABASE} to ${BACKUP_SERVER}"
        ${DRY_RUN} scp "${backup_path}/${current_filename}" "${BACKUP_SERVER}/${PREFIX}" && l2

        l1 "Updating current backup pointer"
        backup_server_host=`echo ${BACKUP_SERVER} | cut -d':' -f 1`
        backup_server_path=`echo ${BACKUP_SERVER} | cut -d':' -f 2`
        ${DRY_RUN} ssh -t "${backup_server_host}" "ln -f -s ${current_filename} ${backup_server_path}/${PREFIX}/${pointer_filename}" && l2

        l1 "Removing local backup version of ${DATABASE}"
        ${DRY_RUN} rm -f "${backup_path}/${current_filename}" && l2
    fi
}

function get_backup
{
    current_filename="${PREFIX}-${DATABASE}.bak.lz.gpg"
    ${DRY_RUN} mkdir -p "${backup_path}"
    l1 "Geting backup of ${DATABASE} from ${BACKUP_SERVER}"
    ${DRY_RUN} scp "${BACKUP_SERVER}/${PREFIX}/${current_filename}" "${backup_path}/${current_filename}" && l2


}

function get_variable_name_for_option {
    local OPT_DESC=${1}
    local OPTION=${2}
    local VAR=$(echo ${OPT_DESC} | sed -e "s/.*\[\?-${OPTION} \([A-Z_]\+\).*/\1/g" -e "s/.*\[\?-\(${OPTION}\).*/\1FLAG/g")

    if [[ "${VAR}" == "${1}" ]]; then
        echo ""
    else
        echo ${VAR}
    fi
}

function parse_options {
    local OPT_DESC=${1}
    local INPUT=$(get_input_for_getopts "${OPT_DESC}")

    shift
    while getopts ${INPUT} OPTION ${@};
    do
        [ ${OPTION} == "?" ] && usage
        VARNAME=$(get_variable_name_for_option "${OPT_DESC}" "${OPTION}")
            [ "${VARNAME}" != "" ] && eval "${VARNAME}=${OPTARG:-true}" # && printf "\t%s\n" "* Declaring ${VARNAME}=${!VARNAME} -- OPTIONS='$OPTION'"
    done

    check_for_required "${OPT_DESC}"

}

function check_for_required {
    local OPT_DESC=${1}
    local REQUIRED=$(get_required "${OPT_DESC}" | sed -e "s/\://g")
    while test -n "${REQUIRED}"; do
        OPTION=${REQUIRED:0:1}
        VARNAME=$(get_variable_name_for_option "${OPT_DESC}" "${OPTION}")
                [ -z "${!VARNAME}" ] && printf "ERROR: %s\n" "Option -${OPTION} must been set." && usage
        REQUIRED=${REQUIRED:1}
    done
}

function get_input_for_getopts {
    local OPT_DESC=${1}
    echo ${OPT_DESC} | sed -e "s/\([a-zA-Z]\) [A-Z_]\+/\1:/g" -e "s/[][ -]//g"
}

function get_optional {
    local OPT_DESC=${1}
    echo ${OPT_DESC} | sed -e "s/[^[]*\(\[[^]]*\]\)[^[]*/\1/g" -e "s/\([a-zA-Z]\) [A-Z_]\+/\1:/g" -e "s/[][ -]//g"
}

function get_required {
    local OPT_DESC=${1}
    echo ${OPT_DESC} | sed -e "s/\([a-zA-Z]\) [A-Z_]\+/\1:/g" -e "s/\[[^[]*\]//g" -e "s/[][ -]//g"
}

function usage {
    printf "Usage:\n\t%s\n" "${0} ${OPT_DESC}"
    exit 10
}


USAGE="-t TASK -h HOST -l PREFIX -p DATABASE [ -z COMPRESSION_LEVEL -s BACKUP_SERVER -d DRY_RUN ]"
parse_options "${USAGE}" ${@}

echo "TAKS: backup|restore"
echo "HOST: SQL Server host as user@host"
echo "PREFIX: nexo|gt"
echo "DATABASE: database name"
echo "COMPRESSION_LEVEL: 0..9, default: 0"
echo "BACKUP_SERVER: backup server in scp format user@host:dir"
echo "DRY_RUN: if set to 'echo' then script will show commands instead of executing them, for debug"

case ${TASK} in
    backup)
        l1 "Starting backup" && l2
        create_backup
        compress_backup
        encrypt_backup
        send_backup
        ;;
    restore)
        echo "Starting restore" && l2
        get_backup
        decrypt_backup
        decompress_backup
        restore_backup
        ;;
esac