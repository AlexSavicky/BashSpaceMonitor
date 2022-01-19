#!/usr/bin/env bash
set -e
set -m

### BEGIN INIT SCRIPT
# Provides: ac_check_disk_space
# Required-Start: $local_fs $syslog
# Required-Stop: $local_fs
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: ac_check_disk_space
# Description: Service to monitoring disk space for Astra Linux
### END INIT SCRIPT

usage()
{
    echo -e "Usage:\n$0 (start|stop|restart)"
}

_log()
{
    # Сдвигаем влево входные параметры    
    #shift
    ts=`date +"%b %d %Y %H:%M:%S"`
    hn=`cat /etc/hostname`
    echo "$ts $hn ac_check_disk_space[${BASHPID}]: $*"
}

check_conf_file()
{
    if [ -e "/etc/ac/check_disk_space.conf" ]; then
        source "/etc/ac/check_disk_space.conf"
    else
        echo "Can not find configuration file (/etc/ac/check_disk_space.conf)"
        exit 0
    fi
}

function calculate_space_prefix()
{
    local value=$1
    local result=$2

    local size=0
    local prefix=""

    prefix="${value: -1}"
    len="${#value}"
    len=$(($len - 1))
    size="${value:0:$len}"

    case $prefix in
        "K")
            size=$(($size * 1024))
            ;;

        "M")
            size=$(($size * 1048576)) 
            ;;

        "G")
            size=$(($size * 1073741824))
            ;;

        *) 
            #size=$(($size * 1073741824))
            ;;
    esac

    echo $size
}

function calculate_return_space_prefix()
{
    local value=$1
    local space=$2

    local size=0

    prefix="${value: -1}"
    case $prefix in
        "K")
            size=$(($space / 1024))
            ;;

        "M")
            size=$(($space / 1048576))
            ;;

        "G")
            size=$(($space / 1073741824))
            ;;
        *)
            ;;
    esac

    echo $size
}

start()
{
    #trap 'echo "1" >> /tmp/test' 1 2 3 15

    # Проверяем запуск от рута
    if [ $UID -ne 0 ]; then
        echo "Root privileges required"
        exit 0
    fi

    # Проверяем наличие конфига
    check_conf_file

    # Проверка на вторую копию
    if [ -e ${PID_FILE} ]; then
        _pid=( `cat ${PID_FILE}` )
        if [ -e "/proc/${_pid}" ]; then
            echo "Daemon already running with pid = $_pid"
            exit 0
        fi
    fi

    touch ${LOG_FILE}

    # Получаем списки дисков по именам и UUID
    disks=( `blkid | grep -v swap | awk '{print $1}' | sed -e s/://` )
    uuids=( `blkid | grep -v swap | awk '{print $2}' | sed -e s/UUID=// | sed -e s/\"//g` )

    # Инициализация массива привязки диска к точке монтирования
    mounts=()

    # Заполняем массив по имени диска
    for (( i=0; i<${#disks[*]}; i++ )); do
        mount_point=( `cat /proc/mounts | grep ${disks[$i]} | awk '{print $2}'` )
        if [[ ! -z $mount_point ]]; then
            mounts=("${mounts[@]}" "${disks[$i]}:$mount_point")
        fi
    done

    # Заполняем массив по UUID
    for (( i=0; i<${#uuids[*]}; i++ )); do
        mount_point=( `cat /proc/mounts | grep ${uuids[$i]} | awk '{print $2}'` )
        if [[ ! -z $mount_point ]]; then
            disk=`blkid -U ${uuids[$i]}`
            mounts=("${mounts[@]}" "$disk:$mount_point")
        fi
    done

    # Проверка, существуют ли диски указанные в файле настройки и составление массива дисков для проверки
    exists=0
    checked_disks=()
    for mount in "${mounts[@]}"; do
        mount_disk="${mount%%:*}"
            
        for check in "${CHECK_DISKS[@]}"; do
            check_disk="${check%%:*}"

            if [ $check_disk == $mount_disk ]; then
                check_size="${check##*:}"
                size=$(calculate_space_prefix $check_size)

                checked_disks=("${checked_disks[@]}" "$check_disk:$size")
                exists=1
            fi
        done
    done

    if [ $exists -eq 0 ]; then
        echo "Can not find disks, please check your configuration file"
        exit 1
    fi

    # Копия предыдущего лога
    cp -f ${LOG_FILE} ${LOG_FILE}.prev

    # Имя хоста
    host=( `cat /etc/hostname` )

    # Демонизация процесса =)
    cd /
    exec > ${LOG_FILE}
    exec 2> /dev/null
    exec < /dev/null

    # Форкаемся
    (
        # ; rm -f ${PID_FILE}; exit 255;
        # SIGHUP SIGINT SIGQUIT SIGTERM
        #trap '_log "Daemon stop"; rm -f ${PID_FILE}; cp ${LOG_FILE} ${LOG_FILE}.prev; exit 0;' 1 2 3 15

        _log "Daemon started"

        # Основной цикл
        while [ 1 ]; do
            
            for checked in "${checked_disks[@]}"; do
                checked_disk="${checked%%:*}"
                checked_size="${checked##*:}"

                for mount in "${mounts[@]}"; do
                    mount_disk="${mount%%:*}"
                    mount_point="${mount##*:}"

                    if [ $mount_disk == $checked_disk ]; then
                        disk_all=( `stat -f $mount_point -c "%b"` )
                        disk_avaiable=( `stat -f $mount_point -c "%a"` )
                        disk_block_size=( `stat -f $mount_point -c "%s"` )

                        disk_all=$(($disk_all * $disk_block_size))
                        disk_avaiable=$(($disk_avaiable * $disk_block_size))

                        if [ $disk_avaiable -le $checked_size ]; then
                            _log "Low disk size on $checked_disk mounted to $mount_point. Total size: $disk_all, avaiable size: $disk_avaiable, trigger size: $checked_size."
                            
                            # Переводим байты в удобочитаемый формат
                            for check in "${CHECK_DISKS[@]}"; do
                                check_disk="${check%%:*}"
                                check_size="${check##*:}"

                                if [ $check_disk == $checked_disk ]; then
                                    disk_all=$(calculate_return_space_prefix $check_size $disk_all)
                                    disk_avaiable=$(calculate_return_space_prefix $check_size $disk_avaiable)
                                    checked_size=$(calculate_return_space_prefix $check_size $checked_size)

                                    prefix="${check_size: -1}"
                                fi
                            done
                            
                            subject=`echo -e ${MAIL_SUBJECT_TEMPLATE} | sed -e "s|:host:|$host|g" | sed -e "s|:disk:|$checked_disk|g" | sed -e "s|:mount_point:|$mount_point|g" | sed -e "s|:disk_total:|${disk_all}${prefix}|g" | sed -e "s|:disk_avaiable:|${disk_avaiable}${prefix}|g" | sed -e "s|:disk_checked_size:|${checked_size}${prefix}|g"`
                            body=`echo -e ${MAIL_BODY_TEMPLATE} | sed -e "s|:host:|$host|g" | sed -e "s|:disk:|$checked_disk|g" | sed -e "s|:mount_point:|$mount_point|g" | sed -e "s|:disk_total:|${disk_all}${prefix}|g" | sed -e "s|:disk_avaiable:|${disk_avaiable}${prefix}|g" | sed -e "s|:disk_checked_size:|${checked_size}${prefix}|g"`

                            for rcpt in "${MAIL_RCPT[@]}"; do
                                echo "$body" | mail -s "$subject" "$rcpt"
                            done
                        fi
                    fi
                done
            done

            sleep "${CHECK_PERIOD}"
        done
    )&

    # Пишем pid потомка в файл
    echo $! > ${PID_FILE}
}

stop()
{
    check_conf_file

    if [ -e ${PID_FILE} ]; then

        _pid=( `cat ${PID_FILE}` )
        if [ -e "/proc/${_pid}" ]; then
            kill -9 $_pid
        
            result=$?
            if [ $result -eq 0 ]; then
                echo "Daemon stop."
            else
                echo "Error stop daemon"
            fi
        
        else
            echo "Daemon is not run"  
        fi    

    else
        echo "Daemon is not run"  
    fi
}

restart()
{
    stop
    start
}

case $1 in
    "start")
        start
        ;;

    "stop")
        stop
        ;;

    "restart")
        restart
        ;;

    *)
        usage
        ;;
esac

exit 0