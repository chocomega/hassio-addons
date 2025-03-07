#!/usr/bin/with-contenv bashio
# shellcheck shell=bash
# shellcheck disable=

#########################
# MOUNT SMB SHARES v1.6 #
#########################
if bashio::config.has_value 'networkdisks'; then

    # Define variables
    MOREDISKS=$(bashio::config 'networkdisks')
    CIFS_USERNAME=$(bashio::config 'cifsusername')
    CIFS_PASSWORD=$(bashio::config 'cifspassword')

    SMBVERS=""
    SECVERS=""

    # Mount CIFS Share if configured and if Protection Mode is active
    echo 'Mounting smb share(s)...'

    if bashio::config.has_value 'cifsdomain'; then
        echo "Using domain $(bashio::config 'cifsdomain')"
        DOMAIN=",domain=$(bashio::config 'cifsdomain')"
    else
        DOMAIN=""
    fi

    # Mount using UID/GID values
    if bashio::config.has_value 'PUID' && bashio::config.has_value 'PGID' && [ -z ${ROOTMOUNT+x} ]; then
        echo "Using PUID $(bashio::config 'PUID') and PGID $(bashio::config 'PGID')"
        PUID=",uid=$(bashio::config 'PUID')"
        PGID=",gid=$(bashio::config 'PGID')"
    else
        PUID=",uid=$(id -u)"
        PGID=",gid=$(id -g)"
    fi

    # Clean data
    MOREDISKS=${MOREDISKS// \/\//,\/\/}
    MOREDISKS=${MOREDISKS//, /,}
    MOREDISKS=${MOREDISKS// /"\040"}

    # Mounting disks
    # shellcheck disable=SC2086
    for disk in ${MOREDISKS//,/ }; do # Separate comma separated values

        # Clean name of network share
        # shellcheck disable=SC2116,SC2001
        disk=$(echo $disk | sed "s,/$,,") # Remove / at end of name
        disk="${disk//"\040"/ }"            #replace \040 with
        diskname="${disk//\\//}"            #replace \ with /
        diskname="${diskname##*/}"          # Get only last part of the name
        MOUNTED=false

        # Data validation
        if [[ ! $disk =~ ^.*+[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[/]+.*+$ ]]; then
            bashio::log.fatal "The structure of your \"networkdisks\" option : \"$disk\" doesn't seem correct, please use a structure like //123.12.12.12/sharedfolder,//123.12.12.12/sharedfolder2. If you don't use it, you can simply remove the text, this will avoid this error message in the future."
            break 2
        fi

        # Does server exists
        server="$(echo "$disk" | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+")"
        if ping -w 1 -c 1 8.8.8.8 >/dev/null; then
            ping -w 5 -c 1 "$server" >/dev/null || \
                { bashio::log.fatal "Your server $server from $disk doesn't ping, is it correct?"; break 2; }
        fi

        # Prepare mount point
        mkdir -p /mnt/"$diskname"
        chown -R root:root /mnt/"$diskname"

        # if Fail test different smb and sec versions
        if [ "$MOUNTED" = false ]; then

            # Test with domain, remove otherwise
            ####################################
            for DOMAINVAR in "$DOMAIN" ",domain=WORKGROUP" ""; do

                # Test with PUIDPGID, remove otherwise
                ######################################
                for PUIDPGID in "$PUID$PGID" "$PUID$PGID,forceuid,forcegid" ""; do

                    # Test with iocharset utf8, remove otherwise
                    ############################################
                    for CHARSET in ",iocharset=utf8" ""; do

                        # Test with different SMB versions
                        ##################################
                        for SMBVERS in "" ",vers=3" ",vers=1.0" ",vers=2.1" ",vers=3.0" ",nodfs"; do

                            # Test with different security versions
                            #######################################
                            for SECVERS in "" ",sec=ntlm" ",sec=ntlmv2" ",sec=ntlmv2i" ",sec=ntlmssp" ",sec=ntlmsspi" ",sec=krb5i" ",sec=krb5"; do
                                if [ "$MOUNTED" = false ]; then
                                    mount -t cifs -o "rw,file_mode=0775,dir_mode=0775,username=$CIFS_USERNAME,password=${CIFS_PASSWORD},nobrl$SMBVERS$SECVERS$PUIDPGID$CHARSET$DOMAINVAR" "$disk" /mnt/"$diskname" 2>ERRORCODE \
                                        && MOUNTED=true && MOUNTOPTIONS="$SMBVERS$SECVERS$PUIDPGID$CHARSET$DOMAINVAR" || MOUNTED=false
                                fi
                            done

                        done

                    done

                done

            done
        fi

        # Messages
        if [ "$MOUNTED" = true ] && mountpoint -q /mnt/"$diskname"; then
            #Test write permissions
            # shellcheck disable=SC2015
            touch "/mnt/$diskname/testaze" && rm "/mnt/$diskname/testaze" &&
            bashio::log.info "... $disk successfully mounted to /mnt/$diskname with options $MOUNTOPTIONS" ||
            bashio::log.fatal "Disk is mounted, however unable to write in the shared disk. Please check UID/GID for permissions, and if the share is rw"

            # Test for serverino
            # shellcheck disable=SC2015
            touch "/mnt/$diskname/testaze" && mv "/mnt/$diskname/testaze" "/mnt/$diskname/testaze2" && rm "/mnt/$diskname/testaze2" ||
            (umount "/mnt/$diskname" && mount -t cifs -o "iocharset=utf8,rw,file_mode=0775,dir_mode=0775,username=$CIFS_USERNAME,password=${CIFS_PASSWORD}$MOUNTOPTIONS,noserverino" "$disk" /mnt/"$diskname" && bashio::log.warning "noserverino option used")

        else
            # Mounting failed messages
            bashio::log.fatal "Error, unable to mount $disk to /mnt/$diskname with username $CIFS_USERNAME, $CIFS_PASSWORD. Please check your remote share path, username, password, domain, try putting 0 in UID and GID"
            bashio::log.fatal "Here is some debugging info :"

            # Download smbclient
            if command -v "apk" &>/dev/null; then apk add --no-cache samba-client &>/dev/null; fi
            if command -v "apt" &>/dev/null; then apt-get install smbclient &>/dev/null; fi
            if command -v "pacman" &>/dev/null; then pacman -S smbclient; fi

            # Provide debugging info
            smbclient -L $disk -U "$CIFS_USERNAME%$CIFS_PASSWORD" || true

            # Error code
            mount -t cifs -o "rw,file_mode=0775,dir_mode=0775,username=$CIFS_USERNAME,password=${CIFS_PASSWORD},nobrl$DOMAINVAR" "$disk" /mnt/"$diskname" 2>ERRORCODE || MOUNTED=false
            bashio::log.fatal "Error read : $(<ERRORCODE)"
            rm ERRORCODE*

            # clean folder
            umount "/mnt/$diskname" 2>/dev/null || true
            rmdir "/mnt/$diskname" || true
        fi

    done

    if [ -f ERRORCODE ]; then
        rm ERRORCODE*
    fi

fi
